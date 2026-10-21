import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/internals.dart';

void main() {
  late Directory tmp;
  late Directory src;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mold_edges_');
    src = Directory(p.join(tmp.path, 'src'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(Directory root, String rel, String content) {
    File(p.join(root.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  Matcher failsWith(String code) => throwsA(
    isA<ValidationException>().having((e) => e.codes, 'codes', [code]),
  );

  group('a manifest that is not UTF-8', () {
    // `name: café` in Latin-1: 0xE9 is no UTF-8 sequence.
    final latin1Yaml = [...utf8.encode('name: caf'), 0xE9, 10];

    test('in an archive is MANIFEST_INVALID', () {
      final archive = Archive()
        ..addFile(ArchiveFile('mold.yaml', latin1Yaml.length, latin1Yaml))
        ..addFile(ArchiveFile('files/a.txt', 1, [0x61]));
      final bytes = const GZipEncoder().encode(TarEncoder().encode(archive));

      expect(
        () => const Unbundler().inspect(bytes),
        failsWith(MoldCode.manifestInvalid),
      );
    });

    test('in a file is MANIFEST_INVALID', () {
      final file = File(p.join(tmp.path, 'mold.yaml'))
        ..writeAsBytesSync(latin1Yaml);

      expect(
        () => Manifest.fromFile(file.path),
        failsWith(MoldCode.manifestInvalid),
      );
    });
  });

  group('a file renamed to where another needs a directory', () {
    test('collides before anything is written', () async {
      write(src, 'lib/app', 'a file\n');
      write(src, 'lib/app_dir/x.dart', '// x\n');
      final archive = await const Bundler().bundle(
        projectDir: src.path,
        manifest: const Manifest(
          name: 't',
          version: '1',
          pathRenames: [Substitution(from: 'app_dir', to: 'app')],
        ),
      );
      final target = p.join(tmp.path, 'out');

      await expectLater(
        const Unbundler().unbundle(bytes: archive, targetDir: target),
        failsWith(MoldCode.renameCollision),
      );
      expect(Directory(target).existsSync(), isFalse);
    });

    test('is reported naming both', () {
      final result = const RenameValidator().validate({
        'lib/app': 'lib/app',
        'lib/app_dir/x.dart': 'lib/app/x.dart',
      });

      expect(result.errors.single.message, contains("inside 'lib/app'"));
    });
  });

  group('recorded values', () {
    Future<List<int>> pack() {
      write(src, 'a.txt', 'app');
      return const Bundler().bundle(
        projectDir: src.path,
        manifest: const Manifest(
          name: 't',
          version: '1',
          variables: [TemplateVariable(name: 'name', replaces: 'app')],
        ),
      );
    }

    test('fill variables; one the template dropped is a warning', () async {
      final warnings = <ValidationError>[];
      final plan = const Unbundler().plan(
        bytes: await pack(),
        recorded: {'name': 'shop', 'gone': 'x'},
        onWarning: warnings.add,
      );

      expect(plan.values, {'name': 'shop'});
      expect(warnings.single.code, MoldCode.variableDropped);
      expect(warnings.single.field, 'gone');
    });

    test('give way to explicit values', () async {
      final plan = const Unbundler().plan(
        bytes: await pack(),
        vars: {'name': 'cart'},
        recorded: {'name': 'shop'},
      );

      expect(plan.values, {'name': 'cart'});
    });
  });

  group('a stale file', () {
    test('differing from a written one only in case', () async {
      write(src, 'lib/MyApp.txt', 'v1');
      final target = p.join(tmp.path, 'out');
      Future<List<int>> pack() => const Bundler().bundle(
        projectDir: src.path,
        manifest: const Manifest(name: 't', version: '1'),
      );
      await const Unbundler().unbundle(
        bytes: await pack(),
        targetDir: target,
        stamp: true,
      );
      File(p.join(src.path, 'lib/MyApp.txt')).renameSync(
        p.join(src.path, 'lib/Myapp.txt'),
      );

      final plan = const Unbundler().plan(
        bytes: await pack(),
        targetDir: target,
        overwrite: true,
      );

      // One file on a case-insensitive filesystem, so not left behind; two on
      // a case-sensitive one, so the old one is.
      final caseSensitive = !File(p.join(target, 'lib/myapp.txt')).existsSync();
      expect(plan.stale, caseSensitive ? ['lib/MyApp.txt'] : isEmpty);
    });
  });

  test(
    'an unreadable file fails the pack after the warnings',
    () async {
      write(src, '.env', 'KEY=1');
      write(src, 'locked.txt', 'x');
      Process.runSync('chmod', ['000', p.join(src.path, 'locked.txt')]);
      final warnings = <ValidationError>[];

      await expectLater(
        const Bundler().bundle(
          projectDir: src.path,
          manifest: const Manifest(name: 't', version: '1'),
          onWarning: warnings.add,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        warnings.map((w) => w.code),
        contains(MoldCode.projectSecretSuspected),
      );
    },
    testOn: '!windows',
    // Root reads a file whatever its mode.
    skip: Platform.environment['USER'] == 'root',
  );
}
