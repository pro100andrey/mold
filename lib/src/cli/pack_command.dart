import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../archive/archive_diff.dart';
import '../archive/archive_reader.dart';
import '../archive/archive_validator.dart';
import '../archive/archive_writer.dart';
import '../bundler/bundler.dart';
import '../bundler/project_validator.dart';
import '../manifest/manifest.dart';
import '../output/embed_source.dart';
import '../output/output_format.dart';
import '../prompt/variable_resolver.dart';
import '../unbundler/unbundler.dart';
import '../validation/validation_error.dart';
import 'command_base.dart';
import 'plan_report.dart';

/// `mold pack <source_dir>` — capture a project into an archive.
class PackCommand extends MoldCommand {
  PackCommand(super.out, super.err) {
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
      ..addOption(
        'level',
        help: 'gzip level, 0 (store, fastest) to 9 (smallest).',
        defaultsTo: '${ArchiveWriter.defaultLevel}',
      )
      ..addFlag(
        'fast',
        negatable: false,
        help:
            "Compress with the Dart VM's zlib: ~2.7x faster, but the bytes may "
            'differ across OS and SDK versions.',
      );
    addVarOptions(', for previewing with --diff');
    argParser
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
      )
      ..addFlag(
        'check',
        negatable: false,
        help:
            'Exit 1 if the output file is not what packing would write now; '
            'write nothing. For CI over a committed archive or embed source.',
      );
  }

  @override
  String get name => 'pack';

  @override
  String get description => 'Pack a project directory into a template archive.';

  @override
  String get invocation => 'mold pack <source_dir> [options]';

  @override
  Future<int> execute(ArgResults results) async {
    if (results.rest.isEmpty) {
      throw const CliException('Missing <source_dir>.');
    }
    final sourceDir = results.rest.first;
    final check = results['check'] as bool;
    if (check && (results['dry-run'] as bool || results['diff'] as bool)) {
      throw const CliException(
        '--check compares what packing would write; it cannot be combined '
        'with --dry-run or --diff.',
      );
    }

    final manifestPath =
        (results['manifest'] as String?) ?? _defaultManifestPath(sourceDir);
    final manifest = Manifest.fromFile(manifestPath);
    final format = OutputFormat.fromFlag(results['format'] as String);
    final level = _level(results['level'] as String);

    final packVars = varsOf(results);
    if (results['diff'] as bool) {
      return _previewPack(sourceDir, manifest, packVars);
    }

    if (packVars.vars.isNotEmpty || packVars.recorded.isNotEmpty) {
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

    // One stem drives both the file name and the generated const identifier;
    // rendering from manifest.name here would make `-n foo` write foo.dart
    // declaring kDemoTemplate.
    final stem = (results['name'] as String?) ?? manifest.name;
    final ext = format == OutputFormat.tarGz ? 'mold' : 'dart';
    final outputPath = (results['output'] as String?) ?? './$stem.$ext';

    if (check) {
      // Compared by content, so nothing needs compressing.
      final current = collectBundle(
        projectDir: sourceDir,
        manifest: manifest,
        onWarning: warn,
      );
      return _check(outputPath, format, stem, current);
    }

    final archive = await Bundler(
      compressionLevel: level,
      fastCompression: results['fast'] as bool,
    ).bundle(projectDir: sourceDir, manifest: manifest, onWarning: warn);
    final content = _render(format, archive, stem);
    File(outputPath)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(content);

    if (wantsJson) {
      emitJson({'output': outputPath, 'bytes': content.length});
    } else {
      err.writeln('Wrote $outputPath (${content.length} bytes).');
    }
    return 0;
  }

  /// Whether the file at [outputPath] holds what packing would write now,
  /// writing nothing.
  ///
  /// Compared by content, not by bytes. The archive is unpacked from the
  /// committed file — from inside the Dart source, for an embed format — and
  /// its manifest, files and executable bits compared with [current]. A
  /// byte comparison failed whenever the compressor differed while the
  /// content did not: another OS, another Dart SDK, another `--level`.
  ///
  /// An embed source must also be exactly what this mold renders around the
  /// archive it holds — the declaration's name, the layout, the header — so a
  /// changed `-n` or a newer mold's rendering is stale too.
  int _check(
    String outputPath,
    OutputFormat format,
    String stem,
    BundleArchive current,
  ) {
    final reasons = _staleness(outputPath, format, stem, current);
    final upToDate = reasons.isEmpty;

    if (wantsJson) {
      emitJson({'output': outputPath, 'upToDate': upToDate, 'stale': reasons});
    } else if (upToDate) {
      err.writeln('Up to date: $outputPath.');
    } else {
      err.writeln(
        'Stale: $outputPath — ${reasons.join('; ')}. Run without --check to '
        'regenerate it.',
      );
    }

    return upToDate ? 0 : 1;
  }

  /// Why [outputPath] is not what packing writes now; empty when it is.
  List<String> _staleness(
    String outputPath,
    OutputFormat format,
    String stem,
    BundleArchive current,
  ) {
    final file = File(outputPath);
    if (!file.existsSync()) {
      return ['it does not exist'];
    }
    final bytes = file.readAsBytesSync();

    final List<int> committed;
    final reasons = <String>[];
    if (format == .tarGz) {
      committed = bytes;
    } else {
      final String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        return ['it is not a Dart source'];
      }
      final embedded = const EmbedSource().archiveOf(text);
      if (embedded == null) {
        return ['it holds no ${format.flag} archive mold would write'];
      }
      committed = embedded;
      // As text with LF endings: a Windows checkout turns a committed source's
      // LF into CRLF (core.autocrlf), which is not a change to it.
      final rendered = utf8.decode(_render(format, embedded, stem));
      if (text.replaceAll('\r\n', '\n') != rendered) {
        reasons.add(
          'the source around the archive differs (its name, layout or the '
          'mold version that wrote it)',
        );
      }
    }

    final inspected = const ArchiveValidator().inspect(committed);
    if (inspected.tar == null || !inspected.result.isValid) {
      return [...reasons, 'its archive is not a valid template'];
    }
    final diff = ArchiveDiff(
      const ArchiveReader().fromTar(inspected.tar!),
      current,
    );

    return [...reasons, ...diff.describe()];
  }

  /// Validates and reports what a pack would capture, without writing.
  ///
  /// A preflight rather than a preview of substitution: packing performs no
  /// substitution at all, so there is nothing to diff. What it can tell you is
  /// whether the manifest is right — which files land in the template, which
  /// symlinks were left out and why, and whether every `replaces` token is
  /// distinctive enough to be safe.
  int _dryRunPack(String sourceDir, Manifest manifest) {
    // One scan, shared with the validator — see Bundler.bundle.
    final scanned = Directory(sourceDir).existsSync()
        ? ProjectValidator.scanFor(sourceDir, manifest)
        : null;
    const ProjectValidator()
        .validate(
          ProjectInput(dir: sourceDir, manifest: manifest, scan: scanned),
        )
        .report(warn);

    // Falls back rather than asserting — see Bundler.bundle.
    final scan = scanned ?? ProjectValidator.scanFor(sourceDir, manifest);

    if (wantsJson) {
      emitJson({
        'files': scan.files,
        'gitignored': scan.gitignored,
        'skippedLinks': {
          for (final MapEntry(:key, :value) in scan.skippedLinks.entries)
            key: value.name,
        },
      });
      return 0;
    }

    err.writeln(
      'Dry run — nothing written. ${scan.files.length} files would be '
      'captured, ${scan.gitignored} gitignored, '
      '${scan.skippedLinks.length} symlinks skipped.',
    );
    for (final rel in scan.files) {
      err.writeln('  $rel');
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
  /// Values come from `--var`, `--vars-file` and manifest defaults only;
  /// `pack` never prompts, so it stays usable from CI.
  Future<int> _previewPack(
    String sourceDir,
    Manifest manifest,
    ({Map<String, String> vars, Map<String, String> recorded}) values,
  ) async {
    // Packing and planning both validate the manifest, so its warnings come
    // twice; each is reported once. Dropping the planner's warnings instead
    // hid the ones only an unpack raises — a value already in the template, a
    // rename differing only in case — from the preview meant to show them.
    final seen = <String>{};
    void warnOnce(ValidationError w) {
      if (seen.add('${w.code}\u0000${w.field}\u0000${w.message}')) {
        warn(w);
      }
    }

    final archive = await const Bundler().bundle(
      projectDir: sourceDir,
      manifest: manifest,
      onWarning: warnOnce,
    );
    final plan = const Unbundler().plan(
      bytes: archive,
      vars: values.vars,
      recorded: values.recorded,
      resolver: const VariableResolver(noPrompt: true),
      onWarning: warnOnce,
    );

    if (wantsJson) {
      emitJson(planJson(plan, showDiff: true, applied: false));
    } else {
      err.writeln('Preview — nothing written.');
      printPlan(err, plan, showDiff: true, applied: false);
    }

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

  static int _level(String raw) {
    final level = int.tryParse(raw);
    if (level == null || level < 0 || level > 9) {
      throw CliException('--level must be 0 to 9, got: $raw');
    }

    return level;
  }
}
