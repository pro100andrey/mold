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
}
