@TestOn('!windows')
library;

import 'dart:io';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

bool _isExecutable(String path) => File(path).statSync().mode & 64 != 0;

void main() {
  group('executable bit', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_mode_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('survives a pack/unpack round trip', () async {
      final src = Directory('${tmp.path}/src')..createSync(recursive: true);
      final script = File('${src.path}/setup.sh')
        ..writeAsStringSync('#!/bin/sh\necho super_server\n');
      File('${src.path}/README.md').writeAsStringSync('super_server');
      Process.runSync('chmod', ['+x', script.path]);
      expect(_isExecutable(script.path), isTrue, reason: 'test precondition');

      const manifest = Manifest(
        name: 'demo',
        version: '1.0.0',
        variables: [
          TemplateVariable(
            name: 'project_name',
            defaultValue: 'my_project',
            replaces: 'super_server',
          ),
        ],
      );

      final archive = await const Bundler().bundle(
        projectDir: src.path,
        manifest: manifest,
      );
      await const Unbundler().unbundleBytes(
        source: archive,
        targetDir: '${tmp.path}/out',
        vars: const {'project_name': 'my_project'},
      );

      expect(_isExecutable('${tmp.path}/out/setup.sh'), isTrue);
      expect(
        _isExecutable('${tmp.path}/out/README.md'),
        isFalse,
        reason: 'non-executable files must not gain the bit',
      );
      // Content substitution still applied to the executable file.
      expect(
        File('${tmp.path}/out/setup.sh').readAsStringSync(),
        contains('my_project'),
      );
    });

    test('the archive records which entries are executable', () async {
      final src = Directory('${tmp.path}/src')..createSync(recursive: true);
      final script = File('${src.path}/run.sh')..writeAsStringSync('#!/bin/sh');
      File('${src.path}/plain.txt').writeAsStringSync('x');
      Process.runSync('chmod', ['+x', script.path]);

      final archive = await const Bundler().bundle(
        projectDir: src.path,
        manifest: const Manifest(name: 'demo', version: '1.0.0'),
      );

      final read = const ArchiveReader().read(archive);
      expect(read.executable, contains('run.sh'));
      expect(read.executable, isNot(contains('plain.txt')));
    });
  });
}
