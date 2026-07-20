import 'dart:io';
import 'dart:typed_data';

import 'package:mold/mold.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Verbatim bundle/unbundle round-trip', () {
    late Directory tmp;
    late Directory project;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mold_rt_');
      project = Directory(p.join(tmp.path, 'super_server'))
        ..createSync(recursive: true);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    void writeText(String rel, String content) {
      File(p.join(project.path, rel))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    void writeBytes(String rel, List<int> bytes) {
      File(p.join(project.path, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);
    }

    Manifest manifest({List<String> exclude = const []}) => Manifest.fromYaml(
      [
        'name: super_server',
        'version: 1.0.0',
        if (exclude.isNotEmpty) 'exclude:',
        for (final e in exclude) '  - $e',
      ].join('\n'),
    );

    test('bundles and unbundles a mixed tree byte-for-byte', () async {
      // A non-trivial binary payload (all 256 byte values).
      final binary = Uint8List.fromList(List.generate(256, (i) => i));
      writeText('mold.yaml', 'name: super_server\nversion: 1.0.0\n');
      writeText('lib/main.dart', 'void main() => print("hi");\n');
      writeText('lib/nested/util.dart', 'const answer = 42;\n');
      writeBytes('assets/logo.png', binary);

      final bytes = await const Bundler().bundle(
        projectDir: project.path,
        manifest: manifest(),
      );

      final archivePath = p.join(tmp.path, 'out.mold');
      File(archivePath).writeAsBytesSync(bytes);

      final outDir = p.join(tmp.path, 'extracted');
      await const Unbundler().unbundleFile(
        source: archivePath,
        targetDir: outDir,
      );

      expect(
        File(p.join(outDir, 'lib/main.dart')).readAsStringSync(),
        'void main() => print("hi");\n',
      );
      expect(
        File(p.join(outDir, 'lib/nested/util.dart')).readAsStringSync(),
        'const answer = 42;\n',
      );
      expect(
        File(p.join(outDir, 'assets/logo.png')).readAsBytesSync(),
        binary,
      );
    });

    test('honors exclude globs', () async {
      writeText('keep.txt', 'keep');
      writeText('build/skip.txt', 'skip');

      final bytes = await const Bundler().bundle(
        projectDir: project.path,
        manifest: manifest(exclude: ['build/**']),
      );
      final archive = const ArchiveReader().read(bytes);

      expect(archive.files.keys, contains('keep.txt'));
      expect(archive.files.keys, isNot(contains('build/skip.txt')));
    });

    test('does not mutate the source directory', () async {
      writeText('a.txt', 'a');
      final before = _snapshot(project);

      await const Bundler().bundle(
        projectDir: project.path,
        manifest: manifest(),
      );

      expect(_snapshot(project), before);
    });

    test('embeds the verbatim manifest yaml', () async {
      writeText('a.txt', 'a');
      const yaml = 'name: super_server\nversion: 1.0.0\n';

      final bytes = await const Bundler().bundle(
        projectDir: project.path,
        manifest: Manifest.fromYaml(yaml),
      );

      expect(const ArchiveReader().read(bytes).manifestYaml, yaml);
    });
  });
}

/// Maps every file under [dir] to its bytes, for mutation checks.
Map<String, List<int>> _snapshot(Directory dir) {
  final out = <String, List<int>>{};
  for (final e in dir.listSync(recursive: true)) {
    if (e is File) {
      out[p.relative(e.path, from: dir.path)] = e.readAsBytesSync();
    }
  }
  return out;
}
