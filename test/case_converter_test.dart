import 'package:mold/mold.dart';
import 'package:test/test.dart';

void main() {
  group('CaseConverter', () {
    const c = CaseConverter();

    group('splits tokens into words', () {
      test('snake_case', () {
        expect(c.splitWords('super_server'), ['super', 'server']);
      });
      test('kebab-case', () {
        expect(c.splitWords('super-server'), ['super', 'server']);
      });
      test('SCREAMING_SNAKE', () {
        expect(c.splitWords('SUPER_SERVER'), ['super', 'server']);
      });
      test('PascalCase', () {
        expect(c.splitWords('SuperServer'), ['super', 'server']);
      });
      test('camelCase', () {
        expect(c.splitWords('superServer'), ['super', 'server']);
      });
      test('digits', () {
        expect(c.splitWords('api2Client'), ['api2', 'client']);
      });

      test('leading acronym run (HTTPServer)', () {
        expect(c.splitWords('HTTPServer'), ['http', 'server']);
      });
      test('mid acronym run (myHTTPServer)', () {
        expect(c.splitWords('myHTTPServer'), ['my', 'http', 'server']);
      });
      test('all-caps acronym (API)', () {
        expect(c.splitWords('API'), ['api']);
      });
    });

    group('renders all four casings', () {
      test('from a snake token', () {
        expect(c.toSnake('super_server'), 'super_server');
        expect(c.toKebab('super_server'), 'super-server');
        expect(c.toScreamingSnake('super_server'), 'SUPER_SERVER');
        expect(c.toPascal('super_server'), 'SuperServer');
      });

      test('from a Pascal token', () {
        expect(c.toSnake('SuperServer'), 'super_server');
        expect(c.toScreamingSnake('SuperServer'), 'SUPER_SERVER');
      });
    });

    group('renders a package path', () {
      test('a dotted package becomes a directory path', () {
        expect(c.toPath('com.acme'), 'com/acme');
        expect(c.toPath('com.example.my_project'), 'com/example/my_project');
      });

      test('segments keep their spelling — this is not a casing', () {
        // Via splitWords this would be com/acme/corp: three segments where the
        // package has two, and the capital gone.
        expect(c.toPath('com.acmeCorp'), 'com/acmeCorp');
        expect(c.toPath('com.ACME'), 'com/ACME');
      });

      test('a token with no dots is returned unchanged', () {
        expect(c.toPath('acme'), 'acme');
        expect(c.toPath('acmeCorp'), 'acmeCorp');
      });

      test('empty segments are dropped', () {
        expect(c.toPath('com..acme'), 'com/acme');
        expect(c.toPath('.acme'), 'acme');
        expect(c.toPath('acme.'), 'acme');
        expect(c.toPath('.'), '');
        expect(c.toPath(''), '');
      });

      test('an already-converted path is left alone', () {
        expect(c.toPath('com/acme'), 'com/acme');
        expect(c.toPath(c.toPath('com.acme')), 'com/acme');
      });
    });

    group('builds a replacement table', () {
      test('one entry per casing', () {
        expect(c.replacements('super_server', 'my_project'), {
          'super_server': 'my_project',
          'super-server': 'my-project',
          'SUPER_SERVER': 'MY_PROJECT',
          'SuperServer': 'MyProject',
        });
      });

      test('a single-word token collapses to fewer distinct keys', () {
        // snake == kebab == 'server' for a one-word token; the map dedupes.
        final table = c.replacements('server', 'client');
        expect(table['server'], 'client');
        expect(table['SERVER'], 'CLIENT');
        expect(table['Server'], 'Client');
      });

      test('a collapsed key keeps the snake_case value, not the kebab one', () {
        // snake == kebab == 'superserver', but the two values differ. First
        // casing to claim the key wins, so snake_case does.
        final table = c.replacements('superserver', 'my_project');
        expect(table['superserver'], 'my_project');
        expect(table['SUPERSERVER'], 'MY_PROJECT');
        expect(table['Superserver'], 'MyProject');
      });

      test('a non-ASCII token yields no replacements at all', () {
        expect(c.replacements('приложение', 'my_project'), isEmpty);
      });
    });
  });

  group('CaseTransform', () {
    test('each transform renders its documented shape', () {
      expect(CaseTransform.snakeCase.apply('my_project'), 'my_project');
      expect(CaseTransform.kebabCase.apply('my_project'), 'my-project');
      expect(CaseTransform.camelCase.apply('my_project'), 'myProject');
      expect(CaseTransform.pascalCase.apply('my_project'), 'MyProject');
      expect(CaseTransform.screamingCase.apply('my_project'), 'MY_PROJECT');
      expect(CaseTransform.titleCase.apply('my_project'), 'My Project');
      expect(CaseTransform.pathCase.apply('com.acme'), 'com/acme');
    });

    test('pathCase converts separators, it does not re-word', () {
      expect(CaseTransform.pathCase.apply('com.acmeCorp'), 'com/acmeCorp');
      expect(CaseTransform.pathCase.apply('acme'), 'acme');
      expect(CaseTransform.pathCase.apply('com..acme'), 'com/acme');
      expect(CaseTransform.pathCase.apply('com/acme'), 'com/acme');
    });

    test('accepts any source spelling', () {
      for (final spelling in [
        'my_project',
        'myProject',
        'MyProject',
        'MY_PROJECT',
        'my-project',
      ]) {
        expect(CaseTransform.camelCase.apply(spelling), 'myProject');
        expect(CaseTransform.titleCase.apply(spelling), 'My Project');
      }
    });

    test('handles acronym runs the way splitWords does', () {
      expect(CaseTransform.camelCase.apply('myHTTPServer'), 'myHttpServer');
      expect(CaseTransform.titleCase.apply('myHTTPServer'), 'My Http Server');
    });

    test('a degenerate token yields an empty string, not a crash', () {
      expect(
        CaseTransform.camelCase.apply(
          '\u043f\u0440\u0438\u043b\u043e\u0436\u0435\u043d\u0438\u0435',
        ),
        '',
      );
      expect(CaseTransform.titleCase.apply(''), '');
    });

    test('byNameOrNull is the lookup, names lists the choices', () {
      expect(CaseTransform.byNameOrNull('camelCase'), CaseTransform.camelCase);
      expect(CaseTransform.byNameOrNull('CamelCase'), isNull);
      expect(CaseTransform.byNameOrNull('nope'), isNull);
      expect(CaseTransform.names, contains('titleCase'));
    });

    test('replacements() still derives exactly four casings', () {
      // camelCase and titleCase are deliberately NOT auto-derived: for a
      // single-word token camelCase is indistinguishable from snake_case.
      const c = CaseConverter();
      expect(c.replacements('my_project', 'your_thing').keys, hasLength(4));
      expect(
        c.replacements('my_project', 'your_thing'),
        isNot(contains('myProject')),
      );
    });
  });
}
