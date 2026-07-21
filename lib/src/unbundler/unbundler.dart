import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../archive/archive_path.dart';
import '../archive/archive_reader.dart';
import '../archive/archive_validator.dart';
import '../bundler/file_classifier.dart';
import '../manifest/manifest.dart';
import '../manifest/manifest_validator.dart';
import '../manifest/substitution_template.dart';
import '../prompt/variable_resolver.dart';
import 'case_converter.dart';
import 'substitutor.dart';
import 'target_validator.dart';
import 'variables_validator.dart';

/// The public unpacking contract: materialize a project from archive bytes.
abstract class UnbundlerBase {
  /// Unpacks the archive [bytes] into [targetDir], applying [vars].
  Future<void> unbundle({
    required List<int> bytes,
    required String targetDir,
    required Map<String, String> vars,
  });
}

/// Materializes a project from a template archive, applying manifest-driven
/// renaming at unpack time (the archive itself stays a verbatim snapshot).
///
/// For each declared variable with a `replaces` token, the resolved value
/// substitutes all four casings throughout file/dir paths and text-file
/// contents. Binary files are copied byte-for-byte.
class Unbundler implements UnbundlerBase {
  const Unbundler();

  /// Unpacks the in-memory archive [bytes] into [targetDir] (the core path).
  ///
  /// [vars] holds explicit `--var` values; any variable absent from it is
  /// resolved by [resolver] (default/prompt per its configuration). Without a
  /// [resolver], unresolved variables fall back to the manifest `default`; one
  /// with no default is reported by `VariablesValidator`.
  ///
  /// [onWarning] receives non-fatal problems that would otherwise be silent,
  /// such as failing to restore an executable bit.
  @override
  Future<void> unbundle({
    required List<int> bytes,
    required String targetDir,
    Map<String, String> vars = const {},
    VariableResolver? resolver,
    void Function(String message)? onWarning,
  }) {
    // Phase order: archive → manifest → target → variables. The first failing
    // phase aborts before the next runs.
    //
    // Target precedes variables because resolving them may prompt: validating
    // it afterwards made the user answer every prompt only to be told the
    // destination was occupied, discarding all the input.
    const ArchiveValidator().validate(bytes).throwIfInvalid();
    final archive = const ArchiveReader().read(bytes);
    final manifest = Manifest.fromYaml(archive.manifestYaml);
    const ManifestValidator().validate(manifest).throwIfInvalid();
    const TargetValidator().validate(targetDir).throwIfInvalid();

    final resolved = (resolver ?? const VariableResolver()).resolve(
      manifest.variables,
      vars,
    );
    const VariablesValidator()
        .validate(
          VariablesInput(variables: manifest.variables, values: resolved),
        )
        .throwIfInvalid();

    // Re-checked immediately before writing. Resolving variables may block on
    // interactive input for minutes, and the earlier check is what keeps the
    // user from typing answers that get thrown away — it is not a claim that
    // the target is still free once they finish.
    const TargetValidator().validate(targetDir).throwIfInvalid();

    _write(archive, manifest, targetDir, resolved, onWarning);

    return .value();
  }

  /// Unpacks a project directly from in-memory archive [source] bytes (e.g. an
  /// embedded `const List<int>` template). Delegates to [unbundle].
  Future<void> unbundleBytes({
    required List<int> source,
    required String targetDir,
    Map<String, String> vars = const {},
    VariableResolver? resolver,
    void Function(String message)? onWarning,
  }) => unbundle(
    bytes: source,
    targetDir: targetDir,
    vars: vars,
    resolver: resolver,
    onWarning: onWarning,
  );

  /// Reads the archive at the file [source] and unpacks it into [targetDir].
  Future<void> unbundleFile({
    required String source,
    required String targetDir,
    Map<String, String> vars = const {},
    VariableResolver? resolver,
    void Function(String message)? onWarning,
  }) {
    final file = File(source);
    if (!file.existsSync()) {
      throw FormatException('Archive not found: $source');
    }

    return unbundle(
      bytes: file.readAsBytesSync(),
      targetDir: targetDir,
      vars: vars,
      resolver: resolver,
      onWarning: onWarning,
    );
  }

