@TestOn('!windows')
library;

import 'dart:io';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

void main() {
  group('pack-phase warnings reach the caller', () {
    late Directory tmp;
    late Directory src;
    late List<String> warnings;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mold_packwarn_');
      src = Directory('${tmp.path}/src')..createSync(recursive: true);
      warnings = [];
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<void> pack(Manifest manifest) => const Bundler().bundle(
      projectDir: src.path,
      manifest: manifest,
      onWarning: warnings.add,
    );

    test('a symlink left out of the archive is reported', () async {
      final outside = File('${tmp.path}/secret.txt')..writeAsStringSync('x');
      File('${src.path}/keep.txt').writeAsStringSync('super_server');
      Link('${src.path}/leak.txt').createSync(outside.path);

      await pack(
        const Manifest(
          name: 'demo',
          version: '1.0.0',
          variables: [
            TemplateVariable(name: 'p', replaces: 'super_server'),
          ],
        ),
      );

      expect(warnings, hasLength(1));
      expect(warnings.single, contains(ProjectValidator.symlinkSkipped));
      expect(warnings.single, contains('leak.txt'));
    });

    test('warnings arrive even when the pack then aborts', () async {
      // Every file is a skipped symlink, so the pack fails as empty — and the
      // warnings are the explanation for that error, so they must survive it.
      final outside = File('${tmp.path}/secret.txt')..writeAsStringSync('x');
      Link('${src.path}/a.txt').createSync(outside.path);
      Link('${src.path}/b.txt').createSync(outside.path);

      await expectLater(
        pack(const Manifest(name: 'demo', version: '1.0.0')),
        throwsA(isA<ValidationException>()),
      );
      expect(warnings, hasLength(2));
      expect(
        warnings.every((w) => w.contains(ProjectValidator.symlinkSkipped)),
        isTrue,
      );
    });

    test('a clean project reports nothing', () async {
      File('${src.path}/keep.txt').writeAsStringSync('super_server');

      await pack(
        const Manifest(
          name: 'demo',
          version: '1.0.0',
          variables: [
            TemplateVariable(name: 'p', replaces: 'super_server'),
          ],
        ),
      );

      expect(warnings, isEmpty);
    });
  });
}
