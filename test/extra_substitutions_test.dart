import 'dart:io';
import 'dart:typed_data';

import 'package:mold/mold.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('extra_substitutions / no_substitute / binary_extensions', () {
    late Directory tmp;
    late Directory project;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mold_extra_');
      project = Directory(p.join(tmp.path, 'super_server'))
        ..createSync(recursive: true);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    void writeText(String rel, String content) {
      File(p.join(project.path, rel))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    Future<String> roundTrip(
      String manifestYaml,
      Map<String, String> vars,
    ) async {
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
        vars: vars,
      );
      return out;
    }

    test('a hard-coded URL is replaced via extra_substitutions', () async {
      writeText('lib/config.dart', "const api = 'https://api.super.dev';\n");
      const manifestYaml = '''
name: super_server
version: 1.0.0
extra_substitutions:
  - from: https://api.super.dev
    to: https://api.my.dev
''';
      final out = await roundTrip(manifestYaml, const {});
      expect(
        File(p.join(out, 'lib/config.dart')).readAsStringSync(),
        "const api = 'https://api.my.dev';\n",
      );
    });

    test(
      'a no_substitute lockfile is copied verbatim though it is text',
      () async {
        // The lockfile contains the rename token, but must NOT be substituted.
        writeText('pubspec.lock', 'name: super_server\n');
        writeText('lib/app.dart', '// super_server\n');
        const manifestYaml = '''
name: super_server
version: 1.0.0
variables:
  project_name:
    default: my_project
    replaces: super_server
no_substitute:
  - pubspec.lock
''';
        final out = await roundTrip(manifestYaml, const {});

        // Lockfile untouched...
        expect(
          File(p.join(out, 'pubspec.lock')).readAsStringSync(),
          'name: super_server\n',
        );
        // ...while ordinary text is still substituted.
        expect(
          File(p.join(out, 'lib/app.dart')).readAsStringSync(),
          '// my_project\n',
        );
      },
    );

    test('binary_extensions extensions are copied byte-identical', () async {
      final blob = Uint8List.fromList([0, 1, 2, 250, 251, 252, 255]);
      // A file whose extension is NOT in the built-in binary set, but listed
      // in binary_extensions. Its bytes happen to be invalid UTF-8.
      File(p.join(project.path, 'data.myblob')).writeAsBytesSync(blob);
      const manifestYaml = '''
name: super_server
version: 1.0.0
binary_extensions:
  - myblob
''';
      final out = await roundTrip(manifestYaml, const {});
      expect(File(p.join(out, 'data.myblob')).readAsBytesSync(), blob);
    });
  });
}
