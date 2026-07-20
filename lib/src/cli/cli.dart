import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../bundler/bundler.dart';
import '../manifest/manifest.dart';
import '../output/embed_source.dart';
import '../output/output_format.dart';
import '../prompt/variable_prompter.dart';
import '../prompt/variable_resolver.dart';
import '../unbundler/unbundler.dart';
import '../validation/validation_result.dart';

/// Thrown for user-facing CLI errors (bad args, missing files). The runner
/// turns it into a clean stderr message + exit code 64.
class CliException implements Exception {
  const CliException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _description =
    'Pack a project into a portable template archive and unpack it under a new '
    'name.';

/// Builds the `mold` command runner. [err] receives all human-facing
/// messages; it is injected so tests can capture output with a buffer.
CommandRunner<int> buildRunner(StringSink err) =>
    CommandRunner<int>('mold', _description)
      ..addCommand(PackCommand(err))
      ..addCommand(UnpackCommand(err));

/// Runs the `mold` CLI and returns its process exit code.
///
/// `0` ok, `1` IO/format failure, `64` usage error. Pure of `exit()` so it can
/// be driven from tests: pass a buffer for [err] to capture output.
Future<int> runBundleCli(List<String> args, {StringSink? err}) async {
  final sink = err ?? stderr;
  try {
    return await buildRunner(sink).run(args) ?? 0;
  } on UsageException catch (e) {
    sink
      ..writeln(e.message)
      ..writeln(e.usage);
    return 64;
  }
}

/// `mold pack <source_dir>` — capture a project into an archive.
class PackCommand extends Command<int> {
  PackCommand(this._err) {
    argParser
      ..addOption(
        'manifest',
        abbr: 'm',
        help: 'Path to the manifest (default: <dir>/mold.yaml).',
      )
      ..addOption(
        'output',
        abbr: 'o',
        help: 'Output path (default: ./<name>.mold).',
      )
      ..addOption(
        'name',
        abbr: 'n',
        help: 'Output file name stem (overrides manifest name).',
      )
      ..addOption(
        'format',
        abbr: 'f',
        allowed: OutputFormat.values.map((f) => f.flag),
        defaultsTo: OutputFormat.tarGz.flag,
        help: 'Output format: tar.gz file, or an embeddable Dart source.',
      );
  }

  final StringSink _err;

  @override
  String get name => 'pack';

  @override
  String get description => 'Pack a project directory into a template archive.';

  @override
  String get invocation => 'mold pack <source_dir> [options]';

  @override
  Future<int> run() async {
    final results = argResults!;
    try {
      if (results.rest.isEmpty) {
        throw const CliException('Missing <source_dir>.');
      }
      final sourceDir = results.rest.first;

      final manifestPath =
          (results['manifest'] as String?) ?? _defaultManifestPath(sourceDir);
      final manifest = Manifest.fromFile(manifestPath);
      final format = OutputFormat.fromFlag(results['format'] as String);

      final archive = await const Bundler().bundle(
        projectDir: sourceDir,
        manifest: manifest,
      );
      // One stem drives both the file name and the generated const identifier;
      // rendering from manifest.name here would make `-n foo` write foo.dart
      // declaring kDemoTemplate.
      final stem = (results['name'] as String?) ?? manifest.name;
      final content = _render(format, archive, stem);

      final ext = format == OutputFormat.tarGz ? 'mold' : 'dart';
      final outputPath = (results['output'] as String?) ?? './$stem.$ext';
      File(outputPath)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(content);

      _err.writeln('Wrote $outputPath (${content.length} bytes).');
      return 0;
    } on CliException catch (e) {
      _err.writeln(e.message);
      return 64;
    } on ValidationException catch (e) {
      _err.writeln(e.toString());
      return 1;
    } on FormatException catch (e) {
      _err.writeln(e.message);
      return 1;
    }
  }

  /// Renders the archive into the bytes to write for [format]: raw archive for
  /// `tar.gz`, or the UTF-8 of an embeddable Dart source otherwise.
  List<int> _render(OutputFormat format, List<int> archive, String name) {
    const embed = EmbedSource();
    switch (format) {
      case .tarGz:
        return archive;
      case .bytes:
        return utf8.encode(embed.bytesSource(archive: archive, name: name));
      case .base64:
        return utf8.encode(embed.base64Source(archive: archive, name: name));
    }
  }

  /// Resolves the default manifest path. There is no fallback: if the default
  /// `mold.yaml` is absent and `-m` was not given, it is an error.
  String _defaultManifestPath(String sourceDir) {
    final path = p.join(sourceDir, 'mold.yaml');
    if (!File(path).existsSync()) {
      throw CliException(
        "No manifest: '$path' not found and --manifest not given.",
      );
    }
    return path;
  }
}

/// `mold unpack <source>` — materialize a project from an archive.
class UnpackCommand extends Command<int> {
  UnpackCommand(this._err) {
    argParser
      ..addOption(
        'target',
        abbr: 't',
        help: 'Destination dir (default: ./<name>).',
      )
      ..addMultiOption(
        'var',
        abbr: 'v',
        help: 'Variable value as key=value (repeatable).',
      )
      ..addFlag(
        'no-prompt',
        negatable: false,
        help: 'Never prompt; use --var values and manifest defaults only.',
      );
  }

  final StringSink _err;

  @override
  String get name => 'unpack';

  @override
  String get description =>
      'Unpack a template archive into a target directory.';

  @override
  String get invocation => 'mold unpack <source> [options]';

  @override
  Future<int> run() async {
    final results = argResults!;
    try {
      if (results.rest.isEmpty) {
        throw const CliException('Missing <source>.');
      }

      final source = results.rest.first;

      final targetDir =
          (results['target'] as String?) ??
          './${p.basenameWithoutExtension(source)}';
      final vars = _parseVars(results['var'] as List<String>);

      final resolver = VariableResolver(
        noPrompt: results['no-prompt'] as bool,
        prompter: VariablePrompter(_err, stdin.readLineSync),
      );

      await const Unbundler().unbundleFile(
        source: source,
        targetDir: targetDir,
        vars: vars,
        resolver: resolver,
      );
      _err.writeln('Unpacked into $targetDir.');
      return 0;
    } on CliException catch (e) {
      _err.writeln(e.message);
      return 64;
    } on ValidationException catch (e) {
      _err.writeln(e.toString());
      return 1;
    } on FormatException catch (e) {
      _err.writeln(e.message);
      return 1;
    }
  }

  /// Parses repeated `key=value` pairs into a map. Splits on the first `=`.
  Map<String, String> _parseVars(List<String> raw) {
    final out = <String, String>{};
    for (final entry in raw) {
      final eq = entry.indexOf('=');
      if (eq <= 0) {
        throw CliException("Invalid --var '$entry'; expected key=value.");
      }
      out[entry.substring(0, eq)] = entry.substring(eq + 1);
    }
    
    return out;
  }
}
