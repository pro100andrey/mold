import 'dart:io';

import 'package:mold/mold.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'embed_source_test.dart' show parseBytesSource;

void main() {
  group('unbundleBytes + embed round-trip', () {
    late Directory tmp;
    late Directory project;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mold_bytes_');
      project = Directory(p.join(tmp.path, 'super_server'))
        ..createSync(recursive: true);
      File(p.join(project.path, 'lib/super_server.dart'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('class SuperServer {} // super_server\n');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    Manifest manifest() => Manifest.fromYaml('''
name: super_server
version: 1.0.0
variables:
  project_name:
    default: my_project
    replaces: super_server
''');

    test('the base classes are implemented', () {
      expect(const Bundler(), isA<BundlerBase>());
      expect(const Unbundler(), isA<UnbundlerBase>());
    });

    test('unbundleBytes matches unbundleFile from the same archive', () async {
      final archive = await const Bundler().bundle(
        projectDir: project.path,
        manifest: manifest(),
      );
      final archivePath = p.join(tmp.path, 'tpl.mold');
      File(archivePath).writeAsBytesSync(archive);

      final fromFile = p.join(tmp.path, 'from_file');
      await const Unbundler().unbundleFile(
        source: archivePath,
        targetDir: fromFile,
        vars: {'project_name': 'my_project'},
      );

      final fromBytes = p.join(tmp.path, 'from_bytes');
      await const Unbundler().unbundleBytes(
        source: archive,
        targetDir: fromBytes,
        vars: {'project_name': 'my_project'},
      );

      expect(_snapshot(Directory(fromBytes)), _snapshot(Directory(fromFile)));
    });

    test(
      'bundle → emit bytes source → load → unbundleBytes → renamed tree',
      () async {
        final archive = await const Bundler().bundle(
          projectDir: project.path,
          manifest: manifest(),
        );

        // Emit the embeddable bytes source, then load the archive back from it
        // exactly as a generated file would.
        final src = const EmbedSource().bytesSource(
          archive: archive,
          name: 'super_server',
        );
        final loaded = parseBytesSource(src);
        expect(loaded, archive);

        final out = p.join(tmp.path, 'out');
        await const Unbundler().unbundleBytes(
          source: loaded,
          targetDir: out,
          vars: {'project_name': 'my_project'},
        );

        // Path renamed and content substituted from the in-memory bytes.
        final file = File(p.join(out, 'lib/my_project.dart'));
        expect(file.existsSync(), isTrue);
        expect(file.readAsStringSync(), 'class MyProject {} // my_project\n');
      },
    );
  });
}

/// Maps every file under [dir] to its bytes (relative paths), for tree compare.
Map<String, List<int>> _snapshot(Directory dir) {
  final out = <String, List<int>>{};
  for (final e in dir.listSync(recursive: true)) {
    if (e is File) {
      out[p.relative(e.path, from: dir.path)] = e.readAsBytesSync();
    }
  }
  return out;
}
