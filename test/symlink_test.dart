@TestOn('!windows')
library;

import 'dart:io';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

void main() {
  group('symlinks', () {
    late Directory tmp;
    late Directory src;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mold_link_');
      src = Directory('${tmp.path}/src')..createSync(recursive: true);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    ScanResult scan() => FileScanner().scan(src.path);

    test('a link to a file inside the project is packed as its content', () {
      File('${src.path}/real.txt').writeAsStringSync('super_server');
      Link('${src.path}/alias.txt').createSync('real.txt');

      final result = scan();

      expect(result.files, containsAll(['alias.txt', 'real.txt']));
      expect(result.skippedLinks, isEmpty);
    });

    test('a link out of the project is skipped and reported', () {
      final outside = File('${tmp.path}/secret.txt')
        ..writeAsStringSync('do not pack me');
      File('${src.path}/keep.txt').writeAsStringSync('super_server');
      Link('${src.path}/leak.txt').createSync(outside.path);

      final result = scan();

      expect(result.files, ['keep.txt']);
      expect(result.skippedLinks.keys, ['leak.txt']);
      expect(result.skippedLinks['leak.txt'], contains('outside the project'));
    });

    test('a dangling link is skipped and reported', () {
      File('${src.path}/keep.txt').writeAsStringSync('super_server');
      Link('${src.path}/broken.txt').createSync('nowhere.txt');

      final result = scan();

      expect(result.files, ['keep.txt']);
      expect(result.skippedLinks['broken.txt'], contains('does not exist'));
    });

    test('a link to a directory is skipped and reported', () {
      Directory('${src.path}/real_dir').createSync();
      File('${src.path}/real_dir/a.txt').writeAsStringSync('super_server');
      Link('${src.path}/alias_dir').createSync('real_dir');

      final result = scan();

      expect(result.files, ['real_dir/a.txt']);
      expect(result.skippedLinks['alias_dir'], contains('is a directory'));
    });

    test('an excluded link is not reported', () {
      final outside = File('${tmp.path}/secret.txt')..writeAsStringSync('x');
      File('${src.path}/keep.txt').writeAsStringSync('super_server');
      Link('${src.path}/leak.txt').createSync(outside.path);

      final result = FileScanner(exclude: ['leak.txt']).scan(src.path);

      expect(result.skippedLinks, isEmpty, reason: 'filtered out anyway');
    });

    test('ProjectValidator warns without blocking the pack', () {
      final outside = File('${tmp.path}/secret.txt')..writeAsStringSync('x');
      File('${src.path}/keep.txt').writeAsStringSync('super_server');
      Link('${src.path}/leak.txt').createSync(outside.path);

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
      final result = const ProjectValidator().validate(
        ProjectInput(dir: src.path, manifest: manifest),
      );

      expect(result.isValid, isTrue, reason: 'a warning must not block');
      expect(
        result.warnings.map((w) => w.code),
        contains(ProjectValidator.symlinkSkipped),
      );
    });

    test('a dereferenced link round-trips with substitution applied', () async {
      File('${src.path}/real.txt').writeAsStringSync('hello super_server');
      Link('${src.path}/alias.txt').createSync('real.txt');

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

      final unpacked = File('${tmp.path}/out/alias.txt');
      expect(unpacked.readAsStringSync(), 'hello my_project');
      expect(
        FileSystemEntity.isLinkSync(unpacked.path),
        isFalse,
        reason: 'dereferenced, so no symlink privileges needed to unpack',
      );
    });
  });
}
