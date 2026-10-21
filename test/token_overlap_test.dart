import 'dart:io';

import 'package:mold/mold.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Matches a result carrying an error-severity issue with the given code.
Matcher rejectsWith(String code) => predicate<ValidationResult>(
  (r) => !r.isValid && r.errors.any((e) => e.code == code),
  'rejected with error code $code',
);

/// Matches a result that is valid but carries a warning with the given code.
Matcher warnsWith(String code) => predicate<ValidationResult>(
  (r) => r.isValid && r.warnings.any((e) => e.code == code),
  'warned with code $code',
);

void main() {
  group('token overlap', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_overlap_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    const validator = ProjectValidator();

    void writeFile(String rel, String content) {
      File(p.join(tmp.path, rel))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    Manifest withVar(String replaces) => Manifest(
      name: 'x',
      version: '1',
      variables: [TemplateVariable(name: 'p', replaces: replaces)],
    );

    ValidationResult check(String replaces) => validator.validate(
      ProjectInput(dir: tmp.path, manifest: withVar(replaces)),
    );

    test('a token buried in longer words is refused, not merely warned', () {
      // The regression this exists for: `bin` measured 95% collateral on a
      // real corpus. Substituting it would rewrite `binary`, `isBinary`, ...
      writeFile('a.dart', '''
final binary = 1;
bool isBinary(String p) => true;
const extraBinary = {};
const binaryExtensions = [];
''');
      final r = check('bin');
      expect(r, rejectsWith(ProjectValidator.tokenTooGeneric));
    });

    test('the error names the worst colliding identifiers with counts', () {
      writeFile('a.dart', 'binary binary binary isBinary');
      final message =
          check(
                'bin',
              ).errors
              .firstWhere((e) => e.code == ProjectValidator.tokenTooGeneric)
              .message;

      expect(message, contains('binary (3)'));
      expect(message, contains('isBinary (1)'));
      expect(message, contains('%'));
    });

    test('derived casings are searched, not just the literal token', () {
      // The false negative: `my_app` never appears literally, but its Pascal
      // and SCREAMING forms are buried in these identifiers, and substitution
      // would rewrite both.
      writeFile('a.dart', 'class MyApplication {} const MY_APPENDIX = 2;');
      final r = check('my_app');

      expect(r, rejectsWith(ProjectValidator.tokenTooGeneric));
      expect(r.errors.first.message, contains('MyApplication'));
    });

    test('a token present only in a derived casing is not "not found"', () {
      writeFile('a.dart', 'class SuperServer {}');
      final r = check('super_server');

      expect(
        r.errors.map((e) => e.code),
        isNot(contains(ProjectValidator.replacesNotFound)),
      );
    });

    test('modest over-reach warns rather than blocking', () {
      // One collateral match in ten: 10%, inside the warning band.
      writeFile('lib/plural.dart', 'const x = "flutter_applications";');
      for (var i = 0; i < 9; i++) {
        writeFile('lib/f$i.dart', 'const x = "flutter_application";');
      }
      final r = check('flutter_application');

      expect(r, warnsWith(ProjectValidator.partialOverlap));
      expect(r.isValid, isTrue);
    });

    test('a clean token is silent', () {
      for (var i = 0; i < 20; i++) {
        writeFile('lib/f$i.dart', 'const x = "super_server";');
      }
      final r = check('super_server');

      expect(r.isValid, isTrue);
      expect(r.warnings, isEmpty);
    });
  });

  group('a match ends where its casing ends a word', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_boundary_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// The collateral identifiers [replaces] finds in [content], most frequent
    /// first — empty when every match is a whole word.
    List<String> collateral(String replaces, String content) {
      File(p.join(tmp.path, 'a.txt')).writeAsStringSync(content);
      final r = const ProjectValidator().validate(
        ProjectInput(
          dir: tmp.path,
          manifest: Manifest(
            name: 'x',
            version: '1',
            variables: [TemplateVariable(name: 'p', replaces: replaces)],
          ),
        ),
      );
      final issue = [...r.errors, ...r.warnings].where(
        (e) =>
            e.code == ProjectValidator.partialOverlap ||
            e.code == ProjectValidator.tokenTooGeneric,
      );

      return issue.isEmpty ? const [] : [issue.single.message];
    }

    // One clean match beside the probe keeps the verdict out of the "not
    // found" path, and one is enough to push a single collateral hit over
    // both thresholds — so an empty result means the probe was clean.
    for (final clean in [
      'app_template_test', // snake: `_` after
      'my_app_template', // snake: `_` before
      'app_template_g', // generated-identifier suffix
      'APP_TEMPLATE_TEST', // SCREAMING: `_` after
      'app-template-test', // kebab: `-` after
      'app-template_test', // kebab: `_` after
      'AppTemplateTest', // Pascal: capital after
      'MyAppTemplate', // Pascal: lowercase before
      'HTTPAppTemplate', // Pascal: capital before
      'AppTemplate2', // Pascal: digit after
    ]) {
      test('$clean is a whole-word match', () {
        expect(collateral('app_template', 'app_template $clean'), isEmpty);
      });
    }

    for (final (token, buried) in [
      ('my_app', 'my_appendix'),
      ('app', 'application'),
      ('my_app', 'MyApplication'),
      ('app_template', 'AppTemplateer'),
      ('app_template', 'APP_TEMPLATES'),
      ('app_template', 'xapp_template'),
      ('app_template', 'app-templates'),
      ('app_template', 'app_template2'),
    ]) {
      test('$token inside $buried is still over-reach', () {
        final found = collateral(token, '$token $buried');

        expect(found, hasLength(1));
        expect(found.single, contains(buried));
      });
    }

    test('a project named app_template packs without a warning', () async {
      // The downstream case: its own test package and generated identifiers
      // extend the name with `_`, and renaming them is the point.
      final project = Directory(p.join(tmp.path, 'app_template'))..createSync();
      void write(String rel, String content) {
        File(p.join(project.path, rel))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);
      }

      write('pubspec.yaml', 'name: app_template\n');
      write('lib/app_template.dart', 'class AppTemplate {}\n');
      write(
        'test/app_template_test.dart',
        "import 'package:app_template/app_template.dart';\n"
            'final app_template_g = AppTemplate();\n',
      );
      write(
        'app_template_test/pubspec.yaml',
        'name: app_template_test\n'
            'dependencies:\n  app_template:\n    path: ../\n',
      );

      final warnings = <String>[];
      await const Bundler().bundle(
        projectDir: project.path,
        manifest: const Manifest(
          name: 'app_template',
          version: '1',
          variables: [
            TemplateVariable(name: 'name', replaces: 'app_template'),
          ],
        ),
        onWarning: warnings.add,
      );

      expect(warnings, isEmpty);
    });
  });

  group('the manifest does not vouch for its own token', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_selfref_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a token occurring only in mold.yaml is reported missing', () {
      File(p.join(tmp.path, 'main.dart')).writeAsStringSync('nothing here\n');
      final manifestPath = p.join(tmp.path, 'mold.yaml');
      File(manifestPath).writeAsStringSync('''
name: x
version: 1
variables:
  p:
    replaces: super_server
''');

      final r = const ProjectValidator().validate(
        ProjectInput(dir: tmp.path, manifest: Manifest.fromFile(manifestPath)),
      );

      expect(r, rejectsWith(ProjectValidator.replacesNotFound));
    });

    test('a manifest with no path on disk still counts every file', () {
      // fromYaml carries no path, so nothing is excluded — a library caller
      // who never touched the filesystem is unaffected.
      File(p.join(tmp.path, 'main.dart')).writeAsStringSync('super_server\n');

      final r = const ProjectValidator().validate(
        ProjectInput(
          dir: tmp.path,
          manifest: Manifest.fromYaml('''
name: x
version: 1
variables:
  p:
    replaces: super_server
'''),
        ),
      );

      expect(r.isValid, isTrue);
    });
  });
}
