import 'package:test/test.dart';

import 'support/internals.dart';

void main() {
  const org = TemplateVariable(
    name: 'org',
    pattern: r'[a-z]+(\.[a-z]+)+',
    defaultValue: 'com.example',
  );
  const platform = TemplateVariable(
    name: 'platform',
    choices: ['android', 'ios'],
    defaultValue: 'android',
  );

  group('pattern and choices', () {
    test('parse from YAML and round-trip through toYaml', () {
      final m = Manifest.fromYaml(r'''
name: t
version: 1
variables:
  org:
    pattern: '[a-z]+(\.[a-z]+)+'
    default: com.example
  platform:
    choices: [android, ios]
    default: android
''');

      expect(m.variables, [org, platform]);
      expect(Manifest.fromYaml(m.toYaml()), m);
    });

    test('the pattern is anchored to the whole value', () {
      expect(org.accepts('com.acme'), isTrue);
      expect(org.accepts('com.acme!'), isFalse);
      expect(org.accepts('xcom.acme'), isTrue, reason: 'still all [a-z.]');
      expect(org.accepts('acme'), isFalse);
    });

    test('choices are exact', () {
      expect(platform.accepts('ios'), isTrue);
      expect(platform.accepts('iOS'), isFalse);
    });
  });

  group('values are checked at unpack', () {
    ValidationResult check(TemplateVariable v, String value) =>
        const VariablesValidator().validate(
          VariablesInput(variables: [v], values: {v.name: value}),
        );

    test('a value outside choices is VARIABLE_NOT_A_CHOICE', () {
      final r = check(platform, 'web');

      expect(r.errors.single.code, MoldCode.variableNotAChoice);
      expect(r.errors.single.message, contains('android, ios'));
    });

    test('a value failing the pattern is VARIABLE_PATTERN_MISMATCH', () {
      expect(
        check(org, 'Acme').errors.single.code,
        MoldCode.variablePatternMismatch,
      );
    });

    test('a value satisfying both is clean', () {
      expect(check(org, 'dev.acme.shop').isValid, isTrue);
      expect(check(platform, 'ios').isValid, isTrue);
    });
  });

  group('the manifest is checked at pack', () {
    ValidationResult check(TemplateVariable v) => const ManifestValidator()
        .validate(Manifest(name: 't', version: '1', variables: [v]));

    test('a pattern that does not compile is MANIFEST_INVALID_PATTERN', () {
      final r = check(const TemplateVariable(name: 'x', pattern: '(['));

      expect(r.errors.single.code, MoldCode.manifestInvalidPattern);
    });

    test('a default its constraints reject is MANIFEST_INVALID_DEFAULT', () {
      final r = check(
        const TemplateVariable(
          name: 'x',
          choices: ['a', 'b'],
          defaultValue: 'c',
        ),
      );

      expect(r.errors.single.code, MoldCode.manifestInvalidDefault);
      expect(r.errors.single.message, contains('choices (a, b)'));
    });
  });

  test('the prompt lists the choices', () {
    final out = StringBuffer();
    VariablePrompter(out, () => '').promptFor(platform);

    expect(out.toString(), contains('One of: android, ios'));
  });
}
