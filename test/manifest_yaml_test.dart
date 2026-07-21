import 'dart:io';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

/// Asserts [key] is absent as a top-level YAML key.
///
/// Anchored, because a plain `contains('substitutions:')` also matches
/// `extra_substitutions:` — the kind of false pass that hides a missing field.
Matcher hasNoTopLevelKey(String key) =>
    isNot(matches(RegExp('^$key:', multiLine: true)));

void main() {
  group('Manifest.toYaml', () {
    test('round-trips every field', () {
      const original = Manifest(
        name: 'super_server',
        version: '1.0.0',
        include: ['**'],
        exclude: ['build/**', '.dart_tool/**'],
        variables: [
          TemplateVariable(
            name: 'project_name',
            description: 'The new project name',
            defaultValue: 'my_project',
            replaces: 'super_server',
          ),
          TemplateVariable(name: 'bare'),
        ],
        extraSubstitutions: [
          Substitution(from: 'https://api.super.dev', to: 'https://x.example'),
        ],
        noSubstitute: ['pubspec.lock', '**/*.g.dart'],
        binaryExtensions: ['myblob'],
      );

      // One assertion over the whole value, so a field added to Manifest but
      // forgotten in toYaml() fails here instead of passing silently.
      expect(Manifest.fromYaml(original.toYaml()), equals(original));
    });

    test('survives scalars that would break a plain YAML scalar', () {
      const original = Manifest(
        name: 'a: b',
        version: '1.0',
        include: ['**', '*.g.dart'],
        extraSubstitutions: [Substitution(from: "it's", to: '#hash: yes')],
      );

      final parsed = Manifest.fromYaml(original.toYaml());

      expect(parsed.name, 'a: b');
      expect(parsed.include, ['**', '*.g.dart']);
      expect(parsed.extraSubstitutions.first.from, "it's");
      expect(parsed.extraSubstitutions.first.to, '#hash: yes');
    });

    test('preserves newlines, tabs, quotes and backslashes', () {
      // A single-quoted YAML scalar folds line breaks into spaces, so a
      // multi-line substitution would silently stop matching its source text.
      const original = Manifest(
        name: 'x',
        version: '1',
        variables: [
          TemplateVariable(name: 'v', description: 'line one\nline two'),
        ],
        extraSubstitutions: [
          Substitution(from: '// Copyright\n// All rights\n', to: ''),
          Substitution(from: r'C:\path "quoted"', to: 'a\tb'),
        ],
      );

      final parsed = Manifest.fromYaml(original.toYaml());

      expect(parsed.variables.first.description, 'line one\nline two');
      expect(
        parsed.extraSubstitutions.first.from,
        '// Copyright\n// All rights\n',
      );
      expect(parsed.extraSubstitutions.first.to, '');
      expect(parsed.extraSubstitutions[1].from, r'C:\path "quoted"');
      expect(parsed.extraSubstitutions[1].to, 'a\tb');
    });

    test('omits empty sections', () {
      const minimal = Manifest(name: 'x', version: '1');
      final yaml = minimal.toYaml();

      expect(yaml, hasNoTopLevelKey('include'));
      expect(yaml, hasNoTopLevelKey('exclude'));
      expect(yaml, hasNoTopLevelKey('variables'));
      expect(yaml, hasNoTopLevelKey('extra_substitutions'));
      expect(yaml, hasNoTopLevelKey('no_substitute'));
      expect(yaml, hasNoTopLevelKey('binary_extensions'));
    });
  });

  group('packing a code-built manifest', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_ser_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('embeds the variables, so unpack actually renames', () async {
      final src = Directory('${tmp.path}/src')..createSync(recursive: true);
      File('${src.path}/super_server.txt').writeAsStringSync('super_server go');

      const manifest = Manifest(
        name: 'demo',
        version: '1.0.0',
        variables: [
          TemplateVariable(
            name: 'project_name',
            defaultValue: 'my_project',
            replaces: 'super_server',
          ),
        ],
      );

      final archive = await const Bundler().bundle(
        projectDir: src.path,
        manifest: manifest,
      );

      // The embedded manifest must carry the variables through.
      final embedded = Manifest.fromYaml(
        const ArchiveReader().read(archive).manifestYaml,
      );
      expect(embedded.variables, hasLength(1));
      expect(embedded.variables.first.replaces, 'super_server');

      await const Unbundler().unbundleBytes(
        source: archive,
        targetDir: '${tmp.path}/out',
        vars: const {'project_name': 'my_project'},
      );

      expect(
        File('${tmp.path}/out/my_project.txt').readAsStringSync(),
        'my_project go',
      );
    });
  });

  group('value semantics', () {
    const variable = TemplateVariable(
      name: 'p',
      description: 'd',
      defaultValue: 'v',
      replaces: 'r',
    );
    const substitution = Substitution(from: 'a', to: 'b');

    test('equal values hash equally', () {
      // The contract Set and Map rely on: unequal hashes for equal values
      // silently break lookup.
      expect(
        const TemplateVariable(
          name: 'p',
          description: 'd',
          defaultValue: 'v',
          replaces: 'r',
        ).hashCode,
        variable.hashCode,
      );
      expect(
        const Substitution(from: 'a', to: 'b').hashCode,
        substitution.hashCode,
      );

      const m = Manifest(
        name: 'n',
        version: '1',
        variables: [variable],
        extraSubstitutions: [substitution],
      );
      const same = Manifest(
        name: 'n',
        version: '1',
        variables: [variable],
        extraSubstitutions: [substitution],
      );
      expect(same.hashCode, m.hashCode);
      // Added one at a time so the analyzer cannot fold the duplicate away —
      // deduping at runtime is the property under test.
      final seen = <Manifest>{}
        ..add(m)
        ..add(same);
      expect(seen, hasLength(1), reason: 'a Set must dedupe them');
    });

    test('differing values are unequal', () {
      expect(variable, isNot(const TemplateVariable(name: 'q')));
      expect(substitution, isNot(const Substitution(from: 'a', to: 'c')));
      expect(
        const Manifest(name: 'n', version: '1'),
        isNot(const Manifest(name: 'n', version: '2')),
      );
    });

    test('toString names the fields, for a readable test failure', () {
      expect(variable.toString(), allOf(contains('p'), contains('r')));
      expect(substitution.toString(), contains('a'));
      expect(
        const Manifest(name: 'n', version: '1').toString(),
        contains('name: n'),
      );
    });

    test('provenance is outside equality', () {
      // `source` and `path` record where a manifest came from, not what it
      // means — including them would make a toYaml round trip impossible.
      final parsed = Manifest.fromYaml('name: n\nversion: 1\n', path: '/x');
      expect(parsed, const Manifest(name: 'n', version: '1'));
      expect(parsed.path, '/x');
      expect(parsed.source, isNotNull);
    });

    test('fromFile on a missing path is a FormatException', () {
      expect(
        () => Manifest.fromFile('/nonexistent/mold.yaml'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
