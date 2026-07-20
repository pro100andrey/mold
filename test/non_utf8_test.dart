import 'dart:io';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

void main() {
  group('non-UTF-8 content', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_utf8_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    // An extensionless file is classified as text (Makefile, LICENSE), so a
    // compiled binary without an extension takes the substitution path.
    final binaryBytes = <int>[0xff, 0xfe, 0x00, 0x01, 0x80];

    test('an extensionless binary round-trips byte-for-byte', () async {
      final src = Directory('${tmp.path}/src')..createSync(recursive: true);
      File('${src.path}/blob').writeAsBytesSync(binaryBytes);
      File('${src.path}/super_server.txt').writeAsStringSync('super_server');

      const manifest = Manifest(
        name: 'demo',
        version: '1.0.0',
        variables: [
          TemplateVariable(
            name: 'project_name',
            defaultValue: 'my_project',
            replaces: 'super_server',
          ),
        ],
      );

      final archive = await const Bundler().bundle(
        projectDir: src.path,
        manifest: manifest,
      );
      await const Unbundler().unbundleBytes(
        source: archive,
        targetDir: '${tmp.path}/out',
        vars: const {'project_name': 'my_project'},
      );

      expect(
        File('${tmp.path}/out/blob').readAsBytesSync(),
        binaryBytes,
        reason: 'undecodable bytes are copied verbatim, not mangled',
      );
      // The rest of the unpack still completed.
      expect(
        File('${tmp.path}/out/my_project.txt').readAsStringSync(),
        'my_project',
      );
    });

    test(
      'a .txt file holding non-UTF-8 bytes does not abort the unpack',
      () async {
        final src = Directory('${tmp.path}/src')..createSync(recursive: true);
        File('${src.path}/latin1.txt').writeAsBytesSync([0xe9, 0xe8]);
        File('${src.path}/plain.txt').writeAsStringSync('ok');

        const manifest = Manifest(name: 'demo', version: '1.0.0');
        final archive = await const Bundler().bundle(
          projectDir: src.path,
          manifest: manifest,
        );

        await const Unbundler().unbundleBytes(
          source: archive,
          targetDir: '${tmp.path}/out',
        );

        expect(File('${tmp.path}/out/latin1.txt').readAsBytesSync(), [
          0xe9,
          0xe8,
        ]);
        expect(File('${tmp.path}/out/plain.txt').readAsStringSync(), 'ok');
      },
    );
  });
}
