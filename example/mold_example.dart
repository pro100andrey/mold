// A runnable tour of mold's library API: pack a real project into a template
// archive, then unpack it under a new name with manifest-driven renaming.
//
//   dart run example/mold_example.dart
//
// The manifest is read from `mold.yaml` beside this file — the same file the
// CLI would take with `-m` — rather than being built inline, so this mirrors
// real use. See example/README.md for the equivalent CLI commands.
import 'dart:io';

import 'package:mold/mold.dart';

Future<void> main() async {
  // The manifest lives next to this script, exactly as it lives next to a real
  // project on disk.
  final manifestPath = File.fromUri(Platform.script.resolve('mold.yaml')).path;
  final manifest = Manifest.fromFile(manifestPath);

  final work = Directory.systemTemp.createTempSync('mold_example_');
  try {
    // A tiny source project named `super_server`, the token the manifest
    // renames. It has to actually contain the token, or pack refuses it.
    final source = Directory('${work.path}/super_server')
      ..createSync(recursive: true);
    File('${source.path}/pubspec.yaml').writeAsStringSync(
      'name: super_server\n',
    );
    File('${source.path}/lib/super_server.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync("const banner = 'Welcome to Super Server';\n");

    // Pack. The archive is a verbatim snapshot — no substitution happens here,
    // so one archive can be unpacked under many names.
    final archive = await const Bundler().bundle(
      projectDir: source.path,
      manifest: manifest,
    );
    stdout.writeln('Packed ${archive.length} bytes.');

    // Unpack under a new name. Substitution happens now.
    final out = '${work.path}/acme_shop';
    await const Unbundler().unbundleBytes(
      source: archive,
      targetDir: out,
      vars: const {'project_name': 'acme_shop'},
    );

    // The token is gone in every form — the path, the pubspec, and the banner.
    final pubspec = File('$out/pubspec.yaml').readAsStringSync().trim();
    final banner = File('$out/lib/acme_shop.dart').readAsStringSync().trim();
    stdout
      ..writeln('Unpacked into $out:')
      ..writeln('  $pubspec')
      ..writeln('  $banner');
  } finally {
    work.deleteSync(recursive: true);
  }
}
