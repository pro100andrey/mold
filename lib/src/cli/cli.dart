import 'dart:io';

import 'package:args/command_runner.dart';

import 'inspect_command.dart';
import 'pack_command.dart';
import 'unpack_command.dart';

export 'command_base.dart' show CliException;

const _description =
    'Pack a project into a portable template archive and unpack it under a new '
    'name.';

/// Builds the `mold` command runner. [out] receives a command's product
/// (`--json`), [err] everything meant for a person; both are injected so tests
/// can capture them with a buffer.
CommandRunner<int> buildRunner(StringSink out, StringSink err) =>
    CommandRunner<int>('mold', _description)
      ..addCommand(PackCommand(out, err))
      ..addCommand(UnpackCommand(out, err))
      ..addCommand(InspectCommand(out, err));

/// Runs the `mold` CLI and returns its process exit code.
///
/// `0` ok, `1` validation / IO / format failure (and a stale `pack --check`),
/// `64` usage error. Pure of `exit()` so it can be driven from tests: pass
/// buffers for [out] and [err] to capture output.
Future<int> runBundleCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
}) async {
  final errSink = err ?? stderr;
  try {
    return await buildRunner(out ?? stdout, errSink).run(args) ?? 0;
  } on UsageException catch (e) {
    errSink
      ..writeln(e.message)
      ..writeln(e.usage);
    return 64;
  } on IOException catch (e) {
    // One clause here rather than in each command: every body already runs
    // inside this try, so any subcommand is covered. IOException, not
    // FileSystemException, so no future IO source escapes —
    // writeAsBytesSync, readAsBytesSync, listSync and Process.runSync all
    // throw subtypes of it. Without this the CLI exits 255 with a stack trace
    // on an ordinary permissions or missing-directory failure.
    errSink.writeln(e.toString());
    return 1;
  }
}
