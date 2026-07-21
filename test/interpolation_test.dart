import 'dart:io';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

/// The manifest under test: a `replaces` shorthand for the bulk rename, plus
/// two explicit substitutions for the forms the four casings cannot reach.
const _manifest = '''
name: flutter_application
version: 1.0.0
variables:
  project_name:
    description: The new project name
    default: my_project
    replaces: flutter_application
extra_substitutions:
  - from: com.example.flutterApplication
    to: com.example.{{ project_name | camelCase }}
  - from: Flutter Application
    to: "{{ project_name | titleCase }}"
''';

/// Every spelling of the old name that must be gone after a rename.
const _oldForms = [
  'flutter_application',
  'flutter-application',
  'FLUTTER_APPLICATION',
  'FlutterApplication',
  'flutterApplication',
  'Flutter Application',
];

void main() {
  group('interpolated substitutions', () {
    late Directory tmp;
    late Directory src;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mold_interp_');
      src = Directory('${tmp.path}/src')..createSync(recursive: true);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void write(String rel, String content) {
      File('${src.path}/$rel')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    /// Reproduces the three shapes a real Flutter project uses for one name.
    void writeFlutterShapes() {
      // snake — reached by `replaces`
      write('pubspec.yaml', 'name: flutter_application\n');
      write(
        'android/app/src/main/kotlin/com/example/flutter_application/'
            'MainActivity.kt',
        'package com.example.flutter_application\n',
      );
      // camelCase — Apple's createUTIIdentifier camelCases the project name
      // while Android's createAndroidIdentifier does not.
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'PRODUCT_BUNDLE_IDENTIFIER = com.example.flutterApplication;\n',
      );
      write(
        'macos/Runner/Configs/AppInfo.xcconfig',
        'PRODUCT_BUNDLE_IDENTIFIER = com.example.flutterApplication\n',
      );
      // titleCase — CFBundleDisplayName, the name under the home-screen icon
      write(
        'ios/Runner/Info.plist',
        '<key>CFBundleDisplayName</key>\n'
            '<string>Flutter Application</string>\n',
      );
    }

    Future<Directory> renameTo(String value) async {
      final archive = await const Bundler().bundle(
        projectDir: src.path,
        manifest: Manifest.fromYaml(_manifest),
      );
      final out = Directory('${tmp.path}/out');
      await const Unbundler().unbundleBytes(
        source: archive,
        targetDir: out.path,
        vars: {'project_name': value},
      );
      return out;
    }

    String read(Directory out, String rel) =>
        File('${out.path}/$rel').readAsStringSync();

    test('reaches the forms the four casings cannot', () async {
      writeFlutterShapes();
      final out = await renameTo('my_project');

      // snake, via `replaces`
      expect(read(out, 'pubspec.yaml'), contains('name: my_project'));
      expect(
        read(
          out,
          'android/app/src/main/kotlin/com/example/my_project/'
          'MainActivity.kt',
        ),
        contains('package com.example.my_project'),
      );
      // camelCase, via interpolation
      expect(
        read(out, 'ios/Runner.xcodeproj/project.pbxproj'),
        contains('com.example.myProject'),
      );
      expect(
        read(out, 'macos/Runner/Configs/AppInfo.xcconfig'),
        contains('com.example.myProject'),
      );
      // titleCase, via interpolation
      expect(
        read(out, 'ios/Runner/Info.plist'),
        contains('<string>My Project</string>'),
      );
    });

    test('no spelling of the old name survives anywhere', () async {
      writeFlutterShapes();
      final out = await renameTo('my_project');

      final survivors = <String>[];
      for (final file in out.listSync(recursive: true).whereType<File>()) {
        final text = file.readAsStringSync();
        for (final form in _oldForms) {
          if (text.contains(form) || file.path.contains(form)) {
            survivors.add('${file.path}: $form');
          }
        }
      }
      expect(survivors, isEmpty, reason: 'old name survived the rename');
    });

    test('the same template renames to a different value', () async {
      writeFlutterShapes();
      final out = await renameTo('acme_shop');

      expect(
        read(out, 'ios/Runner.xcodeproj/project.pbxproj'),
        contains('com.example.acmeShop'),
      );
      expect(
        read(out, 'ios/Runner/Info.plist'),
        contains('<string>Acme Shop</string>'),
      );
    });

    test('an explicit substitution beats a colliding rename key', () async {
      write('a.txt', 'flutter_application\n');
      final archive = await const Bundler().bundle(
        projectDir: src.path,
        manifest: Manifest.fromYaml('''
name: t
version: 1
variables:
  project_name:
    default: my_project
    replaces: flutter_application
extra_substitutions:
  - from: flutter_application
    to: "{{ project_name | screamingCase }}"
'''),
      );
      final out = Directory('${tmp.path}/out');
      await const Unbundler().unbundleBytes(
        source: archive,
        targetDir: out.path,
        vars: const {'project_name': 'my_project'},
      );

      // The rename would have written my_project; the explicit entry wins.
      expect(read(out, 'a.txt').trim(), 'MY_PROJECT');
    });

    test('a variable with no `replaces` now carries a value', () async {
      // Before interpolation such a variable was a silent no-op: it prompted
      // for a value that reached nothing. It is now the only way to feed one
      // into a substitution.
      write('a.txt', 'OLD\n');
      final archive = await const Bundler().bundle(
        projectDir: src.path,
        manifest: Manifest.fromYaml('''
name: t
version: 1
variables:
  project_name:
    default: OLD
extra_substitutions:
  - from: OLD
    to: "{{ project_name }}"
'''),
      );
      final out = Directory('${tmp.path}/out');
      await const Unbundler().unbundleBytes(
        source: archive,
        targetDir: out.path,
        vars: const {'project_name': 'OLD_AGAIN'},
      );

      // Renders to OLD_AGAIN and stops — the rendered value is not re-scanned,
      // or the `OLD` inside it would match again and cascade.
      expect(read(out, 'a.txt').trim(), 'OLD_AGAIN');
    });
  });
}
