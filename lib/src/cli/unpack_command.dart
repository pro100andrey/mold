import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../prompt/variable_prompter.dart';
import '../prompt/variable_resolver.dart';
import '../unbundler/unbundler.dart';
import 'command_base.dart';
import 'plan_report.dart';

/// `mold unpack <source>` — materialize a project from an archive.
class UnpackCommand extends MoldCommand {
  UnpackCommand(super.out, super.err) {
    argParser.addOption(
      'target',
      abbr: 't',
      help: 'Destination dir (default: ./<name>).',
    );
    addVarOptions('');
    argParser
      ..addFlag(
        'no-prompt',
        negatable: false,
        help: 'Never prompt; use --var values and manifest defaults only.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help:
            "Unpack into a non-empty target: write the template's files over "
            'the same paths, leave every other file as it is.',
      )
      ..addFlag(
        'stamp',
        negatable: false,
        help:
            'Record the template, values and files in <target>/.mold.json, '
            'for regenerating later. Kept up to date once present.',
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

  @override
  String get name => 'unpack';

  @override
  String get description =>
      'Unpack a template archive into a target directory.';

  @override
  String get invocation => 'mold unpack <source> [options]';

  @override
  Future<int> execute(ArgResults results) async {
    if (results.rest.isEmpty) {
      throw const CliException('Missing <source>.');
    }
    final source = results.rest.first;

    final targetDir =
        (results['target'] as String?) ??
        './${p.basenameWithoutExtension(source)}';
    final vars = varsOf(results);

    final resolver = VariableResolver(
      noPrompt: results['no-prompt'] as bool,
      // Prompts are for a person, so they go where people read: stderr,
      // never into a --json document.
      prompter: VariablePrompter(err, stdin.readLineSync),
    );

    final showDiff = results['diff'] as bool;
    // --diff implies --dry-run: there is no such thing as diffing a write
    // that already happened, so the combination cannot be invalid.
    final dryRun = showDiff || results['dry-run'] as bool;

    // One plan, applied as it was shown: the preview and the write are the
    // same computation.
    const unbundler = Unbundler();
    final plan = unbundler.plan(
      bytes: Unbundler.readArchive(source),
      targetDir: targetDir,
      vars: vars,
      resolver: resolver,
      overwrite: results['force'] as bool,
      stamp: results['stamp'] as bool,
      // A summary needs counts, not content.
      withContent: showDiff,
      onWarning: warn,
    );
    if (!dryRun) {
      await unbundler.apply(plan, onWarning: warn);
    }

    if (wantsJson) {
      emitJson(planJson(plan, showDiff: showDiff, applied: !dryRun));
    } else if (dryRun) {
      printPlan(err, plan, showDiff: showDiff, applied: false);
    } else {
      err.writeln('Unpacked into $targetDir.');
    }

    return 0;
  }
}
