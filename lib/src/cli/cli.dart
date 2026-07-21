import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../bundler/bundler.dart';
import '../bundler/file_scanner.dart';
import '../bundler/project_validator.dart';
import '../manifest/manifest.dart';
import '../output/embed_source.dart';
import '../output/output_format.dart';
import '../output/unified_diff.dart';
import '../prompt/variable_prompter.dart';
import '../prompt/variable_resolver.dart';
import '../unbundler/unbundler.dart';
import '../unbundler/unpack_plan.dart';
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
/// `0` ok, `1` validation / IO / format failure, `64` usage error. Pure of
/// `exit()` so it can be driven from tests: pass a buffer for [err] to capture
/// output.
Future<int> runBundleCli(List<String> args, {StringSink? err}) async {
  final sink = err ?? stderr;
  try {
    return await buildRunner(sink).run(args) ?? 0;
  } on UsageException catch (e) {
    sink
      ..writeln(e.message)
      ..writeln(e.usage);
    return 64;
  } on IOException catch (e) {
    // One clause here rather than in each command: both bodies already run
    // inside this try, so pack, unpack and any future subcommand are covered.
    // IOException, not FileSystemException, so no future IO source escapes —
    // writeAsBytesSync, readAsBytesSync, listSync and Process.runSync all
    // throw subtypes of it. Without this the CLI exits 255 with a stack trace
    // on an ordinary permissions or missing-directory failure.
    sink.writeln(e.toString());
    return 1;
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
      )
      ..addMultiOption(
        'var',
        abbr: 'v',
        help: 'Variable value as key=value, for previewing with --diff.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Validate and list what would be captured, without writing.',
      )
      ..addFlag(
        'diff',
        negatable: false,
        help:
            'Preview the renames this manifest would make '
            '(implies --dry-run).',
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

      final packVars = _parseVars(results['var'] as List<String>);
      if (results['diff'] as bool) {
        return _previewPack(sourceDir, manifest, packVars);
      }

      if (packVars.isNotEmpty) {
        // Packing substitutes nothing, so a value passed here can only be for
        // the preview. Silently dropping it would leave the user believing it
        // took effect.
        throw const CliException(
          '--var only affects `pack --diff`; packing performs no '
          'substitution. Drop it, or add --diff to preview.',
        );
      }

      if (results['dry-run'] as bool) {
        return _dryRunPack(sourceDir, manifest);
      }

      final archive = await const Bundler().bundle(
        projectDir: sourceDir,
        manifest: manifest,
        onWarning: (message) => _err.writeln('Warning: $message'),
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

  /// Validates and reports what a pack would capture, without writing.
  ///
  /// A preflight rather than a preview of substitution: packing performs no
  /// substitution at all, so there is nothing to diff. What it can tell you is
  /// whether the manifest is right — which files land in the template, which
  /// symlinks were left out and why, and whether every `replaces` token is
  /// distinctive enough to be safe.
  int _dryRunPack(String sourceDir, Manifest manifest) {
    final result = const ProjectValidator().validate(
      ProjectInput(dir: sourceDir, manifest: manifest),
    );
    for (final warning in result.warnings) {
      _err.writeln('Warning: $warning');
    }

    if (!result.isValid) {
      _err.writeln(ValidationException(result.errors).toString());
      return 1;
    }

    final scan = FileScanner(
      include: manifest.include,
      exclude: manifest.exclude,
      useGitignore: manifest.useGitignore,
    ).scan(sourceDir);

    _err.writeln(
      'Dry run — nothing written. ${scan.files.length} files would be '
      'captured, ${scan.gitignored} gitignored, '
      '${scan.skippedLinks.length} symlinks skipped.',
    );

    for (final rel in scan.files) {
      _err.writeln('  $rel');
    }

    return 0;
  }

  /// Previews the renames this manifest would make, without writing anything.
  ///
  /// Packing itself substitutes nothing, so there is no diff in the pack step
  /// — but the question a template author actually has is "are my rules
  /// right", and answering it should not require distributing the template
  /// first. The archive is built in memory and handed straight to the same
  /// planner `unpack --diff` uses, with no destination.
  ///
  /// Values come from `--var` and manifest defaults only; `pack` never
  /// prompts, so it stays usable from CI.
  Future<int> _previewPack(
    String sourceDir,
    Manifest manifest,
    Map<String, String> vars,
  ) async {
    final archive = await const Bundler().bundle(
      projectDir: sourceDir,
      manifest: manifest,
      onWarning: (message) => _err.writeln('Warning: $message'),
    );
    final plan = const Unbundler().plan(
      bytes: archive,
      vars: vars,
      resolver: const VariableResolver(noPrompt: true),
    );

    _err.writeln('Preview — nothing written.');
    _printPlan(_err, plan, null, showDiff: true);

    return 0;
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
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Show what would be written, without writing it.',
      )
      ..addFlag(
        'diff',
        negatable: false,
        help: 'With --dry-run, also show a unified diff of the changes.',
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

      final showDiff = results['diff'] as bool;
      // --diff implies --dry-run: there is no such thing as diffing a write
      // that already happened, so the combination cannot be invalid.
      if (showDiff || results['dry-run'] as bool) {
        final file = File(source);
        if (!file.existsSync()) {
          throw FormatException('Archive not found: $source');
        }

        _printPlan(
          _err,
          const Unbundler().plan(
            bytes: file.readAsBytesSync(),
            targetDir: targetDir,
            vars: vars,
            resolver: resolver,
            // A summary needs counts, not content.
            withContent: showDiff,
          ),
          targetDir,
          showDiff: showDiff,
        );

        return 0;
      }

      await const Unbundler().unbundleFile(
        source: source,
        targetDir: targetDir,
        vars: vars,
        resolver: resolver,
        onWarning: (message) => _err.writeln('Warning: $message'),
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
}

/// Prints what an unpack would do: a summary, the renames, the per-file
/// replacement counts, and optionally a unified diff of each change.
///
/// Files nothing happens to are counted but not listed — a template is
/// mostly unchanged files, and listing them buries the ones that matter.
void _printPlan(
  StringSink err,
  UnpackPlan plan,
  String? targetDir, {
  required bool showDiff,
}) {
  final renamed = plan.renamed.toList();
  final rewritten = plan.rewritten.toList();

  if (targetDir != null) {
    err.writeln('Dry run — nothing written to $targetDir.');
  }
  err.writeln(
    '  ${plan.files.length} files: ${renamed.length} renamed, '
    '${rewritten.length} rewritten (${plan.totalReplacements} '
    'replacements), ${plan.untouched.length} unchanged.',
  );

  if (renamed.isNotEmpty) {
    err.writeln('\nRenamed:');
    for (final f in renamed) {
      final count = f.replacements > 0 ? '  (${f.replacements})' : '';
      err.writeln('  ${f.from}  ->  ${f.to}$count');
    }
  }

  final contentOnly = rewritten.where((f) => !f.renamed).toList();
  if (contentOnly.isNotEmpty) {
    err.writeln('\nRewritten:');
    for (final f in contentOnly) {
      err.writeln('  ${f.to}  (${f.replacements})');
    }
  }

  if (!showDiff) {
    if (rewritten.isNotEmpty) {
      err.writeln('\nRe-run with --diff to see the content changes.');
    }
    return;
  }

  const differ = UnifiedDiff();
  for (final f in rewritten) {
    final before = f.before;
    final after = f.after;
    if (before == null || after == null) {
      continue;
    }

    final rendered = differ.render(
      before: before,
      after: after,
      fromLabel: f.from,
      toLabel: f.to,
    );
    if (rendered.isNotEmpty) {
      err
        ..writeln()
        ..write(rendered);
    }
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
