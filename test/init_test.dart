import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/internals.dart';

void main() {
  late Directory tmp;
  late Directory project;

  void write(String rel, String content) {
    File(p.join(project.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  String manifest() =>
      File(p.join(project.path, 'mold.yaml')).readAsStringSync();

  /// Runs the CLI; [answers] are what the init prompt reads.
  Future<(int, String, String)> mold(
    List<String> args, {
    List<String?> answers = const [],
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final queue = [...answers];
    final runner = CommandRunner<int>('mold', '')
      ..addCommand(
        InitCommand(
          out,
          err,
          readLine: () => queue.isEmpty ? null : queue.removeAt(0),
        ),
      );
    final code = await runner.run(args) ?? 0;

    return (code, out.toString(), err.toString());
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mold_init_');
    project = Directory(p.join(tmp.path, 'app_template'))..createSync();
    write('pubspec.yaml', 'name: app_template\n');
    write('lib/app_template.dart', 'class AppTemplate {}\n');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('detectProjectName', () {
    test('reads pubspec.yaml', () {
      expect(detectProjectName(project.path), (
        name: 'app_template',
        source: 'pubspec.yaml',
      ));
    });

    test('reads package.json, without its scope', () {
      File(p.join(project.path, 'pubspec.yaml')).deleteSync();
      write('package.json', '{"name": "@acme/web-shop", "version": "1.0.0"}');

      expect(detectProjectName(project.path).name, 'web-shop');
    });

    test("reads Cargo.toml's package, not a dependency's name", () {
      File(p.join(project.path, 'pubspec.yaml')).deleteSync();
      write(
        'Cargo.toml',
        '[workspace]\nname = "nope"\n\n[package]\nname = "rust_tool"\n',
      );

      expect(detectProjectName(project.path).name, 'rust_tool');
    });

    test('reads go.mod, past a major-version suffix', () {
      File(p.join(project.path, 'pubspec.yaml')).deleteSync();
      write('go.mod', 'module example.com/acme/go-svc/v2\n\ngo 1.22\n');

      expect(detectProjectName(project.path).name, 'go-svc');
    });

    final others = {
      'pyproject.toml': (
        '[build-system]\nrequires = ["hatchling"]\n\n'
            '[project]\nname = "py_tool"\n',
        'py_tool',
      ),
      'composer.json': ('{"name": "acme/php-lib"}', 'php-lib'),
      'settings.gradle.kts': ('rootProject.name = "kt-app"\n', 'kt-app'),
      'settings.gradle': ("rootProject.name = 'groovy-app'\n", 'groovy-app'),
      'pom.xml': (
        '<project><parent><artifactId>parent-pom</artifactId></parent>'
            '<artifactId>java-svc</artifactId></project>',
        'java-svc',
      ),
      'Package.swift': (
        'let package = Package(\n  name: "SwiftKit",\n  products: [])',
        'SwiftKit',
      ),
      'Shop.Api.csproj': ('<Project Sdk="Microsoft.NET.Sdk" />', 'Shop.Api'),
    };
    for (final MapEntry(key: file, value: (content, name)) in others.entries) {
      test('reads $file', () {
        File(p.join(project.path, 'pubspec.yaml')).deleteSync();
        write(file, content);

        expect(detectProjectName(project.path).name, name);
      });
    }

    test('poetry keeps its name under tool.poetry', () {
      File(p.join(project.path, 'pubspec.yaml')).deleteSync();
      write('pyproject.toml', '[tool.poetry]\nname = "poetry-app"\n');

      expect(detectProjectName(project.path).name, 'poetry-app');
    });

    test('falls back to the directory name', () {
      File(p.join(project.path, 'pubspec.yaml')).deleteSync();

      expect(detectProjectName(project.path), (
        name: 'app_template',
        source: 'directory name',
      ));
    });
  });

  group('mold init', () {
    test('writes a manifest that packs', () async {
      final (code, _, err) = await mold(['init', project.path]);

      expect(code, 0, reason: err);
      final m = Manifest.fromYaml(manifest());
      expect(m.name, 'app_template');
      expect(m.exclude, ['mold.yaml']);
      expect(m.variables.single.name, 'project_name');
      expect(m.variables.single.replaces, 'app_template');
      expect(
        const ManifestValidator().validate(m).isValid,
        isTrue,
      );
      expect(err, contains("'app_template' (pubspec.yaml)"));
    });

    test('offers the spellings no casing covers', () async {
      write(
        'ios/Runner.xcconfig',
        'PRODUCT_BUNDLE_IDENTIFIER = '
            'com.example.appTemplate\nPRODUCT_NAME = App Template\n',
      );

      final (code, _, err) = await mold(['init', project.path], answers: ['']);

      expect(code, 0, reason: err);
      expect(err, contains("'appTemplate' → {{ project_name | camelCase }}"));
      expect(Manifest.fromYaml(manifest()).extraSubstitutions, [
        const Substitution(
          from: 'appTemplate',
          to: '{{ project_name | camelCase }}',
        ),
        const Substitution(
          from: 'App Template',
          to: '{{ project_name | titleCase }}',
        ),
      ]);
      // Offered, not also warned about.
      expect(err, isNot(contains(MoldCode.projectUncoveredCasing)));
    });

    test('a no, or no answer at all, leaves them out', () async {
      write('a.txt', 'appTemplate');

      for (final answer in ['n', null]) {
        final (code, _, _) = await mold(
          [
            'init',
            project.path,
            '--force',
          ],
          answers: [answer],
        );

        expect(code, 0);
        expect(Manifest.fromYaml(manifest()).extraSubstitutions, isEmpty);
      }
    });

    test('--yes adds them without asking', () async {
      write('a.txt', 'appTemplate');

      final (_, _, err) = await mold(['init', project.path, '--yes']);

      expect(err, isNot(contains('[Y/n]')));
      expect(Manifest.fromYaml(manifest()).extraSubstitutions, hasLength(1));
    });

    test('an existing manifest is kept unless --force', () async {
      write('mold.yaml', 'name: mine\nversion: 9\n');

      final (code, _, err) = await mold(['init', project.path]);

      expect(code, 64);
      expect(err, contains('already exists'));
      expect(manifest(), 'name: mine\nversion: 9\n');

      expect((await mold(['init', project.path, '--force'])).$1, 0);
      expect(Manifest.fromYaml(manifest()).name, 'app_template');
    });

    test('--dry-run prints it and writes nothing', () async {
      final (code, out, _) = await mold(['init', project.path, '--dry-run']);

      expect(code, 0);
      expect(out, startsWith('name: "app_template"\n'));
      expect(File(p.join(project.path, 'mold.yaml')).existsSync(), isFalse);
    });

    test('--token and --variable override the defaults', () async {
      await mold([
        'init',
        project.path,
        '--token',
        'AppTemplate',
        '--variable',
        'name',
      ]);

      final variable = Manifest.fromYaml(manifest()).variables.single;
      expect(variable.name, 'name');
      expect(variable.replaces, 'AppTemplate');
    });

    test("the pack's concerns are reported as warnings", () async {
      final (code, _, err) = await mold([
        'init',
        project.path,
        '--token',
        'absent_name',
      ]);

      expect(code, 0);
      expect(err, contains('Warning'));
      expect(err, contains(MoldCode.projectReplacesNotFound));
    });

    test('--json describes what it did', () async {
      write('a.txt', 'appTemplate');

      final (_, out, _) = await mold([
        'init',
        project.path,
        '--no-prompt',
        '--json',
      ]);
      final doc = jsonDecode(out) as Map<String, Object?>;

      expect(doc['token'], 'app_template');
      expect(doc['suggestionsAdded'], isFalse);
      expect(doc['suggestions'], [
        {
          'from': 'appTemplate',
          'to': '{{ project_name | camelCase }}',
          'files': ['a.txt'],
        },
      ]);
    });

    test('the result unpacks under a new name', () async {
      write('a.txt', 'appTemplate');
      await mold(['init', project.path, '--yes']);
      final archive = await const Bundler().bundle(
        projectDir: project.path,
        manifest: Manifest.fromFile(p.join(project.path, 'mold.yaml')),
      );
      final target = p.join(tmp.path, 'out');

      await const Unbundler().unbundle(
        bytes: archive,
        targetDir: target,
        vars: {'project_name': 'my_shop'},
      );

      expect(
        File(p.join(target, 'lib', 'my_shop.dart')).readAsStringSync(),
        'class MyShop {}\n',
      );
      expect(File(p.join(target, 'a.txt')).readAsStringSync(), 'myShop');
      expect(File(p.join(target, 'mold.yaml')).existsSync(), isFalse);
    });
  });
}
