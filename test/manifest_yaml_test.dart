import 'dart:io';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

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

      final parsed = Manifest.fromYaml(original.toYaml());

      expect(parsed.name, original.name);
      expect(parsed.version, original.version);
      expect(parsed.include, original.include);
      expect(parsed.exclude, original.exclude);
      expect(parsed.noSubstitute, original.noSubstitute);
      expect(parsed.binaryExtensions, original.binaryExtensions);
      expect(parsed.variables, hasLength(2));
      expect(parsed.variables.first.name, 'project_name');
      expect(parsed.variables.first.description, 'The new project name');
      expect(parsed.variables.first.defaultValue, 'my_project');
      expect(parsed.variables.first.replaces, 'super_server');
      expect(parsed.variables[1].name, 'bare');
      expect(parsed.variables[1].replaces, isNull);
      expect(parsed.extraSubstitutions, hasLength(1));
      expect(parsed.extraSubstitutions.first.from, 'https://api.super.dev');
      expect(parsed.extraSubstitutions.first.to, 'https://x.example');
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

    test('omits empty sections', () {
      const minimal = Manifest(name: 'x', version: '1');
      final yaml = minimal.toYaml();

      expect(yaml, isNot(contains('include:')));
      expect(yaml, isNot(contains('variables:')));
      expect(yaml, isNot(contains('extra_substitutions:')));
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
}
