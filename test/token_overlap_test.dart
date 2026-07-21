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

    test('a self-named project warns rather than blocking', () {
      // The benign case: a project's own generated filename extends its name.
      // Measured at 14% on the real flutter_application corpus.
      writeFile('flutter_application_android.iml', 'x');
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
