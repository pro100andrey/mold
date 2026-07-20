import 'dart:io';
import 'dart:typed_data';

import 'package:mold/mold.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Substitution round-trip', () {
    late Directory tmp;
    late Directory project;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mold_sub_');
      project = Directory(p.join(tmp.path, 'super_server'))
        ..createSync(recursive: true);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    void writeText(String rel, String content) {
      File(p.join(project.path, rel))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    test(
      'renames paths + text across all casings, binaries unchanged',
      () async {
        final binary = Uint8List.fromList(List.generate(256, (i) => i));

        // Source files referencing the name in several casings, plus a path
        // segment and a file name that carry the name.
        writeText('lib/super_server/app.dart', '''
class SuperServer {}            // PascalCase
const id = "super_server";      // snake_case
const url = "super-server.dev"; // kebab-case
const ENV = "SUPER_SERVER";     // SCREAMING_SNAKE
''');
        writeText('lib/super_server.dart', 'export "super_server/app.dart";\n');
        File(p.join(project.path, 'assets/logo.png'))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(binary);

        const manifestYaml = '''
name: super_server
version: 1.0.0
variables:
  project_name:
    description: Project name
    default: my_project
    replaces: super_server
''';

        final bytes = await const Bundler().bundle(
          projectDir: project.path,
          manifest: Manifest.fromYaml(manifestYaml),
        );
        final archivePath = p.join(tmp.path, 'tpl.mold');
        File(archivePath).writeAsBytesSync(bytes);

        final out = p.join(tmp.path, 'out');
        await const Unbundler().unbundleFile(
          source: archivePath,
          targetDir: out,
          vars: {'project_name': 'my_project'},
        );

        // Paths renamed (dir segment + file name).
        expect(
          File(p.join(out, 'lib/my_project/app.dart')).existsSync(),
          isTrue,
        );
        expect(File(p.join(out, 'lib/my_project.dart')).existsSync(), isTrue);
        expect(
          File(p.join(out, 'lib/super_server/app.dart')).existsSync(),
          isFalse,
        );

        // Text substituted in every casing.
        final app = File(
          p.join(out, 'lib/my_project/app.dart'),
        ).readAsStringSync();
        expect(app, contains('class MyProject {}'));
        expect(app, contains('"my_project"'));
        expect(app, contains('"my-project.dev"'));
        expect(app, contains('"MY_PROJECT"'));
        expect(app, isNot(contains('super')));

        // Binary copied byte-identical.
        expect(
          File(p.join(out, 'assets/logo.png')).readAsBytesSync(),
          binary,
        );
      },
    );

    test('falls back to the manifest default when --var is omitted', () async {
      writeText('name.txt', 'super_server');
      const manifestYaml = '''
name: super_server
version: 1.0.0
variables:
  project_name:
    default: my_project
    replaces: super_server
''';
      final bytes = await const Bundler().bundle(
        projectDir: project.path,
        manifest: Manifest.fromYaml(manifestYaml),
      );
      final archivePath = p.join(tmp.path, 'tpl.mold');
      File(archivePath).writeAsBytesSync(bytes);

      final out = p.join(tmp.path, 'out');
      await const Unbundler().unbundleFile(source: archivePath, targetDir: out);

      expect(File(p.join(out, 'name.txt')).readAsStringSync(), 'my_project');
    });
  });
}
