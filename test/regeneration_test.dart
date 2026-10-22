import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/internals.dart';

void main() {
  late Directory tmp;
  late Directory src;
  late String target;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mold_regen_');
    src = Directory(p.join(tmp.path, 'src'))..createSync();
    target = p.join(tmp.path, 'out');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(Directory root, String rel, String content) {
    File(p.join(root.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  Future<List<int>> pack() => const Bundler().bundle(
    projectDir: src.path,
    manifest: const Manifest(name: 't', version: '1'),
  );

  Future<void> unpackStamped(List<int> archive) => const Unbundler().unbundle(
    bytes: archive,
    targetDir: target,
    stamp: true,
  );

  UnpackPlan regenerate(List<int> archive, List<ValidationError> warnings) =>
      const Unbundler().plan(
        bytes: archive,
        targetDir: target,
        overwrite: true,
        onWarning: warnings.add,
      );

  group('a regeneration over a stamped target', () {
    test('flags a file of the project the template now adds', () async {
      write(src, 'a.txt', 'one\n');
      await unpackStamped(await pack());
      // The user's own file; the next template version ships the same path.
      write(Directory(target), 'lib/config.dart', 'mine\n');
      write(src, 'lib/config.dart', 'template\n');

      final warnings = <ValidationError>[];
      final plan = regenerate(await pack(), warnings);

      expect(plan.edited.map((f) => f.to), ['lib/config.dart']);
      expect(
        warnings
            .singleWhere((w) => w.code == MoldCode.unpackOverwritesEdits)
            .message,
        contains('never written by it'),
      );
    });

    test('does not rewrite files that would not change', () async {
      write(src, 'same.txt', 'same\n');
      write(src, 'changes.txt', 'v1\n');
      await unpackStamped(await pack());
      final same = File(p.join(target, 'same.txt'));
      final old = DateTime(2000);
      same.setLastModifiedSync(old);
      write(src, 'changes.txt', 'v2\n');

      await const Unbundler().apply(regenerate(await pack(), []));

      expect(same.lastModifiedSync(), old, reason: 'identical: left alone');
      expect(
        File(p.join(target, 'changes.txt')).readAsStringSync(),
        'v2\n',
      );
    });

    test('rewrites a file that changed after it was planned', () async {
      write(src, 'a.txt', 'one\n');
      await unpackStamped(await pack());
      final plan = regenerate(await pack(), []);
      expect(
        plan.files.firstWhere((f) => f.to == 'a.txt').identicalToExisting,
        isTrue,
      );
      write(Directory(target), 'a.txt', 'edited meanwhile\n');

      await const Unbundler().apply(plan);

      expect(File(p.join(target, 'a.txt')).readAsStringSync(), 'one\n');
    });

    test('ignores stamp paths outside the target', () async {
      write(src, 'a.txt', 'one\n');
      await unpackStamped(await pack());
      final outside = File(p.join(tmp.path, 'outside.txt'))
        ..writeAsStringSync('x');
      File(p.join(target, '.mold.json')).writeAsStringSync(
        const UnpackStamp(
          template: 't',
          version: '1',
          vars: {},
          files: {'../outside.txt': 'h', 'a.txt': 'h'},
        ).toJson(),
      );

      final plan = regenerate(await pack(), []);

      expect(plan.stale, isEmpty);
      expect(outside.existsSync(), isTrue);
    });

    test('an unreadable stamp warns instead of failing', () async {
      write(src, 'a.txt', 'one\n');
      await unpackStamped(await pack());
      File(p.join(target, '.mold.json')).writeAsBytesSync([0xFF, 0xFE, 0x00]);

      final warnings = <ValidationError>[];
      regenerate(await pack(), warnings);

      expect(
        warnings.map((w) => w.code),
        contains(MoldCode.unpackStampInvalid),
      );
    });
  });

  group("a variable's value in a path", () {
    test('is not reported where a rename rewrites it', () async {
      // `bar` is variable b's token *and* variable a's value: in the path it
      // is renamed by b, so nothing ambiguous is left behind.
      write(src, 'lib/bar.dart', 'foo bar');
      final archive = await const Bundler().bundle(
        projectDir: src.path,
        manifest: const Manifest(
          name: 't',
          version: '1',
          variables: [
            TemplateVariable(name: 'a', replaces: 'foo'),
            TemplateVariable(name: 'b', replaces: 'bar'),
          ],
        ),
      );
      final warnings = <ValidationError>[];
      const Unbundler().plan(
        bytes: archive,
        vars: {'a': 'bar', 'b': 'baz'},
        onWarning: warnings.add,
      );

      expect(
        warnings.map((w) => w.code),
        isNot(contains(MoldCode.variableValuePresent)),
      );
    });
  });

  group('manifest scalars keep their spelling', () {
    test('version, default and choices', () {
      final m = Manifest.fromYaml('''
name: t
version: 1.10
variables:
  build:
    default: 007
    choices: [007, 1.10, 1e3]
''');

      expect(m.version, '1.10');
      expect(m.variables.single.defaultValue, '007');
      expect(m.variables.single.choices, ['007', '1.10', '1e3']);
    });

    test('quoted values are taken as they are', () {
      final m = Manifest.fromYaml('name: t\nversion: "1.10"\n');

      expect(m.version, '1.10');
    });
  });

  test('an out-of-range compression level is refused', () {
    write(src, 'a.txt', 'x');

    expect(
      () => const Bundler(compressionLevel: 12).bundle(
        projectDir: src.path,
        manifest: const Manifest(name: 't', version: '1'),
      ),
      throwsA(isA<RangeError>()),
    );
  });
}
