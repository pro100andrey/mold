import 'package:mold/mold.dart';
import 'package:test/test.dart';

void main() {
  group('Manifest', () {
    test('parses name/version/include/exclude', () {
      final m = Manifest.fromYaml('''
name: super_server
version: 1.2.3
include:
  - "**"
exclude:
  - build/**
''');
      expect(m.name, 'super_server');
      expect(m.version, '1.2.3');
      expect(m.include, ['**']);
      expect(m.exclude, ['build/**']);
    });

    test('parses variables with replaces/default/description', () {
      final m = Manifest.fromYaml('''
name: super_server
version: 1.0.0
variables:
  project_name:
    description: The new project name
    default: my_project
    replaces: super_server
  api_url:
    description: API base URL
''');
      expect(m.variables, hasLength(2));

      final first = m.variables.first;
      expect(first.name, 'project_name');
      expect(first.description, 'The new project name');
      expect(first.defaultValue, 'my_project');
      expect(first.replaces, 'super_server');

      final second = m.variables[1];
      expect(second.name, 'api_url');
      expect(second.replaces, isNull);
      expect(second.defaultValue, isNull);
    });

    test('parses extra_substitutions, no_substitute, binary_extensions', () {
      final m = Manifest.fromYaml('''
name: super_server
version: 1.0.0
extra_substitutions:
  - from: https://api.example.com
    to: "{{api_url}}"
no_substitute:
  - pubspec.lock
  - "**/*.g.dart"
binary_extensions:
  - lockb
  - .myblob
''');
      expect(m.extraSubstitutions, hasLength(1));
      expect(m.extraSubstitutions.single.from, 'https://api.example.com');
      expect(m.extraSubstitutions.single.to, '{{api_url}}');
      expect(m.noSubstitute, ['pubspec.lock', '**/*.g.dart']);
      expect(m.binaryExtensions, ['lockb', '.myblob']);
    });

    test('an extra_substitution missing from/to is a FormatException', () {
      expect(
        () => Manifest.fromYaml('''
name: s
version: 1.0.0
extra_substitutions:
  - to: only-to
'''),
        throwsA(isA<FormatException>()),
      );
    });

    test('parsing is lenient: a missing name yields an empty name', () {
      // Required-field enforcement is the ManifestValidator's job, not the
      // parser's, so parsing a name-less manifest does not throw.
      final m = Manifest.fromYaml('version: 1.0.0\n');
      expect(m.name, isEmpty);
      expect(m.version, '1.0.0');
    });
  });
}
