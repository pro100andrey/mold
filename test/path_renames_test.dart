import 'dart:io';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

void main() {
  group('path_renames', () {
    late Directory tmp;
    late Directory src;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mold_paths_');
      src = Directory('${tmp.path}/src')..createSync(recursive: true);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void write(String rel, String content) {
      File('${src.path}/$rel')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    Future<Directory> unpack(String manifest, Map<String, String> vars) async {
      final archive = await const Bundler().bundle(
        projectDir: src.path,
        manifest: Manifest.fromYaml(manifest),
      );
      final out = Directory('${tmp.path}/out');
      await const Unbundler().unbundleBytes(
        source: archive,
        targetDir: out.path,
        vars: vars,
      );
      return out;
    }

    test('renames a path without touching content', () async {
      write('lib/old_name/a.dart', 'const marker = "old_name";');

      final out = await unpack(
        '''
name: t
version: 1
variables:
  project_name:
    default: my_project
path_renames:
  - from: lib/old_name
    to: lib/{{ project_name }}
''',
        const {'project_name': 'my_project'},
      );

      expect(File('${out.path}/lib/my_project/a.dart').existsSync(), isTrue);
      // path_renames reaches paths only; the content is untouched.
      expect(
        File('${out.path}/lib/my_project/a.dart').readAsStringSync(),
        'const marker = "old_name";',
      );
    });

    test('an identity entry pins a path against a shorter rename', () async {
      // The case a bare `replaces` cannot express: in a Flutter project
      // `android/app/` is a fixed Gradle module path that must survive, while
      // `kotlin/com/example/app/` is the package and must move. Same literal,
      // opposite treatment. Longest-first matching resolves it.
      write('android/app/build.gradle.kts', 'namespace = "com.example.app"');
      write(
        'android/app/src/main/kotlin/com/example/app/MainActivity.kt',
        'package com.example.app\n',
      );
      write('lib/main.dart', 'const name = "app";');

      final out = await unpack(
        '''
name: t
version: 1
variables:
  project_name:
    default: my_project
path_renames:
  - from: android/app/
    to: android/app/
  - from: kotlin/com/example/app
    to: kotlin/com/example/{{ project_name }}
extra_substitutions:
  - from: com.example.app
    to: com.example.{{ project_name }}
''',
        const {'project_name': 'my_project'},
      );

      // The Gradle module path survived.
      expect(
        File('${out.path}/android/app/build.gradle.kts').existsSync(),
        isTrue,
      );
      // The Kotlin package directory moved.
      expect(
        File(
          '${out.path}/android/app/src/main/kotlin/com/example/my_project/'
          'MainActivity.kt',
        ).existsSync(),
        isTrue,
      );
      // And the identifiers inside both files were rewritten.
      expect(
        File('${out.path}/android/app/build.gradle.kts').readAsStringSync(),
        contains('com.example.my_project'),
      );
    });

    test('transforms apply to path templates too', () async {
      write('lib/old_name/a.dart', 'x');

      final out = await unpack(
        '''
name: t
version: 1
variables:
  project_name:
    default: my_project
path_renames:
  - from: lib/old_name
    to: lib/{{ project_name | kebabCase }}
''',
        const {'project_name': 'my_project'},
      );

      expect(File('${out.path}/lib/my-project/a.dart').existsSync(), isTrue);
    });

    test('a path template is validated like any other', () {
      final m = Manifest.fromYaml('''
name: t
version: 1
path_renames:
  - from: a
    to: "{{ nope }}"
''');
      final r = const ManifestValidator().validate(m);

      expect(
        r.errors.map((e) => e.code),
        contains(ManifestValidator.unknownVariable),
      );
    });

    test('round-trips through toYaml', () {
      const original = Manifest(
        name: 't',
        version: '1',
        pathRenames: [Substitution(from: 'a/b', to: 'c/{{ p }}')],
      );

      expect(Manifest.fromYaml(original.toYaml()), equals(original));
    });

    test('a malformed entry names its own section', () {
      expect(
        () => Manifest.fromYaml('name: t\nversion: 1\npath_renames:\n  - 3\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('path_renames'),
          ),
        ),
      );
    });
  });
}
