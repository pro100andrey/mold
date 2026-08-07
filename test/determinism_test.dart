import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mold/mold.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Deterministic archives', () {
    // The load-bearing assertion. Packing twice and comparing bytes would pass
    // even with a clock-derived mtime — both packs land in the same second —
    // so the guarantee is checked at the header field it lives in.
    test('no entry carries the time it was packed', () {
      final bytes = const ArchiveWriter().write(
        manifestYaml: 'name: super_server\nversion: 1.0.0\n',
        files: {
          'README.md': utf8.encode('super_server'),
          'bin/setup.sh': utf8.encode('#!/bin/sh\n'),
        },
        executable: const {'bin/setup.sh'},
      );

      final tar = TarDecoder().decodeBytes(decodeGzipBounded(bytes));

      expect(tar, hasLength(3), reason: 'mold.yaml plus the two files');
      expect(tar.map((f) => f.lastModTime), everyElement(0));
    });

    test('the same tree packs to the same bytes', () async {
      final tmp = Directory.systemTemp.createTempSync('mold_determinism_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final project = Directory(p.join(tmp.path, 'super_server'))
        ..createSync(recursive: true);
      File(p.join(project.path, 'README.md')).writeAsStringSync('super_server');
      File(p.join(project.path, 'lib', 'app.dart'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');

      const manifest = Manifest(name: 'super_server', version: '1.0.0');
      Future<List<int>> pack() =>
          const Bundler().bundle(projectDir: project.path, manifest: manifest);

      expect(await pack(), equals(await pack()));
    });
  });
}
