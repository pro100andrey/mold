import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/internals.dart';

/// Matches a [ValidationException] carrying [code].
Matcher failsWith(String code) => throwsA(
  isA<ValidationException>().having((e) => e.codes, 'codes', contains(code)),
);

const _manifest = '''
name: super_server
version: 1.0.0
variables:
  name:
    replaces: super_server
''';

void main() {
  late Directory tmp;
  late Directory src;
  late List<int> archive;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mold_plan_');
    src = Directory(p.join(tmp.path, 'src'))..createSync();
    File(p.join(src.path, 'pubspec.yaml')).writeAsStringSync(
      'name: super_server\n',
    );
    File(p.join(src.path, 'README.md')).writeAsStringSync('nothing here\n');
    archive = await const Bundler().bundle(
      projectDir: src.path,
      manifest: Manifest.fromYaml(_manifest),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String target([String name = 'out']) => p.join(tmp.path, name);

  group('plan, then apply', () {
    test('writes what unbundle writes', () async {
      final planned = const Unbundler().plan(
        bytes: archive,
        targetDir: target('a'),
        vars: {'name': 'my_app'},
      );
      await const Unbundler().apply(planned);
      await const Unbundler().unbundle(
        bytes: archive,
        targetDir: target('b'),
        vars: {'name': 'my_app'},
      );

      for (final rel in ['pubspec.yaml', 'README.md']) {
        expect(
          File(p.join(target('a'), rel)).readAsStringSync(),
          File(p.join(target('b'), rel)).readAsStringSync(),
        );
      }
      expect(
        File(p.join(target('a'), 'pubspec.yaml')).readAsStringSync(),
        'name: my_app\n',
      );
    });

    test('the plan holds the bytes it will write', () {
      final planned = const Unbundler().plan(
        bytes: archive,
        targetDir: target(),
        vars: {'name': 'my_app'},
      );
      final byPath = {for (final f in planned.files) f.to: f};

      expect(
        String.fromCharCodes(byPath['pubspec.yaml']!.bytes),
        'name: my_app\n',
      );
      expect(
        String.fromCharCodes(byPath['README.md']!.bytes),
        'nothing here\n',
      );
      expect(planned.manifest.name, 'super_server');
      expect(planned.values, {'name': 'my_app'});
    });

    test('a plan with no target cannot be applied', () {
      final planned = const Unbundler().plan(
        bytes: archive,
        vars: {'name': 'my_app'},
      );

      expect(
        () => const Unbundler().apply(planned),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('apply validates the target again', () async {
      // Free when planned, taken before it was applied: a plan shown to a
      // user and confirmed later must not write into what appeared meanwhile.
      final planned = const Unbundler().plan(
        bytes: archive,
        targetDir: target(),
        vars: {'name': 'my_app'},
      );
      Directory(target()).createSync();
      File(p.join(target(), 'mine.txt')).writeAsStringSync('mine');

      await expectLater(
        const Unbundler().apply(planned),
        failsWith(MoldCode.targetOccupied),
      );
      expect(Directory(target()).listSync(), hasLength(1));
    });
  });

  group('a target whose parents are missing', () {
    test('is planned without creating anything', () {
      final nested = p.join(tmp.path, 'new', 'nested', 'out');
      const Unbundler().plan(
        bytes: archive,
        targetDir: nested,
        vars: {'name': 'my_app'},
      );

      expect(Directory(p.join(tmp.path, 'new')).existsSync(), isFalse);
    });

    test('is created, parents and all', () async {
      final nested = p.join(tmp.path, 'new', 'nested', 'out');
      await const Unbundler().unbundle(
        bytes: archive,
        targetDir: nested,
        vars: {'name': 'my_app'},
      );

      expect(
        File(p.join(nested, 'pubspec.yaml')).readAsStringSync(),
        'name: my_app\n',
      );
    });

    test('under a file is TARGET_NOT_DIRECTORY', () {
      final file = File(p.join(tmp.path, 'file'))..writeAsStringSync('x');

      expect(
        () => const Unbundler().plan(
          bytes: archive,
          targetDir: p.join(file.path, 'out'),
          vars: {'name': 'my_app'},
        ),
        failsWith(MoldCode.targetNotDirectory),
      );
    });
  });

  group('a rewrite while planning', () {
    List<int> licensed(String path, List<int> bytes) =>
        path == 'README.md' ? [...bytes, ...'MIT\n'.codeUnits] : bytes;

    test('changes the bytes written, and only of the files it changes', () {
      final planned = const Unbundler().plan(
        bytes: archive,
        targetDir: target(),
        vars: {'name': 'my_app'},
        rewrite: licensed,
      );
      final byPath = {for (final f in planned.files) f.to: f};

      expect(
        String.fromCharCodes(byPath['README.md']!.bytes),
        'nothing here\nMIT\n',
      );
      expect(byPath['README.md']!.after, 'nothing here\nMIT\n');
      expect(byPath['README.md']!.rewritten, isTrue);
      expect(byPath['README.md']!.changed, isTrue);
      expect(byPath['pubspec.yaml']!.rewritten, isFalse);
      expect(planned.rewritten.map((f) => f.to), contains('README.md'));
      expect(planned.untouched, isEmpty);
    });

    test('sees where the file lands and what substitution made of it', () {
      final seen = <String, String>{};
      const Unbundler().plan(
        bytes: archive,
        targetDir: target(),
        vars: {'name': 'my_app'},
        rewrite: (path, bytes) {
          seen[path] = String.fromCharCodes(bytes);
          return bytes;
        },
      );

      expect(seen, {
        'pubspec.yaml': 'name: my_app\n',
        'README.md': 'nothing here\n',
      });
    });

    test('is what the stamp records, so a regeneration sees no edit', () async {
      final out = target();
      await const Unbundler().unbundle(
        bytes: archive,
        targetDir: out,
        vars: {'name': 'my_app'},
        stamp: true,
        rewrite: licensed,
      );
      final warnings = <ValidationError>[];
      final again = const Unbundler().plan(
        bytes: archive,
        targetDir: out,
        vars: {'name': 'my_app'},
        overwrite: true,
        rewrite: licensed,
        onWarning: warnings.add,
      );

      expect(again.templateFiles.every((f) => f.identicalToExisting), isTrue);
      expect(again.edited, isEmpty);
      expect(
        warnings.map((w) => w.code),
        isNot(contains(MoldCode.unpackOverwritesEdits)),
      );
    });
  });

  group('errors arrive in the Future', () {
    test('unbundle does not throw synchronously', () async {
      Directory(target()).createSync();
      File(p.join(target(), 'mine.txt')).writeAsStringSync('mine');

      late Future<void> pending;
      expect(
        () => pending = const Unbundler().unbundle(
          bytes: archive,
          targetDir: target(),
          vars: {'name': 'my_app'},
        ),
        returnsNormally,
      );
      await expectLater(pending, failsWith(MoldCode.targetOccupied));
    });

    test('bundle does not throw synchronously', () async {
      late Future<void> pending;
      expect(
        () => pending = const Bundler().bundle(
          projectDir: p.join(tmp.path, 'missing'),
          manifest: Manifest.fromYaml(_manifest),
        ),
        returnsNormally,
      );
      await expectLater(pending, failsWith(MoldCode.projectDirNotFound));
    });
  });

  group('problems with inputs are ValidationExceptions with codes', () {
    test('a missing archive file is ARCHIVE_NOT_FOUND', () async {
      await expectLater(
        const Unbundler().unbundleFile(
          source: p.join(tmp.path, 'nope.mold'),
          targetDir: target(),
        ),
        failsWith(MoldCode.archiveNotFound),
      );
    });

    test('a rename that escapes the target is RENAME_UNSAFE_PATH', () async {
      final escaping = await const Bundler().bundle(
        projectDir: src.path,
        manifest: Manifest.fromYaml('''
name: t
version: 1
path_renames:
  - from: README.md
    to: ../README.md
'''),
      );

      expect(
        () => const Unbundler().plan(bytes: escaping, targetDir: target()),
        failsWith(MoldCode.renameUnsafePath),
      );
    });
  });

  group('warnings', () {
    test('arrive as ValidationErrors with their codes', () async {
      final warnings = <ValidationError>[];
      await const Bundler().bundle(
        projectDir: src.path,
        manifest: Manifest.fromYaml('''
name: t
version: 1
variables:
  unused:
    default: x
'''),
        onWarning: warnings.add,
      );

      expect(warnings.single.code, MoldCode.manifestUnusedVariable);
      expect(warnings.single.severity, Severity.warning);
    });
  });

  group('compression level', () {
    Future<List<int>> pack(int level) => Bundler(
      compressionLevel: level,
    ).bundle(projectDir: src.path, manifest: Manifest.fromYaml(_manifest));

    test('trades size, and the archive still unpacks', () async {
      final stored = await pack(0);
      final smallest = await pack(9);

      expect(stored.length, greaterThan(smallest.length));
      await const Unbundler().unbundle(
        bytes: stored,
        targetDir: target(),
        vars: {'name': 'my_app'},
      );
      expect(
        File(p.join(target(), 'pubspec.yaml')).readAsStringSync(),
        'name: my_app\n',
      );
    });

    test('is reproducible at any one level', () async {
      expect(await pack(1), await pack(1));
    });
  });

  group('Substitutor.applyCounted', () {
    test('agrees with apply and count', () {
      final s = Substitutor({'ab': 'x', 'abc': 'y', 'c': 'z'});
      const input = 'abc ab c abcab';

      expect(s.applyCounted(input), (s.apply(input), s.count(input)));
    });

    test('watching rewrites exactly as the plain substitutor does', () {
      // `app_store` is watched and longer than the key `app` at the same
      // position: the key must still win there.
      final s = Substitutor({'app': 'app_store', 'my_app': 'x'});
      final watched = s.watching(['app_store', 'store', 'appx']);
      const inputs = [
        'app_store',
        'my_app app_store store appx',
        'nothing',
        'storeapp_storeapp',
        '',
      ];

      for (final input in inputs) {
        final seen = <(String, int)>[];
        final result = watched.applyCounted(
          input,
          (t, at) => seen.add((t, at)),
        );

        expect(result, s.applyCounted(input), reason: input);
        for (final (text, at) in seen) {
          expect(input.substring(at, at + text.length), text);
        }
      }
    });

    test('keys opening on class metacharacters still match', () {
      final s = Substitutor({']x': '1', '-y': '2', '^z': '3', r'\w': '4'});

      expect(s.apply(r'a]x b-y c^z d\w'), 'a1 b2 c3 d4');
    });

    test('a watched literal a key covers is not reported', () {
      final s = Substitutor({'app': 'app_store'});
      final seen = <String>[];
      s
          .watching(['app_store', 'store'])
          .applyCounted(
            'app_store store',
            (t, _) => seen.add(t),
          );

      // The first `app_store` starts with the key `app`, so it is rewritten,
      // not met; its `store` and the lone `store` are met.
      expect(seen, ['store', 'store']);
    });
  });
}
