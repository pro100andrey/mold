import 'dart:io';

import 'package:mold/mold.dart';

/// Entry point for the `mold` CLI (`mold pack` / `mold unpack`). All
/// command logic lives in `lib/src/cli/cli.dart` so it can be unit-tested
/// without `exit()`.
Future<void> main(List<String> args) async {
  exitCode = await runBundleCli(args);
}
