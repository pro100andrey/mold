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
import 'unpack_plan.dart';
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
    final (archive, manifest, resolved) = _prepare(
      bytes,
      targetDir,
      vars,
      resolver,
    );

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

  /// Validates the archive and resolves variables, shared by [unbundle] and
  /// [plan] so a dry run runs exactly the checks a real unpack runs.
  ///
  /// Phase order: archive → manifest → target → variables. The first failing
  /// phase aborts before the next runs. Target precedes variables because
  /// resolving them may prompt: validating it afterwards made the user answer
  /// every prompt only to be told the destination was occupied, discarding all
  /// the input.
  (BundleArchive, Manifest, Map<String, String>) _prepare(
    List<int> bytes,
    String? targetDir,
    Map<String, String> vars,
    VariableResolver? resolver,
  ) {
    const ArchiveValidator().validate(bytes).throwIfInvalid();
    final archive = const ArchiveReader().read(bytes);
    final manifest = Manifest.fromYaml(archive.manifestYaml);
    const ManifestValidator().validate(manifest).throwIfInvalid();
    // A null target means "no destination in mind" — previewing the
    // substitutions of a template that has not been distributed yet. Every
    // other phase still runs.
    if (targetDir != null) {
      const TargetValidator().validate(targetDir).throwIfInvalid();
    }

    final resolved = (resolver ?? const VariableResolver()).resolve(
      manifest.variables,
      vars,
    );
    const VariablesValidator()
        .validate(
          VariablesInput(variables: manifest.variables, values: resolved),
        )
        .throwIfInvalid();

    return (archive, manifest, resolved);
  }

  /// Writes [archive]'s `files/` tree into [targetDir] with substitution, using
  /// the parsed [manifest] and already-[resolved] variable values.
  ///
  /// Paths get the variable-derived renames plus `path_renames`; text content
  /// gets the renames plus `extra_substitutions`. The two lists are the only
  /// asymmetry — each reaches exactly one side. Binary files (by extension,
  /// including `binary_extensions`) and `no_substitute` matches are copied
  /// byte-for-byte — though their path is still renamed.
  void _write(
    BundleArchive archive,
    Manifest manifest,
    String targetDir,
    Map<String, String> resolved,
    void Function(String message)? onWarning,
  ) {
    final rules = _Rules(manifest, resolved);

    final target = Directory(targetDir)..createSync(recursive: true);
    final restoreExecutable = <String>[];
    for (final entry in archive.files.entries) {
      final outRel = rules.rename(entry.key);
      final outPath = p.join(target.path, outRel);
      final out = File(outPath)..parent.createSync(recursive: true);

      final decoded = rules.decodeForSubstitution(entry.key, entry.value);
      if (decoded == null) {
        out.writeAsBytesSync(entry.value);
      } else {
        out.writeAsBytesSync(
          rules.encodeSubstituted(entry.value, rules.substitute(decoded)),
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

  /// Builds a plan describing what an unpack would do, without doing it.
  ///
  /// Runs the same validation and variable resolution as [unbundle] and
  /// applies the same [_Rules], so a preview cannot disagree with the real
  /// unpack — it is that computation minus the writes.
  ///
  /// [targetDir] is validated when given, so a dry run also tells you the
  /// destination is usable. Pass null to preview the substitutions alone, with
  /// no destination in mind — what `mold pack --diff` does for a template that
  /// has not been distributed yet.
  UnpackPlan plan({
    required List<int> bytes,
    String? targetDir,
    Map<String, String> vars = const {},
    VariableResolver? resolver,
    bool withContent = true,
  }) {
    final (archive, manifest, resolved) = _prepare(
      bytes,
      targetDir,
      vars,
      resolver,
    );
    final rules = _Rules(manifest, resolved);

    return UnpackPlan([
      for (final entry in archive.files.entries)
        _planOne(rules, entry.key, entry.value, withContent: withContent),
    ]);
  }

  PlannedFile _planOne(
    _Rules rules,
    String key,
    List<int> bytes, {
    required bool withContent,
  }) {
    final to = rules.rename(key);
    final before = rules.decodeForSubstitution(key, bytes);
    if (before == null) {
      return PlannedFile(
        from: key,
        to: to,
        verbatim: true,
        replacements: 0,
      );
    }

    return PlannedFile(
      from: key,
      to: to,
      verbatim: false,
      replacements: rules.countSubstitutions(before),
      // Only materialized when a caller will render it. A summary needs the
      // count alone, and holding both sides of every text file to print one
      // is two extra copies of the whole corpus.
      before: withContent ? before : null,
      after: withContent ? rules.substitute(before) : null,
    );
  }
}

/// The substitution rules for one unpack, derived once from the manifest and
/// the resolved variables.
///
/// Both the writer and `Unbundler.plan` go through this, so a dry run and a
/// real unpack cannot decide differently about any file.
class _Rules {
  factory _Rules(Manifest manifest, Map<String, String> resolved) {
    // Built once and shared: an initializer list cannot hold a local, so the
    // two substitutors used to derive every variable's casings separately.
    final renames = _buildTable(manifest, resolved);

    return _Rules._(
      pathSubstitutor: Substitutor({
        ...renames,
        ..._render(manifest.pathRenames, resolved),
      }),
      // Templates are rendered *before* the table is built, so the result
      // enters the same single-pass longest-first match as the renames. That
      // ordering is required, not incidental: `from: super_server.dev` (16
      // chars) must beat the rename key `super_server` (12) at the same
      // position, which a sequential renames-then-substitutions pass would
      // break.
      //
      // A rendered value is emitted verbatim and never re-scanned, and an
      // explicit substitution whose `from` equals a derived rename key wins,
      // because the spread puts it last.
      contentSubstitutor: Substitutor({
        ...renames,
        ..._render(manifest.extraSubstitutions, resolved),
      }),
      classifier: FileClassifier(
        extraBinary: manifest.binaryExtensions.toSet(),
      ),
      noSubstitute: manifest.noSubstitute.map(Glob.new).toList(),
    );
  }

  const _Rules._({
    required this.pathSubstitutor,
    required this.contentSubstitutor,
    required this.classifier,
    required this.noSubstitute,
  });

  /// Applied to file and directory paths.
  final Substitutor pathSubstitutor;

  /// Applied to text content.
  final Substitutor contentSubstitutor;

  /// Decides text vs binary by extension.
  final FileClassifier classifier;

  /// Globs whose content is copied byte-for-byte.
  final List<Glob> noSubstitute;

  /// The UTF-8 byte-order mark.
  static const _utf8Bom = [0xEF, 0xBB, 0xBF];

  /// Where the archive entry [key] lands, after path substitution.
  ///
  /// Containment is re-checked here, after substitution and independently of
  /// `ArchiveValidator`, so no caller can write outside its target directory.
  String rename(String key) {
    final out = pathSubstitutor.apply(key);
    if (!isContainedArchivePath(out)) {
      throw FormatException(
        "Archive entry 'files/$key' is not a contained relative path "
        '(traversal, absolute, or drive-qualified).',
      );
    }
    return out;
  }

  /// The decoded text of [bytes], or null when the entry is copied verbatim.
  ///
  /// Verbatim means a binary extension, a `no_substitute` match, or content
  /// that is not valid UTF-8. Extension-based classification calls anything
  /// unlisted text, including extensionless files, so a "text" file can still
  /// hold non-UTF-8 bytes; falling back keeps it intact instead of aborting
  /// the unpack partway through. Classification stays extension-based — no
  /// content sniffing.
  String? decodeForSubstitution(String key, List<int> bytes) {
    final verbatim =
        classifier.isBinary(key) || noSubstitute.any((g) => g.matches(key));
    if (verbatim) {
      return null;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  /// Applies the content substitutions to [text].
  String substitute(String text) => contentSubstitutor.apply(text);

  /// How many substitutions [text] would receive.
  int countSubstitutions(String text) => contentSubstitutor.count(text);

  /// Encodes [text] back to bytes, restoring a BOM that [original] carried.
  ///
  /// `utf8.decode` silently drops a leading BOM and `utf8.encode` does not put
  /// it back, so a substituted file would lose three bytes on every unpack —
  /// even under an identity rename. Common in Windows-authored .bat, .ps1 and
  /// .csproj files.
  List<int> encodeSubstituted(List<int> original, String text) {
    final encoded = utf8.encode(text);
    return _startsWithBom(original) ? [..._utf8Bom, ...encoded] : encoded;
  }

  static bool _startsWithBom(List<int> bytes) =>
      bytes.length >= 3 &&
      bytes[0] == _utf8Bom[0] &&
      bytes[1] == _utf8Bom[1] &&
      bytes[2] == _utf8Bom[2];

  /// Renders each substitution's `to` template against [resolved].
  ///
  /// Rendering is late by necessity: the archive embeds `mold.yaml` verbatim
  /// and variable values are known only at unpack. Everything statically
  /// decidable — syntax, unknown variable, unknown transform — was already
  /// rejected by `ManifestValidator`, which runs at both pack and unpack.
  static Map<String, String> _render(
    List<Substitution> substitutions,
    Map<String, String> resolved,
  ) => {
    for (final s in substitutions)
      s.from: SubstitutionTemplate.parse(s.to).render(resolved),
  };

  /// Builds the case-variant replacement table from each variable's `replaces`
  /// token and its already-resolved value.
  static Map<String, String> _buildTable(
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
