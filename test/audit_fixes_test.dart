import 'dart:io';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

/// Matches a [ValidationException] carrying [code].
Matcher rejectsWith(String code) => throwsA(
  isA<ValidationException>().having(
    (e) => e.errors.map((x) => x.code),
    'codes',
    contains(code),
  ),
);

void main() {
  late Directory tmp;
  late Directory src;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mold_audit_');
    src = Directory('${tmp.path}/src')..createSync(recursive: true);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String rel, String content) {
    File('${src.path}/$rel')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  Future<List<int>> pack(String manifest) => const Bundler().bundle(
    projectDir: src.path,
    manifest: Manifest.fromYaml(manifest),
  );

  group('rename collisions', () {
    test('two path_renames onto one path are refused, not merged', () async {
      write('alpha.txt', 'I am alpha\n');
      write('beta.txt', 'I am beta\n');
      final archive = await pack('''
name: t
version: 1
path_renames:
  - from: alpha.txt
    to: same.txt
  - from: beta.txt
    to: same.txt
''');

      // Before this check the writer created same.txt twice and the second
      // entry won, so an archive holding two files unpacked into one.
      expect(
        () => const Unbundler().unbundleBytes(
          source: archive,
          targetDir: '${tmp.path}/out',
        ),
        rejectsWith(RenameValidator.collision),
      );
      expect(
        Directory('${tmp.path}/out').existsSync(),
        isFalse,
        reason: 'nothing may be written once the mapping is known to be lossy',
      );
    });

    test('a `replaces` token whose casings converge is refused too', () async {
      // The reachable form: a project that spells its own name both ways, and
      // a single-word value whose snake and kebab forms are identical.
      write('my_app.txt', 'snake spelling\n');
      write('my-app.txt', 'kebab spelling\n');
      final archive = await pack('''
name: t
version: 1
variables:
  n:
    default: my_app
    replaces: my_app
''');

      expect(
        () => const Unbundler().unbundleBytes(
          source: archive,
          targetDir: '${tmp.path}/out',
          vars: const {'n': 'shop'},
        ),
        rejectsWith(RenameValidator.collision),
      );
    });

    test('the message names every colliding source', () {
      final result = const RenameValidator().validate({
        'a.txt': 'same.txt',
        'b.txt': 'same.txt',
        'c.txt': 'other.txt',
      });

      expect(result.errors, hasLength(1));
      expect(
        result.errors.single.message,
        allOf(contains('a.txt'), contains('b.txt'), contains('same.txt')),
      );
      expect(
        result.errors.single.message,
        isNot(contains('c.txt')),
        reason: 'a path only one entry claims is not a collision',
      );
    });

    test('a dry run refuses what the real unpack refuses', () async {
      write('alpha.txt', 'a\n');
      write('beta.txt', 'b\n');
      final archive = await pack('''
name: t
version: 1
path_renames:
  - from: alpha.txt
    to: same.txt
  - from: beta.txt
    to: same.txt
''');

      // The preview must not report a plan the unpack would reject.
      expect(
        () => const Unbundler().plan(bytes: archive),
        rejectsWith(RenameValidator.collision),
      );
    });

    test('distinct destinations still pass', () async {
      write('alpha.txt', 'a\n');
      write('beta.txt', 'b\n');
      final archive = await pack('name: t\nversion: 1\n');

      await const Unbundler().unbundleBytes(
        source: archive,
        targetDir: '${tmp.path}/out',
      );
      expect(Directory('${tmp.path}/out').listSync(), hasLength(2));
    });
  });

  group('every substitution template is validated', () {
    test('a `from` shared with path_renames no longer hides one', () {
      // replacementTemplates used to be keyed by `from`, so these two entries
      // collapsed and only the innocent one was ever checked.
      final result = const ManifestValidator().validate(
        Manifest.fromYaml('''
name: t
version: 1
extra_substitutions:
  - from: acme
    to: "{{ nope | bogusTransform }}"
path_renames:
  - from: acme
    to: "acme"
'''),
      );

      expect(
        result.errors.map((e) => e.code),
        contains(ManifestValidator.unknownTransform),
      );
    });

    test('the hidden entry is checked for unknown variables too', () {
      // A separate case because a placeholder with a bad transform never
      // becomes a placeholder — the parser cannot report a variable it failed
      // to parse. Only a well-formed one reaches the unknown-variable check.
      final result = const ManifestValidator().validate(
        Manifest.fromYaml('''
name: t
version: 1
extra_substitutions:
  - from: acme
    to: "{{ nope | camelCase }}"
path_renames:
  - from: acme
    to: "acme"
'''),
      );

      expect(
        result.errors.map((e) => e.code),
        contains(ManifestValidator.unknownVariable),
      );
    });

    test('two entries in one section are both checked', () {
      final result = const ManifestValidator().validate(
        Manifest.fromYaml('''
name: t
version: 1
extra_substitutions:
  - from: dup
    to: "{{ missing_a }}"
  - from: dup
    to: "{{ missing_b }}"
'''),
      );

      expect(
        result.errors.where((e) => e.code == ManifestValidator.unknownVariable),
        hasLength(2),
      );
    });

    test('a bad template no longer deletes the text it replaces', () {
      // Rendering a malformed placeholder yields the empty string, so before
      // the fix this packed clean and silently dropped the word `acme`.
      write('a.txt', 'acme super_server\n');
      expect(
        () => pack('''
name: t
version: 1
variables:
  p:
    default: my_project
    replaces: super_server
extra_substitutions:
  - from: acme
    to: "{{ nope | bogusTransform }}"
path_renames:
  - from: acme
    to: "acme"
'''),
        rejectsWith(ManifestValidator.unknownTransform),
      );
    });
  });

  group('use_gitignore parsing', () {
    // YAML 1.1 read these as booleans; package:yaml is 1.2, where they are
    // plain strings, and `as bool?` turned that into an exit-255 TypeError.
    for (final value in ['yes', 'on', '1', '"false"', 'maybe']) {
      test('`use_gitignore: $value` is a FormatException, not a crash', () {
        final yaml = 'name: t\nversion: 1\nuse_gitignore: $value\n';
        expect(
          () => Manifest.fromYaml(yaml),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('use_gitignore'),
            ),
          ),
        );
      });
    }

    test('the CLI reports it as exit 1, not 255', () async {
      write('super_server.txt', 'super_server\n');
      File('${tmp.path}/m.yaml').writeAsStringSync(
        'name: t\nversion: 1\nuse_gitignore: yes\n',
      );
      final err = StringBuffer();

      final code = await runBundleCli([
        'pack',
        src.path,
        '-m',
        '${tmp.path}/m.yaml',
        '-o',
        '${tmp.path}/out.mold',
      ], err: err);

      expect(code, 1);
      expect(err.toString(), contains('use_gitignore'));
    });

    test('real booleans still parse', () {
      expect(
        Manifest.fromYaml(
          'name: t\nversion: 1\nuse_gitignore: false\n',
        ).useGitignore,
        isFalse,
      );
      expect(
        Manifest.fromYaml(
          'name: t\nversion: 1\nuse_gitignore: true\n',
        ).useGitignore,
        isTrue,
      );
      expect(Manifest.fromYaml('name: t\nversion: 1\n').useGitignore, isTrue);
    });
  });

  group('unknown --var', () {
    test('a mistyped key is an error, not a silent fallback', () async {
      write('super_server.txt', 'super_server\n');
      final archive = await pack('''
name: t
version: 1
variables:
  project_name:
    default: fallback_name
    replaces: super_server
''');

      expect(
        () => const Unbundler().unbundleBytes(
          source: archive,
          targetDir: '${tmp.path}/out',
          vars: const {'projectname': 'what_i_meant'},
        ),
        rejectsWith(VariablesValidator.unknown),
      );
    });

    test('the message lists the names that do exist', () {
      final result = const VariablesValidator().validate(
        const VariablesInput(
          variables: [
            TemplateVariable(name: 'project_name', defaultValue: 'x'),
            TemplateVariable(name: 'org', defaultValue: 'y'),
          ],
          values: {'project_name': 'x', 'org': 'y'},
          explicit: {'projectname': 'typo'},
        ),
      );

      expect(result.errors.single.code, VariablesValidator.unknown);
      expect(
        result.errors.single.message,
        allOf(contains('projectname'), contains('org, project_name')),
      );
    });

    test('a correctly spelled key passes', () {
      final result = const VariablesValidator().validate(
        const VariablesInput(
          variables: [TemplateVariable(name: 'project_name')],
          values: {'project_name': 'x'},
          explicit: {'project_name': 'x'},
        ),
      );

      expect(result.isValid, isTrue);
    });

    test('the CLI surfaces it', () async {
      write('super_server.txt', 'super_server\n');
      final archive = await pack('''
name: t
version: 1
variables:
  project_name:
    default: fallback_name
    replaces: super_server
''');
      File('${tmp.path}/t.mold').writeAsBytesSync(archive);
      final err = StringBuffer();

      final code = await runBundleCli([
        'unpack',
        '${tmp.path}/t.mold',
        '-t',
        '${tmp.path}/out',
        '--var',
        'projectname=oops',
        '--no-prompt',
      ], err: err);

      expect(code, 1);
      expect(err.toString(), contains('VARIABLE_UNKNOWN'));
    });
  });

  group('unpack surfaces manifest warnings', () {
    test('a variable that does nothing is reported at unpack too', () async {
      write('a.txt', 'hello\n');
      final packWarnings = <String>[];
      final archive = await const Bundler().bundle(
        projectDir: src.path,
        manifest: Manifest.fromYaml('''
name: t
version: 1
variables:
  dead_var:
    default: nothing
'''),
        onWarning: packWarnings.add,
      );
      expect(
        packWarnings.single,
        contains(ManifestValidator.unusedVariable),
        reason: 'pack already reported it',
      );

      final unpackWarnings = <String>[];
      await const Unbundler().unbundleBytes(
        source: archive,
        targetDir: '${tmp.path}/out',
        onWarning: unpackWarnings.add,
      );

      // Whoever unpacks a template is rarely whoever packed it, so a warning
      // that only reaches the author reaches nobody.
      expect(unpackWarnings.single, contains(ManifestValidator.unusedVariable));
    });

    test('a dry run is no quieter than the unpack it previews', () async {
      write('a.txt', 'hello\n');
      final archive = await pack('''
name: t
version: 1
variables:
  dead_var:
    default: nothing
''');

      final warnings = <String>[];
      const Unbundler().plan(bytes: archive, onWarning: warnings.add);

      expect(warnings.single, contains(ManifestValidator.unusedVariable));
    });
  });

  group('one scan per pack', () {
    test('a caller-supplied scan is the one validated', () {
      write('a.txt', 'hello\n');
      final manifest = Manifest.fromYaml('name: t\nversion: 1\n');
      final scan = ProjectValidator.scanFor(src.path, manifest);

      // Handing the scan over must not change the verdict, only the cost.
      expect(
        const ProjectValidator()
            .validate(
              ProjectInput(dir: src.path, manifest: manifest, scan: scan),
            )
            .isValid,
        isTrue,
      );
    });

    test('a missing directory is still PROJECT_DIR_NOT_FOUND, not a crash', () {
      // Bundler skips the scan when the directory is absent precisely so this
      // stays a structured error instead of a bare FileSystemException.
      expect(
        () => const Bundler().bundle(
          projectDir: '${tmp.path}/nope',
          manifest: Manifest.fromYaml('name: t\nversion: 1\n'),
        ),
        rejectsWith(ProjectValidator.dirNotFound),
      );
    });
  });

  group('unified diff, trailing newline', () {
    const differ = UnifiedDiff();

    test('losing the final newline is a visible change', () {
      final rendered = differ.render(
        before: 'line\n',
        after: 'line',
        fromLabel: 'a',
        toLabel: 'a',
      );

      // It used to render empty: both sides split to ['line'], so the diff
      // reported no change while the summary counted a replacement.
      expect(rendered, isNotEmpty);
      expect(rendered, contains(r'\ No newline at end of file'));
      expect(rendered, contains('-line'));
      expect(rendered, contains('+line'));
    });

    test('gaining a final newline is visible too', () {
      expect(
        differ.render(
          before: 'line',
          after: 'line\n',
          fromLabel: 'a',
          toLabel: 'a',
        ),
        contains(r'\ No newline at end of file'),
      );
    });

    test('a change in a file that has no final newline is marked', () {
      final rendered = differ.render(
        before: 'a\nsuper_server',
        after: 'a\nmy_project',
        fromLabel: 'x',
        toLabel: 'x',
      );

      expect(rendered, contains(r'\ No newline at end of file'));
      // Marked on both sides: neither version ends in a newline.
      expect(
        r'\ No newline at end of file'.allMatches(rendered).length,
        2,
      );
    });

    test('an ordinary newline-terminated file carries no marker', () {
      expect(
        differ.render(
          before: 'super_server\n',
          after: 'my_project\n',
          fromLabel: 'x',
          toLabel: 'x',
        ),
        isNot(contains('No newline')),
      );
    });
  });

  group('OutputFormat.fromFlag', () {
    test('an unknown flag is a FormatException naming the valid ones', () {
      expect(
        () => OutputFormat.fromFlag('yaml'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('yaml'), contains('tar.gz'), contains('base64')),
          ),
        ),
      );
    });

    test('the real flags still resolve', () {
      expect(OutputFormat.fromFlag('tar.gz'), OutputFormat.tarGz);
      expect(OutputFormat.fromFlag('base64'), OutputFormat.base64);
    });
  });
}
