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
  });
}
