import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/internals.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('mold_rules_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String rel, String content) {
    File(p.join(tmp.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  ValidationResult check(Manifest manifest) => const ProjectValidator()
      .validate(ProjectInput(dir: tmp.path, manifest: manifest));

  Iterable<String> codes(ValidationResult r) =>
      [...r.errors, ...r.warnings].map((e) => e.code);

  group('explicit substitutions take part in the token check', () {
    test('a site claimed by extra_substitutions is not collateral', () {
      // The too-generic error recommends exactly this remedy; it used to
      // change nothing, because the check ignored extra_substitutions.
      write('a.dart', 'class MyApplication {} final my_app = 1;');
      const bare = Manifest(
        name: 'x',
        version: '1',
        variables: [TemplateVariable(name: 'p', replaces: 'my_app')],
      );
      expect(codes(check(bare)), contains(MoldCode.projectTokenTooGeneric));

      const shielded = Manifest(
        name: 'x',
        version: '1',
        variables: [TemplateVariable(name: 'p', replaces: 'my_app')],
        extraSubstitutions: [
          Substitution(from: 'MyApplication', to: 'MyApplication'),
        ],
      );
      final r = check(shielded);

      expect(r.isValid, isTrue);
      expect(r.warnings, isEmpty);
    });

    test('a path_renames entry shields paths, not content', () {
      write('app/main.dart', 'app');
      write('lib/app.dart', 'app');
      const manifest = Manifest(
        name: 'x',
        version: '1',
        variables: [TemplateVariable(name: 'p', replaces: 'app')],
        pathRenames: [Substitution(from: 'app/main', to: 'app/main')],
      );

      expect(check(manifest).isValid, isTrue);
    });
  });

  group('rules that never fire are reported', () {
    test('an extra_substitutions entry found nowhere', () {
      write('a.txt', 'hello');
      const manifest = Manifest(
        name: 'x',
        version: '1',
        extraSubstitutions: [Substitution(from: 'helo', to: 'bye')],
      );

      final r = check(manifest);

      expect(r.isValid, isTrue);
      expect(r.warnings.single.code, MoldCode.projectSubstitutionUnused);
      expect(r.warnings.single.field, 'helo');
    });

    test('an extra_substitutions entry found only in a path', () {
      // Content-only: a match in a file name does not make it fire.
      write('hello.txt', 'nothing');
      const manifest = Manifest(
        name: 'x',
        version: '1',
        extraSubstitutions: [Substitution(from: 'hello', to: 'bye')],
      );

      expect(codes(check(manifest)), [MoldCode.projectSubstitutionUnused]);
    });

    test('a path_renames entry found in no path', () {
      write('lib/a.dart', 'kotlin/com/example');
      const manifest = Manifest(
        name: 'x',
        version: '1',
        pathRenames: [Substitution(from: 'kotlin/com/example', to: 'x')],
      );

      expect(codes(check(manifest)), [MoldCode.projectPathRenameUnused]);
    });

    test('entries that fire are silent', () {
      write('kotlin/com/example/A.kt', 'https://example.dev');
      const manifest = Manifest(
        name: 'x',
        version: '1',
        extraSubstitutions: [Substitution(from: 'example.dev', to: 'x')],
        pathRenames: [Substitution(from: 'com/example', to: 'com/x')],
      );

      final r = check(manifest);

      expect(r.isValid, isTrue);
      expect(r.warnings, isEmpty);
    });
  });

  group('a token in files copied verbatim', () {
    const manifest = Manifest(
      name: 'x',
      version: '1',
      variables: [TemplateVariable(name: 'p', replaces: 'super_server')],
      noSubstitute: ['vendor/**'],
    );

    test('is reported, naming the files', () {
      write('lib/a.dart', 'super_server');
      write('vendor/b.txt', 'SuperServer inside');
      File(p.join(tmp.path, 'icon.png'))
        ..createSync()
        ..writeAsBytesSync([0x89, ...'super_server'.codeUnits, 0xFF]);

      final r = check(manifest);
      final warning = r.warnings.singleWhere(
        (w) => w.code == MoldCode.projectTokenInVerbatim,
      );

      expect(r.isValid, isTrue);
      expect(warning.message, contains('2 file(s)'));
      expect(warning.message, contains('icon.png'));
      expect(warning.message, contains('vendor/b.txt'));
    });

    test('is not counted as a match substitution would make', () {
      // Only in a no_substitute file: unpacking renames nothing.
      write('vendor/b.txt', 'super_server');
      write('lib/a.dart', 'nothing');

      expect(
        codes(check(manifest)),
        contains(MoldCode.projectReplacesNotFound),
      );
    });

    test('is not reported when absent', () {
      write('lib/a.dart', 'super_server');
      write('vendor/b.txt', 'unrelated');

      expect(check(manifest).warnings, isEmpty);
    });
  });

  group('tokens that derive the same casing', () {
    test('warn, naming both variables and the casings', () {
      const manifest = Manifest(
        name: 'x',
        version: '1',
        variables: [
          TemplateVariable(name: 'a', replaces: 'my_app'),
          TemplateVariable(name: 'b', replaces: 'my-app'),
        ],
      );

      final r = const ManifestValidator().validate(manifest);
      final warning = r.warnings.singleWhere(
        (w) => w.code == MoldCode.manifestConflictingTokens,
      );

      expect(r.isValid, isTrue);
      expect(warning.message, contains("'a' and 'b'"));
      expect(warning.message, contains('MyApp'));
    });

    test('a token inside another does not', () {
      const manifest = Manifest(
        name: 'x',
        version: '1',
        variables: [
          TemplateVariable(name: 'a', replaces: 'app'),
          TemplateVariable(name: 'b', replaces: 'my_app'),
        ],
      );

      expect(
        const ManifestValidator()
            .validate(manifest)
            .warnings
            .map((w) => w.code),
        isNot(contains(MoldCode.manifestConflictingTokens)),
      );
    });
  });
}
