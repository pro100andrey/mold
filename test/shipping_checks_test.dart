import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/internals.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('mold_checks_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String rel, String content) {
    File(p.join(tmp.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  Manifest named(String token, {List<Substitution> extra = const []}) =>
      Manifest(
        name: 'x',
        version: '1',
        variables: [TemplateVariable(name: 'name', replaces: token)],
        extraSubstitutions: extra,
      );

  List<ValidationError> warnings(Manifest manifest, String code) =>
      const ProjectValidator()
          .validate(ProjectInput(dir: tmp.path, manifest: manifest))
          .warnings
          .where((w) => w.code == code)
          .toList();

  group('spellings no casing covers', () {
    test("Flutter's bundle id and product name are reported", () {
      write('lib/main.dart', 'app_template');
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'PRODUCT_BUNDLE_IDENTIFIER = com.example.appTemplate;\n'
            'PRODUCT_BUNDLE_IDENTIFIER = com.example.appTemplate.RunnerTests;',
      );
      write('macos/AppInfo.xcconfig', 'PRODUCT_NAME = App Template');

      final found = warnings(
        named('app_template'),
        MoldCode.projectUncoveredCasing,
      );

      expect(found, hasLength(1));
      final message = found.single.message;
      expect(message, contains("'appTemplate' (2"));
      expect(message, contains("'App Template' (1"));
      expect(message, contains('to: "{{ name | camelCase }}"'));
      expect(message, contains('to: "{{ name | titleCase }}"'));
    });

    test('a spelling no transform produces is named without a guess', () {
      write('a.txt', 'app_template app.template');

      final message = warnings(
        named('app_template'),
        MoldCode.projectUncoveredCasing,
      ).single.message;

      expect(message, contains("No transform produces 'app.template'"));
      expect(message, isNot(contains('from: "app.template"')));
    });

    test('a run-together spelling is flatCase', () {
      write('android/build.gradle', 'applicationId "com.example.apptemplate"');

      final message = warnings(
        named('app_template'),
        MoldCode.projectUncoveredCasing,
      ).single.message;

      expect(message, contains('from: "apptemplate"'));
      expect(message, contains('to: "{{ name | flatCase }}"'));
    });

    test('derived casings and longer words are not variants', () {
      write(
        'a.txt',
        'app_template app-template APP_TEMPLATE AppTemplate '
            'myapptemplate appTemplater',
      );

      expect(
        warnings(named('app_template'), MoldCode.projectUncoveredCasing),
        isEmpty,
      );
    });

    test('a spelling an explicit substitution claims is not reported', () {
      write('a.txt', 'app_template com.example.appTemplate');

      final manifest = named(
        'app_template',
        extra: const [
          Substitution(from: 'appTemplate', to: '{{ name | camelCase }}'),
        ],
      );

      expect(warnings(manifest, MoldCode.projectUncoveredCasing), isEmpty);
    });

    test('following the suggestion renames the site', () async {
      write('pubspec.yaml', 'name: app_template\n');
      write('ios/Info.plist', 'com.example.appTemplate');
      final archive = await const Bundler().bundle(
        projectDir: tmp.path,
        manifest: named(
          'app_template',
          extra: const [
            Substitution(from: 'appTemplate', to: '{{ name | camelCase }}'),
          ],
        ),
      );
      final plan = const Unbundler().plan(
        bytes: archive,
        vars: {'name': 'my_shop'},
      );

      expect(
        plan.files.singleWhere((f) => f.to == 'ios/Info.plist').after,
        'com.example.myShop',
      );
    });
  });

  group('unknown manifest keys', () {
    test('are reported with the key they probably mean', () {
      final m = Manifest.fromYaml('''
name: x
version: 1
excludes: [build/**]
variables:
  name:
    replace: app
extra_substitutions:
  - from: a
    to: b
    form: c
''');

      final found = const ManifestValidator()
          .validate(m)
          .warnings
          .where((w) => w.code == MoldCode.manifestUnknownKey)
          .map((w) => w.message)
          .toList();

      expect(found, hasLength(3));
      expect(found[0], contains("'excludes' — did you mean 'exclude'?"));
      expect(found[1], contains("'variables.name.replace'"));
      expect(found[1], contains("'replaces'"));
      expect(found[2], contains("'extra_substitutions[0].form'"));
    });

    test('a key far from every known one gets no guess', () {
      final m = Manifest.fromYaml('name: x\nversion: 1\nflavour: dark\n');

      expect(
        const ManifestValidator().validate(m).warnings.single.message,
        "Unknown manifest key 'flavour'. It is ignored.",
      );
    });

    test('are not part of equality', () {
      expect(
        Manifest.fromYaml('name: x\nversion: 1\nextra: 1\n'),
        Manifest.fromYaml('name: x\nversion: 1\n'),
      );
    });
  });

  group('secrets', () {
    const plain = Manifest(name: 'x', version: '1');

    List<String> flagged() => [
      for (final w in warnings(plain, MoldCode.projectSecretSuspected))
        w.field!,
    ];

    test('are found by name', () {
      for (final rel in [
        '.env',
        '.env.production',
        'android/key.properties',
        'android/app/google-services.json',
        'certs/server.pem',
        'android/upload.jks',
        '.ssh/id_ed25519',
      ]) {
        write(rel, 'x');
      }
      write('README.md', 'readme');

      expect(flagged().toSet(), {
        '.env',
        '.env.production',
        'android/key.properties',
        'android/app/google-services.json',
        'certs/server.pem',
        'android/upload.jks',
        '.ssh/id_ed25519',
      });
    });

    test('and by content', () {
      // Assembled at run time: as literals, these trip the secret scan of
      // `dart pub publish` — the very kind of check being tested.
      final aws = ['AKIA', 'ABCDEFGHIJKLMNOP'].join();
      final google = ['AIza', 'SyA1234567890abcdefghijklmnopqrstuv'].join();
      final pem = ['-----BEGIN RSA ', 'PRIVATE KEY-----'].join();
      write('lib/a.dart', "const key = '$aws';");
      write(
        'lib/firebase_options.dart',
        "apiKey: '$google',",
      );
      write('b.txt', '$pem\nabc\n');
      write('c.txt', 'nothing to see');

      final found = warnings(plain, MoldCode.projectSecretSuspected);

      expect(found.map((w) => w.field).toSet(), {
        'lib/a.dart',
        'lib/firebase_options.dart',
        'b.txt',
      });
      expect(
        found.singleWhere((w) => w.field == 'lib/a.dart').message,
        contains('an AWS access key id'),
      );
    });

    test('templates meant to be committed are not flagged', () {
      write('.env.example', 'API_KEY=');
      write('.env.sample', 'API_KEY=');

      expect(flagged(), isEmpty);
    });
  });

  group('paths that do not port', () {
    const plain = Manifest(name: 'x', version: '1');

    test('are reported for Windows', () {
      for (final rel in ['docs/a:b.md', 'aux.txt', 'lib/con/x.dart', 'end.']) {
        write(rel, 'x');
      }
      write('fine.txt', 'x');

      final found = warnings(plain, MoldCode.projectPathNotPortable);

      expect(found.map((w) => w.field).toSet(), {
        'docs/a:b.md',
        'aux.txt',
        'lib/con/x.dart',
        'end.',
      });
    }, testOn: '!windows');

    test('pairs that differ only in case are reported', () {
      write('README.md', 'a');
      write('readme.md', 'b');

      final found = warnings(plain, MoldCode.projectPathNotPortable);

      expect(found.single.message, contains('differ only in case'));
    }, testOn: 'linux');

    test('after renaming, too', () {
      final r = const RenameValidator().validate({
        'a/Foo.txt': 'a/My.txt',
        'a/bar.txt': 'a/my.txt',
      });

      expect(r.isValid, isTrue);
      expect(r.warnings.single.code, MoldCode.renameCaseCollision);
    });
  });

  group('unpacking on Windows', () {
    const renames = {'a/notes.txt': 'a/my:notes.txt', 'b/x.txt': 'b/CON.txt'};

    test('refuses names Windows cannot create', () {
      final r = const RenameValidator(windows: true).validate(renames);

      expect(r.errors.map((e) => e.code), [
        MoldCode.renameInvalidName,
        MoldCode.renameInvalidName,
      ]);
      expect(r.errors.first.message, contains("contains ':'"));
      expect(r.errors.last.message, contains('reserved device name'));
    });

    test('elsewhere they unpack', () {
      expect(const RenameValidator().validate(renames).isValid, isTrue);
    });
  });

  group("a variable's value already in the template", () {
    Future<List<ValidationError>> planWarnings(String value) async {
      write('lib/super_server.dart', 'class SuperServer {}\nclass MyApp {}\n');
      final archive = await const Bundler().bundle(
        projectDir: tmp.path,
        manifest: named('super_server'),
      );
      final found = <ValidationError>[];
      const Unbundler().plan(
        bytes: archive,
        vars: {'name': value},
        onWarning: found.add,
      );

      return found
          .where((w) => w.code == MoldCode.variableValuePresent)
          .toList();
    }

    test('is reported, naming what it merges with', () async {
      final found = await planWarnings('my_app');

      expect(found.single.message, contains("'MyApp' 1 time(s)"));
      expect(found.single.message, contains("'SuperServer' also becomes it"));
    });

    test('is not reported for a value that is not there', () async {
      expect(await planWarnings('acme_shop'), isEmpty);
    });

    test('is not reported inside a longer word', () async {
      // `MyApplication` holds `MyApp`, but not as a word.
      write('lib/other.dart', 'class MyApplication {}');

      final found = await planWarnings('my_app');

      expect(found.single.message, contains("'MyApp' 1 time(s)"));
    });
  });

  group('overwriting edits made since the stamped unpack', () {
    test('is flagged, and identical or untouched files are not', () async {
      final project = Directory(p.join(tmp.path, 'src'))..createSync();
      File(p.join(project.path, 'a.txt')).writeAsStringSync('one\n');
      File(p.join(project.path, 'b.txt')).writeAsStringSync('two\n');
      final archive = await const Bundler().bundle(
        projectDir: project.path,
        manifest: const Manifest(name: 't', version: '1'),
      );
      final target = p.join(tmp.path, 'out');
      await const Unbundler().unbundle(
        bytes: archive,
        targetDir: target,
        stamp: true,
      );
      File(p.join(target, 'a.txt')).writeAsStringSync('one, edited\n');

      final warnings = <ValidationError>[];
      final plan = const Unbundler().plan(
        bytes: archive,
        targetDir: target,
        overwrite: true,
        onWarning: warnings.add,
      );

      expect(plan.edited.map((f) => f.to), ['a.txt']);
      expect(
        warnings
            .singleWhere((w) => w.code == MoldCode.unpackOverwritesEdits)
            .message,
        contains('a.txt'),
      );
    });
  });
}
