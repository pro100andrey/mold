import 'package:mold/mold.dart';
import 'package:test/test.dart';

/// A prompter backed by a scripted queue of input lines (no real stdin).
VariablePrompter scriptedPrompter(List<String?> lines, StringSink out) {
  final queue = List<String?>.from(lines);
  return VariablePrompter(
    out,
    () => queue.isEmpty ? null : queue.removeAt(0),
  );
}

void main() {
  group('VariableResolver', () {
    const projectName = TemplateVariable(
      name: 'project_name',
      description: 'The new project name',
      defaultValue: 'my_project',
      replaces: 'super_server',
    );
    const required = TemplateVariable(name: 'org', description: 'Org id');

    test('explicit --var wins over default and prompting', () {
      final out = StringBuffer();
      const resolver = VariableResolver();
      final resolved = resolver.resolve(
        [projectName],
        {'project_name': 'explicit_value'},
      );
      expect(resolved['project_name'], 'explicit_value');
      expect(out.toString(), isEmpty);
    });

    test('--no-prompt resolves from defaults without reading input', () {
      var reads = 0;
      final prompter = VariablePrompter(StringBuffer(), () {
        reads++;
        return 'should-not-be-read';
      });
      final resolver = VariableResolver(prompter: prompter, noPrompt: true);
      final resolved = resolver.resolve([projectName], const {});
      expect(resolved['project_name'], 'my_project');
      expect(reads, 0);
    });

    test('--no-prompt omits a required, default-less variable', () {
      // Omitted rather than thrown on, so VariablesValidator reports every
      // missing variable at once as a structured VARIABLE_MISSING.
      const resolver = VariableResolver(noPrompt: true);
      final resolved = resolver.resolve([required, projectName], const {});

      expect(resolved.containsKey('org'), isFalse);
      expect(resolved['project_name'], 'my_project');
      expect(
        const VariablesValidator().validate(
          VariablesInput(variables: const [required], values: resolved),
        ),
        isA<ValidationResult>().having(
          (r) => r.errors.map((e) => e.code),
          'codes',
          contains(VariablesValidator.missing),
        ),
      );
    });

    test('prompts unresolved variables; non-empty input is used', () {
      final out = StringBuffer();
      final resolver = VariableResolver(
        prompter: scriptedPrompter(['typed_name'], out),
      );
      final resolved = resolver.resolve([projectName], const {});
      expect(resolved['project_name'], 'typed_name');
      // Description + name + default shown in the prompt.
      expect(out.toString(), contains('The new project name'));
      expect(out.toString(), contains('project_name [my_project]:'));
    });

    test('empty input at the prompt accepts the default', () {
      final out = StringBuffer();
      final resolver = VariableResolver(
        prompter: scriptedPrompter([''], out),
      );
      final resolved = resolver.resolve([projectName], const {});
      expect(resolved['project_name'], 'my_project');
    });

    test('mixed: explicit for one, prompt for another', () {
      final out = StringBuffer();
      final resolver = VariableResolver(
        prompter: scriptedPrompter(['acme'], out),
      );
      final resolved = resolver.resolve(
        [projectName, required],
        {'project_name': 'x'},
      );
      expect(resolved, {'project_name': 'x', 'org': 'acme'});
    });
  });

  group('end of input is not an answer', () {
    const projectName = TemplateVariable(
      name: 'project_name',
      defaultValue: 'my_project',
    );
    const required = TemplateVariable(name: 'org', description: 'Org id');

    test('EOF on a default-less variable leaves it unresolved', () {
      // A CI job piping from /dev/null without --no-prompt used to get a
      // successfully-scaffolded project with the variable set to '', exit 0.
      final out = StringBuffer();
      final resolver = VariableResolver(prompter: scriptedPrompter([], out));

      final resolved = resolver.resolve([required], const {});

      expect(resolved.containsKey('org'), isFalse);
      expect(
        const VariablesValidator().validate(
          VariablesInput(variables: const [required], values: resolved),
        ),
        predicate<ValidationResult>(
          (r) => r.errors.any((e) => e.code == VariablesValidator.missing),
          'reports VARIABLE_MISSING',
        ),
      );
    });

    test('EOF on a variable with a default takes the default', () {
      final out = StringBuffer();
      final resolver = VariableResolver(prompter: scriptedPrompter([], out));

      final resolved = resolver.resolve([projectName], const {});

      expect(resolved['project_name'], 'my_project');
    });

    test('an empty line still differs from EOF', () {
      // Pressing Enter on a default-less variable returns '' as documented;
      // only a closed stdin leaves it unresolved.
      final out = StringBuffer();
      final resolver = VariableResolver(prompter: scriptedPrompter([''], out));

      final resolved = resolver.resolve([required], const {});

      expect(resolved['org'], '');
    });
  });
}
