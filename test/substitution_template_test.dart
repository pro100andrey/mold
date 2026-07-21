import 'package:mold/mold.dart';
import 'package:test/test.dart';

/// Asserts the template parsed cleanly and renders [expected] from [values].
void expectRenders(
  String template,
  Map<String, String> values,
  String expected,
) {
  final parsed = SubstitutionTemplate.parse(template);
  expect(parsed.errors, isEmpty, reason: 'template: $template');
  expect(parsed.render(values), expected, reason: 'template: $template');
}

/// Asserts the template failed to parse with [kind].
void expectError(String template, TemplateErrorKind kind) {
  final parsed = SubstitutionTemplate.parse(template);
  expect(
    parsed.errors.map((e) => e.kind),
    contains(kind),
    reason: 'template: $template',
  );
}

void main() {
  const vars = {'project_name': 'my_project', 'org': 'acme'};

  group('SubstitutionTemplate.parse', () {
    test('a template with no placeholders is literal', () {
      final parsed = SubstitutionTemplate.parse('https://api.example.com');
      expect(parsed.errors, isEmpty);
      expect(parsed.isLiteral, isTrue);
      expect(parsed.variableNames, isEmpty);
      expect(parsed.render(const {}), 'https://api.example.com');
    });

    test('a bare placeholder emits the value unchanged', () {
      expectRenders('{{project_name}}', vars, 'my_project');
    });

    test('whitespace inside the braces is insignificant', () {
      for (final form in [
        '{{project_name}}',
        '{{ project_name }}',
        '{{  project_name  }}',
        '{{project_name }}',
      ]) {
        expectRenders(form, vars, 'my_project');
      }
      for (final form in [
        '{{project_name|camelCase}}',
        '{{ project_name | camelCase }}',
        '{{project_name | camelCase}}',
      ]) {
        expectRenders(form, vars, 'myProject');
      }
    });

    test('every transform is reachable', () {
      expectRenders('{{ project_name | snakeCase }}', vars, 'my_project');
      expectRenders('{{ project_name | kebabCase }}', vars, 'my-project');
      expectRenders('{{ project_name | camelCase }}', vars, 'myProject');
      expectRenders('{{ project_name | pascalCase }}', vars, 'MyProject');
      expectRenders('{{ project_name | screamingCase }}', vars, 'MY_PROJECT');
      expectRenders('{{ project_name | titleCase }}', vars, 'My Project');
    });

    test('placeholders mix with surrounding literals', () {
      expectRenders(
        'com.example.{{ project_name | camelCase }}',
        vars,
        'com.example.myProject',
      );
      expectRenders(
        '{{ org }}/{{ project_name | kebabCase }}.git',
        vars,
        'acme/my-project.git',
      );
    });

    test('variableNames lists every referenced variable in order', () {
      final parsed = SubstitutionTemplate.parse(
        '{{ org }}-{{ project_name | camelCase }}-{{ org }}',
      );
      expect(parsed.variableNames, ['org', 'project_name', 'org']);
    });

    test('{{{{ escapes a literal {{', () {
      expectRenders('{{{{ project_name }}', const {}, '{{ project_name }}');
      expectRenders('{{{{}}', const {}, '{{}}');
    });

    test('an escape sits alongside a real placeholder', () {
      expectRenders(
        '{{{{ literal }} and {{ org }}',
        vars,
        '{{ literal }} and acme',
      );
    });

    test('a lone }} needs no escape', () {
      expectRenders('a }} b', const {}, 'a }} b');
    });
  });

  group('SubstitutionTemplate errors', () {
    test('unterminated placeholder', () {
      expectError(
        'com.example.{{ project_name',
        TemplateErrorKind.unterminated,
      );
    });

    test('unknown transform', () {
      expectError(
        '{{ project_name | camlCase }}',
        TemplateErrorKind.unknownTransform,
      );
    });

    test('the unknown-transform message lists the valid choices', () {
      final parsed = SubstitutionTemplate.parse('{{ p | nope }}');
      expect(parsed.errors.single.message, contains('camelCase'));
      expect(parsed.errors.single.message, contains('titleCase'));
    });

    test('chaining is refused, not read as a transform name', () {
      expectError(
        '{{ project_name | snakeCase | camelCase }}',
        TemplateErrorKind.malformed,
      );
    });

    test('an empty or invalid name is malformed', () {
      expectError('{{}}', TemplateErrorKind.malformed);
      expectError('{{ }}', TemplateErrorKind.malformed);
      expectError('{{ 9lives }}', TemplateErrorKind.malformed);
      expectError('{{ a b }}', TemplateErrorKind.malformed);
      expectError('{{ a-b }}', TemplateErrorKind.malformed);
    });

    test('three braces is malformed, four is an escape', () {
      expectError('{{{ x }}', TemplateErrorKind.malformed);
      expect(SubstitutionTemplate.parse('{{{{ x }}').errors, isEmpty);
    });

    test('parsing never throws, and collects more than one error', () {
      final parsed = SubstitutionTemplate.parse(
        '{{ a | nope }} and {{ 9bad }}',
      );
      expect(parsed.errors, hasLength(2));
    });
  });

  group('SubstitutionTemplate.render', () {
    test('throws for a variable with no value', () {
      final parsed = SubstitutionTemplate.parse('{{ missing }}');
      expect(
        () => parsed.render(const {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('missing'),
          ),
        ),
      );
    });

    test('a rendered value is emitted verbatim, never re-scanned', () {
      // The value itself contains what looks like a placeholder.
      expectRenders('{{ p }}', const {'p': '{{ q }}'}, '{{ q }}');
    });
  });
}