  /// Writes [archive]'s `files/` tree into [targetDir] with substitution, using
  /// the parsed [manifest] and already-[resolved] variable values.
  ///
  /// Paths are rewritten with the variable-derived renames only; text content
  /// also gets the manifest's literal `extra_substitutions`. Binary files (by
  /// extension, including `binary_extensions`) and `no_substitute` matches are
  /// copied byte-for-byte — though their path is still renamed.
  void _write(
    BundleArchive archive,
    Manifest manifest,
    String targetDir,
    Map<String, String> resolved,
    void Function(String message)? onWarning,
  ) {
    final renames = _buildTable(manifest, resolved);
    final pathSubstitutor = Substitutor(renames);
    // Templates are rendered *before* the table is built, so the result enters
    // the same single-pass longest-first match as the renames. That ordering
    // is required, not incidental: `from: super_server.dev` (16 chars) must
    // beat the rename key `super_server` (12) at the same position, which a
    // sequential renames-then-substitutions pass would break.
    //
    // A rendered value is emitted verbatim and never re-scanned, and an
    // explicit substitution whose `from` equals a derived rename key wins,
    // because the spread puts it last.
    final contentSubstitutor = Substitutor({
      ...renames,
      ..._render(manifest.extraSubstitutions, resolved),
    });
    final classifier = FileClassifier(
      extraBinary: manifest.binaryExtensions.toSet(),
    );
    final noSubstitute = manifest.noSubstitute.map(Glob.new).toList();

    final target = Directory(targetDir)..createSync(recursive: true);
    final restoreExecutable = <String>[];
    for (final entry in archive.files.entries) {
      final outRel = pathSubstitutor.apply(entry.key);
      // Re-checked after substitution, and independently of ArchiveValidator,
      // so a direct library call can never write outside its target directory.
      if (!isContainedArchivePath(outRel)) {
        throw FormatException(
          "Archive entry 'files/${entry.key}' is not a contained relative "
          'path (traversal, absolute, or drive-qualified).',
        );
      }
      final outPath = p.join(target.path, outRel);
      final out = File(outPath)..parent.createSync(recursive: true);

      final verbatim =
          classifier.isBinary(entry.key) ||
          noSubstitute.any((g) => g.matches(entry.key));
      // Extension-based classification calls anything unlisted text, including
      // extensionless files, so a "text" file can still hold non-UTF-8 bytes.
      // Falling back to a verbatim copy keeps such a file intact instead of
      // aborting the unpack partway through; classification stays extension-
      // based, no content sniffing.
      final decoded = verbatim ? null : _tryDecodeUtf8(entry.value);
      if (decoded == null) {
        out.writeAsBytesSync(entry.value);
      } else {
        // `utf8.decode` silently drops a leading BOM and `utf8.encode` does
        // not put it back, so a substituted file would lose three bytes on
        // every unpack — even under an identity rename. Common in
        // Windows-authored .bat, .ps1 and .csproj files.
        final encoded = utf8.encode(contentSubstitutor.apply(decoded));
        out.writeAsBytesSync(
          _startsWithBom(entry.value) ? [..._utf8Bom, ...encoded] : encoded,
        );
      }
      if (archive.executable.contains(entry.key)) {
        restoreExecutable.add(outPath);
      }
    }
    _makeExecutable(restoreExecutable, onWarning);
  }

  /// Restores the owner-executable bit on [paths].
  ///
  /// `dart:io` exposes no chmod, so this shells out. A no-op on Windows, which
  /// has no such bit; best-effort elsewhere, since failing to chmod must not
  /// discard an otherwise valid unpack — but the failure is reported through
  /// [warn] rather than swallowed, or the user meets it later as "permission
  /// denied" in the scaffolded project.
  ///
  /// Batched, but in chunks: one exec with a few thousand paths would exceed
  /// ARG_MAX and fail with E2BIG — a non-zero exit code, not an exception, so
  /// an unchecked call would leave every file non-executable in silence.
  void _makeExecutable(List<String> paths, void Function(String)? warn) {
    if (paths.isEmpty || Platform.isWindows) {
      return;
    }
    const chunkSize = 500;
    for (var i = 0; i < paths.length; i += chunkSize) {
      final chunk = paths.sublist(i, min(i + chunkSize, paths.length));
      try {
        final result = Process.runSync('chmod', ['+x', ...chunk]);
        if (result.exitCode != 0) {
          warn?.call(
            'Could not make ${chunk.length} file(s) executable: '
            '${result.stderr}',
          );
        }
      } on ProcessException catch (e) {
        warn?.call('Could not run chmod: ${e.message}');
      }
    }
  }

  /// The UTF-8 byte-order mark.
  static const _utf8Bom = [0xEF, 0xBB, 0xBF];

  /// Whether [bytes] open with a UTF-8 BOM.
  bool _startsWithBom(List<int> bytes) =>
      bytes.length >= 3 &&
      bytes[0] == _utf8Bom[0] &&
      bytes[1] == _utf8Bom[1] &&
      bytes[2] == _utf8Bom[2];

  /// Decodes [bytes] as UTF-8, or returns null when they are not valid UTF-8.
  String? _tryDecodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  /// Renders each substitution's `to` template against [resolved].
  ///
  /// Rendering is late by necessity: the archive embeds `mold.yaml` verbatim
  /// and variable values are known only here. Everything statically decidable
  /// — syntax, unknown variable, unknown transform — was already rejected by
  /// `ManifestValidator`, which runs at both pack and unpack.
  Map<String, String> _render(
    List<Substitution> substitutions,
    Map<String, String> resolved,
  ) => {
    for (final s in substitutions)
      s.from: SubstitutionTemplate.parse(s.to).render(resolved),
  };

  /// Builds the case-variant replacement table from each variable's `replaces`
  /// token and its already-resolved value.
  Map<String, String> _buildTable(
    Manifest manifest,
    Map<String, String> resolved,
  ) {
    const converter = CaseConverter();
    final table = <String, String>{};
    for (final variable in manifest.variables) {
      final replaces = variable.replaces;
      if (replaces == null) {
        continue;
      }

      final value = resolved[variable.name];
      if (value == null) {
        throw FormatException(
          "No value was resolved for variable '${variable.name}'.",
        );
      }
      table.addAll(converter.replacements(replaces, value));
    }
    
    return table;
  }
}
