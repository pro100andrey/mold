import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/internals.dart';

/// Matches a [ValidationException] carrying [code].
Matcher rejectsWith(String code) => throwsA(
  isA<ValidationException>().having(
    (e) => e.errors.map((x) => x.code),
    'codes',
    contains(code),
  ),
);

const _manifest = '''
name: app_template
version: 1.0.0
variables:
  name:
    replaces: app_template
''';

void main() {
  late Directory tmp;
  late Directory src;
  late Directory out;
  late List<int> archive;

  void write(Directory root, String rel, String content) {
    File(p.join(root.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  String read(String rel) => File(p.join(out.path, rel)).readAsStringSync();

  /// Every file under [out], relative, sorted.
  List<String> listing() =>
      out
          .listSync(recursive: true)
          .whereType<File>()
          .map(
            (f) => p.posix.joinAll(p.split(p.relative(f.path, from: out.path))),
          )
          .toList()
        ..sort();

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mold_overwrite_');
    src = Directory(p.join(tmp.path, 'app_template'))..createSync();
    out = Directory(p.join(tmp.path, 'out'));
    write(src, 'pubspec.yaml', 'name: app_template\n');
    write(src, 'lib/app_template.dart', 'class AppTemplate {}\n');
    write(src, 'lib/src/new_in_template.dart', '// app_template\n');
    archive = await const Bundler().bundle(
      projectDir: src.path,
      manifest: Manifest.fromYaml(_manifest),
    );
  });

  tearDown(() {
    // A test makes a file read-only; give it back so the tree can go.
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['-R', 'u+w', tmp.path]);
    }
    tmp.deleteSync(recursive: true);
  });

  Future<void> unpack({bool overwrite = false, List<String>? warnings}) =>
      const Unbundler().unbundle(
        bytes: archive,
        targetDir: out.path,
        vars: {'name': 'my_app'},
        overwrite: overwrite,
        onWarning: warnings == null ? null : (w) => warnings.add('$w'),
      );

  /// A project already scaffolded from the template, then worked on.
  void scaffoldAndEdit() {
    write(out, 'pubspec.yaml', 'name: my_app\ndependencies: {}\n');
    write(out, 'lib/my_app.dart', 'class MyApp {}\n');
    write(out, 'lib/hand_written.dart', 'mine\n');
    write(out, 'README.md', 'mine\n');
  }

  group('unpacking into an occupied target', () {
    test('is refused by default', () {
      scaffoldAndEdit();

      expect(unpack, rejectsWith(TargetValidator.occupied));
      expect(read('pubspec.yaml'), 'name: my_app\ndependencies: {}\n');
    });

    test('with overwrite, keeps unrelated files', () async {
      scaffoldAndEdit();

      await unpack(overwrite: true);

      expect(read('lib/hand_written.dart'), 'mine\n');
      expect(read('README.md'), 'mine\n');
    });

    test('with overwrite, replaces same-path files and adds new ones', () {
      scaffoldAndEdit();

      return unpack(overwrite: true).then((_) {
        expect(read('pubspec.yaml'), 'name: my_app\n');
        expect(read('lib/src/new_in_template.dart'), '// my_app\n');
        expect(listing(), [
          'README.md',
          'lib/hand_written.dart',
          'lib/my_app.dart',
          'lib/src/new_in_template.dart',
          'pubspec.yaml',
        ]);
      });
    });

    test('with overwrite, still refuses a target that is a file', () {
      File(out.path).writeAsStringSync('not a directory');

      expect(
        () => unpack(overwrite: true),
        rejectsWith(TargetValidator.occupied),
      );
      expect(File(out.path).readAsStringSync(), 'not a directory');
    });

    test('with overwrite, still works on a fresh target', () async {
      await unpack(overwrite: true);

      expect(read('pubspec.yaml'), 'name: my_app\n');
    });
  });

  group('path conflicts are refused before anything is written', () {
    test('a directory where the template has a file', () {
      scaffoldAndEdit();
      File(p.join(out.path, 'lib', 'my_app.dart')).deleteSync();
      Directory(p.join(out.path, 'lib', 'my_app.dart')).createSync();

      expect(
        () => unpack(overwrite: true),
        rejectsWith(TargetValidator.pathConflict),
      );
      expect(read('pubspec.yaml'), 'name: my_app\ndependencies: {}\n');
    });

    test('a file where the template needs a directory', () {
      scaffoldAndEdit();
      write(out, 'lib/src', 'a file');

      expect(
        () => unpack(overwrite: true),
        rejectsWith(TargetValidator.pathConflict),
      );
      expect(read('pubspec.yaml'), 'name: my_app\ndependencies: {}\n');
    });

    test(
      'a symlinked directory, which would lead outside the target',
      () {
        scaffoldAndEdit();
        final elsewhere = Directory(p.join(tmp.path, 'elsewhere'))
          ..createSync();
        Link(p.join(out.path, 'lib', 'src')).createSync(elsewhere.path);

        expect(
          () => unpack(overwrite: true),
          rejectsWith(TargetValidator.pathConflict),
        );
        expect(elsewhere.listSync(), isEmpty);
      },
      testOn: '!windows',
    );
  });

  group('a failed overwrite is undone', () {
    test(
      'overwritten files get their content back, created ones go',
      () {
        scaffoldAndEdit();
        // Differs from what the template writes, so restoring it shows.
        write(out, 'lib/my_app.dart', 'class MyApp { int edited = 1; }\n');
        // Entries are written in sorted order, so lib/my_app.dart is
        // overwritten and lib/src/ created before pubspec.yaml, which cannot
        // be written.
        final blocked = File(p.join(out.path, 'pubspec.yaml'));
        Process.runSync('chmod', ['444', blocked.path]);
        final before = listing();

        expect(
          () => unpack(overwrite: true),
          throwsA(isA<FileSystemException>()),
        );

        expect(read('lib/my_app.dart'), 'class MyApp { int edited = 1; }\n');
        expect(listing(), before);
        expect(
          Directory(p.join(out.path, 'lib', 'src')).existsSync(),
          isFalse,
          reason: 'a directory the unpack created goes with its files',
        );
      },
      testOn: '!windows',
      // root writes through a read-only mode, so nothing would fail.
      skip: _isRoot ? 'running as root' : false,
    );
  });

  group('the write probe', () {
    test('leaves nothing behind in a non-empty target', () {
      scaffoldAndEdit();
      final before = listing();

      expect(
        const TargetValidator(overwrite: true).validate(out.path).isValid,
        isTrue,
      );
      expect(listing(), before);
    });

    test('does not clobber a file named like it', () {
      write(out, '.mold_write_probe', 'mine\n');

      expect(
        const TargetValidator(overwrite: true).validate(out.path).isValid,
        isTrue,
      );
      expect(read('.mold_write_probe'), 'mine\n');
    });
  });

  group('planning an overwrite', () {
    UnpackPlan plan({bool withContent = true}) => const Unbundler().plan(
      bytes: archive,
      targetDir: out.path,
      vars: {'name': 'my_app'},
      overwrite: true,
      withContent: withContent,
    );

    test('says which files are created and which overwritten', () {
      scaffoldAndEdit();

      final result = plan();

      expect(result.created.map((f) => f.to), [
        'lib/src/new_in_template.dart',
      ]);
      expect(result.overwritten.map((f) => f.to), {
        'lib/my_app.dart',
        'pubspec.yaml',
      });
    });

    test('compares with the file already there', () {
      scaffoldAndEdit();

      final byPath = {for (final f in plan().files) f.to: f};

      expect(byPath['lib/my_app.dart']!.identicalToExisting, isTrue);
      expect(byPath['pubspec.yaml']!.identicalToExisting, isFalse);
      expect(
        byPath['pubspec.yaml']!.existing,
        'name: my_app\ndependencies: {}\n',
      );
      expect(byPath['lib/src/new_in_template.dart']!.existing, isNull);
    });

    test('writes nothing', () {
      scaffoldAndEdit();
      final before = listing();

      plan();

      expect(listing(), before);
      expect(read('pubspec.yaml'), 'name: my_app\ndependencies: {}\n');
    });

    test('without overwrite, an occupied target is still refused', () {
      scaffoldAndEdit();

      expect(
        () => const Unbundler().plan(
          bytes: archive,
          targetDir: out.path,
          vars: {'name': 'my_app'},
        ),
        rejectsWith(TargetValidator.occupied),
      );
    });
  });

  group('mold unpack --force', () {
    late String archivePath;

    setUp(() {
      archivePath = p.join(tmp.path, 't.mold');
      File(archivePath).writeAsBytesSync(archive);
    });

    Future<(int, String)> cli(List<String> extra) async {
      final err = StringBuffer();
      final code = await runBundleCli([
        'unpack',
        archivePath,
        '-t',
        out.path,
        '--var',
        'name=my_app',
        '--no-prompt',
        ...extra,
      ], err: err);

      return (code, err.toString());
    }

    test('without it, an occupied target exits 1 TARGET_OCCUPIED', () async {
      scaffoldAndEdit();

      final (code, err) = await cli([]);

      expect(code, 1);
      expect(err, contains(TargetValidator.occupied));
      expect(err, contains('--force'));
    });

    test('writes into an occupied target', () async {
      scaffoldAndEdit();

      final (code, _) = await cli(['--force']);

      expect(code, 0);
      expect(read('pubspec.yaml'), 'name: my_app\n');
      expect(read('README.md'), 'mine\n');
    });

    test('--dry-run lists what would be created and overwritten', () async {
      scaffoldAndEdit();

      final (code, err) = await cli(['--force', '--dry-run']);

      expect(code, 0);
      expect(err, contains('2 to overwrite (1 identical)'));
      expect(
        err,
        stringContainsInOrder([
          'Created:',
          'lib/src/new_in_template.dart',
          'Overwritten:',
          'pubspec.yaml',
        ]),
      );
      expect(read('pubspec.yaml'), 'name: my_app\ndependencies: {}\n');
    });

    test('--diff diffs against the file already there', () async {
      scaffoldAndEdit();

      final (code, err) = await cli(['--force', '--diff']);

      expect(code, 0);
      expect(
        err,
        stringContainsInOrder([
          '--- pubspec.yaml (in target)',
          '+++ pubspec.yaml',
          '-dependencies: {}',
        ]),
      );
      // Identical to what is there: nothing to show.
      expect(err, isNot(contains('lib/my_app.dart (in target)')));
      expect(read('pubspec.yaml'), 'name: my_app\ndependencies: {}\n');
    });
  });
}

final bool _isRoot =
    !Platform.isWindows &&
    (Process.runSync('id', ['-u']).stdout as String).trim() == '0';
