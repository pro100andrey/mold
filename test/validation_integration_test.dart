import 'dart:io';

import 'package:mold/mold.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Pulls the set of error codes out of a thrown [ValidationException].
Set<String> codesOf(ValidationException e) =>
    e.errors.map((x) => x.code).toSet();

void main() {
  late Directory tmp;
  late Directory project;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mold_vi_');
    project = Directory(p.join(tmp.path, 'super_server'))
      ..createSync(recursive: true);
    File(
      p.join(project.path, 'main.dart'),
    ).writeAsStringSync('// super_server\n');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<List<int>> packValid() => const Bundler().bundle(
    projectDir: project.path,
    manifest: Manifest.fromYaml('''
name: super_server
version: 1.0.0
variables:
  project_name:
    default: my_project
    replaces: super_server
'''),
  );

  group('pack phase (manifest → project)', () {
    test('a manifest missing a required field fails with its code', () async {
      try {
        await const Bundler().bundle(
          projectDir: project.path,
          manifest: Manifest.fromYaml('version: 1.0.0\n'),
        );
        fail('expected ValidationException');
      } on ValidationException catch (e) {
        expect(codesOf(e), contains(ManifestValidator.missingName));
      }
    });

    test('the manifest phase aborts before the project phase', () async {
      // Manifest is invalid (no name) AND the project lacks the token. Only the
      // first phase (manifest) should surface — project never runs.
      Directory(p.join(tmp.path, 'empty')).createSync();
      try {
        await const Bundler().bundle(
          projectDir: p.join(tmp.path, 'empty'),
          manifest: Manifest.fromYaml('version: 1.0.0\n'),
        );
        fail('expected ValidationException');
      } on ValidationException catch (e) {
        expect(codesOf(e), contains(ManifestValidator.missingName));
        expect(codesOf(e), isNot(contains(ProjectValidator.dirEmpty)));
      }
    });
  });

  group('unbundle phase (archive → manifest → variables → target)', () {
    test('an archive missing files/ fails with its code', () async {
      final bytes = const ArchiveWriter().write(
        manifestYaml: 'name: x\nversion: 1\n',
        files: const {},
      );
      try {
        await const Unbundler().unbundle(
          bytes: bytes,
          targetDir: p.join(tmp.path, 'out'),
        );
        fail('expected ValidationException');
      } on ValidationException catch (e) {
        expect(codesOf(e), contains(ArchiveValidator.missingFiles));
      }
    });

    test('an occupied target fails with its code', () async {
      final archive = await packValid();
      final occupied = Directory(p.join(tmp.path, 'taken'))..createSync();
      File(p.join(occupied.path, 'f')).writeAsStringSync('x');

      try {
        await const Unbundler().unbundleBytes(
          source: archive,
          targetDir: occupied.path,
          vars: {'project_name': 'my_project'},
        );
        fail('expected ValidationException');
      } on ValidationException catch (e) {
        expect(codesOf(e), contains(TargetValidator.occupied));
      }
    });

    test('a valid unbundle still succeeds end-to-end', () async {
      final archive = await packValid();
      final out = p.join(tmp.path, 'out');
      await const Unbundler().unbundleBytes(
        source: archive,
        targetDir: out,
        vars: {'project_name': 'my_project'},
      );
      expect(
        File(p.join(out, 'main.dart')).readAsStringSync(),
        '// my_project\n',
      );
    });
  });
}
