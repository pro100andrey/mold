import 'dart:io';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

void main() {
  group('ProjectValidator honours include/exclude', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_pvs_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    const validator = ProjectValidator();

    Manifest manifestExcludingBuild() => const Manifest(
      name: 'demo',
      version: '1.0.0',
      exclude: ['build/**'],
      variables: [
        TemplateVariable(
          name: 'project_name',
          defaultValue: 'my_project',
          replaces: 'super_server',
        ),
      ],
    );

    test('a token found only in an excluded file is reported missing', () {
      File('${tmp.path}/keep.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('nothing relevant here');
      File('${tmp.path}/build/generated.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('const x = "super_server";');

      final result = validator.validate(
        ProjectInput(dir: tmp.path, manifest: manifestExcludingBuild()),
      );

      expect(
        result.errors.map((e) => e.code),
        contains(ProjectValidator.replacesNotFound),
        reason: 'the excluded file never reaches the archive',
      );
    });

    test('a token in an included file still passes', () {
      File('${tmp.path}/keep.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('super_server lives here');
      File('${tmp.path}/build/generated.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('irrelevant');

      final result = validator.validate(
        ProjectInput(dir: tmp.path, manifest: manifestExcludingBuild()),
      );

      expect(result.isValid, isTrue);
    });

    test('a project whose files are all excluded is rejected as empty', () {
      File('${tmp.path}/build/only.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('super_server');

      final result = validator.validate(
        ProjectInput(dir: tmp.path, manifest: manifestExcludingBuild()),
      );

      expect(
        result.errors.map((e) => e.code),
        contains(ProjectValidator.dirEmpty),
        reason: 'packing this would produce an archive with no files',
      );
    });

    test('include filters the validated set too', () {
      File('${tmp.path}/lib/a.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('super_server');
      File('${tmp.path}/notes.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('nothing');

      const onlyMarkdown = Manifest(
        name: 'demo',
        version: '1.0.0',
        include: ['*.md'],
        variables: [
          TemplateVariable(
            name: 'project_name',
            defaultValue: 'my_project',
            replaces: 'super_server',
          ),
        ],
      );

      final result = validator.validate(
        ProjectInput(dir: tmp.path, manifest: onlyMarkdown),
      );

      expect(
        result.errors.map((e) => e.code),
        contains(ProjectValidator.replacesNotFound),
      );
    });
  });
}
