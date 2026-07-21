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
      expect(result.skippedLinks['leak.txt'], SkipReason.outsideProject);
    });

    test('a dangling link is skipped and reported', () {
      File('${src.path}/keep.txt').writeAsStringSync('super_server');
      Link('${src.path}/broken.txt').createSync('nowhere.txt');

      final result = scan();

      expect(result.files, ['keep.txt']);
      expect(result.skippedLinks['broken.txt'], SkipReason.dangling);
    });

    test('a link to a directory is skipped and reported', () {
      Directory('${src.path}/real_dir').createSync();
      File('${src.path}/real_dir/a.txt').writeAsStringSync('super_server');
      Link('${src.path}/alias_dir').createSync('real_dir');

      final result = scan();

      expect(result.files, ['real_dir/a.txt']);
      expect(result.skippedLinks['alias_dir'], SkipReason.directory);
    });

    test('a link to an excluded file is skipped, not smuggled in', () {
      Directory('${src.path}/secrets').createSync();
      File('${src.path}/secrets/key.txt').writeAsStringSync('SUPER SECRET');
      File('${src.path}/app.txt').writeAsStringSync('super_server');
      Link('${src.path}/pub.txt').createSync('secrets/key.txt');

      final result = FileScanner(exclude: ['secrets/**']).scan(src.path);

      expect(result.files, ['app.txt']);
      expect(result.skippedLinks['pub.txt'], SkipReason.filteredOut);
    });

    test('a link to a file outside `include` is skipped', () {
      File('${src.path}/notes.md').writeAsStringSync('super_server');
      File('${src.path}/private.dart').writeAsStringSync('secret');
      Link('${src.path}/alias.md').createSync('private.dart');

      final result = FileScanner(include: ['*.md']).scan(src.path);

      expect(result.files, ['notes.md']);
      expect(result.skippedLinks['alias.md'], SkipReason.filteredOut);
    });

    test('a circular link is distinguished from a dangling one', () {
      File('${src.path}/keep.txt').writeAsStringSync('super_server');
      Link('${src.path}/a').createSync('b');
      Link('${src.path}/b').createSync('a');

      final result = scan();

      expect(result.skippedLinks['a'], SkipReason.circular);
      expect(result.skippedLinks['b'], SkipReason.circular);
    });

    test('skipped-link warnings survive an empty scan', () {
      final outside = File('${tmp.path}/secret.txt')..writeAsStringSync('x');
      Link('${src.path}/a.txt').createSync(outside.path);
      Link('${src.path}/b.txt').createSync(outside.path);

      final result = const ProjectValidator().validate(
        ProjectInput(
          dir: src.path,
          manifest: const Manifest(name: 'demo', version: '1.0.0'),
        ),
      );

      expect(
        result.errors.map((e) => e.code),
        contains(ProjectValidator.dirEmpty),
      );
      expect(
        result.warnings.map((w) => w.code),
        contains(ProjectValidator.symlinkSkipped),
        reason: 'the warnings are why there is nothing to pack',
      );
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
