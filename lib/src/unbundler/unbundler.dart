import 'dart:convert';
import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../archive/archive_path.dart';
import '../archive/archive_reader.dart';
import '../archive/archive_validator.dart';
import '../bundler/file_classifier.dart';
import '../manifest/manifest.dart';
import '../manifest/manifest_validator.dart';
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
  /// [resolver], unresolved variables fall back to the manifest `default` or,
  /// lacking one, throw.
  @override
  Future<void> unbundle({
    required List<int> bytes,
    required String targetDir,
    Map<String, String> vars = const {},
    VariableResolver? resolver,
  }) {
    // Phase order: archive → manifest → variables → target. The first failing
    // phase aborts before the next runs.
    const ArchiveValidator().validate(bytes).throwIfInvalid();
    final archive = const ArchiveReader().read(bytes);
    final manifest = Manifest.fromYaml(archive.manifestYaml);
    const ManifestValidator().validate(manifest).throwIfInvalid();

    final resolved = (resolver ?? const VariableResolver()).resolve(
      manifest.variables,
      vars,
    );
    const VariablesValidator()
        .validate(
          VariablesInput(variables: manifest.variables, values: resolved),
        )
        .throwIfInvalid();
    const TargetValidator().validate(targetDir).throwIfInvalid();

    _write(archive, manifest, targetDir, resolved);

    return .value();
  }

  /// Unpacks a project directly from in-memory archive [source] bytes (e.g. an
  /// embedded `const List<int>` template). Delegates to [unbundle].
  Future<void> unbundleBytes({
    required List<int> source,
    required String targetDir,
    Map<String, String> vars = const {},
    VariableResolver? resolver,
  }) => unbundle(
    bytes: source,
    targetDir: targetDir,
    vars: vars,
    resolver: resolver,
  );

  /// Reads the archive at the file [source] and unpacks it into [targetDir].
  Future<void> unbundleFile({
    required String source,
    required String targetDir,
    Map<String, String> vars = const {},
    VariableResolver? resolver,
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
  ) {
    final renames = _buildTable(manifest, resolved);
    final pathSubstitutor = Substitutor(renames);
    final contentSubstitutor = Substitutor({
      ...renames,
      for (final s in manifest.extraSubstitutions) s.from: s.to,
    });
    final classifier = FileClassifier(
      extraBinary: manifest.binaryExtensions.toSet(),
    );
    final noSubstitute = manifest.noSubstitute.map(Glob.new).toList();

    final target = Directory(targetDir)..createSync(recursive: true);
    for (final entry in archive.files.entries) {
      final outRel = pathSubstitutor.apply(entry.key);
      // Re-checked after substitution, and independently of ArchiveValidator,
      // so a direct library call can never write outside its target directory.
      if (!isContainedArchivePath(outRel)) {
        throw FormatException(
          "Archive entry escapes the target directory: 'files/${entry.key}'.",
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
        out.writeAsStringSync(contentSubstitutor.apply(decoded));
      }
    }
  }

  /// Decodes [bytes] as UTF-8, or returns null when they are not valid UTF-8.
  String? _tryDecodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

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
