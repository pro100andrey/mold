import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/internals.dart';

void main() {
  late Directory tmp;
  late Directory project;
  late String archive;

  void write(Directory root, String rel, String content) {
    File(p.join(root.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  /// Runs the CLI; returns the exit code, stdout and stderr.
  Future<(int, String, String)> mold(List<String> args) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runBundleCli(args, out: out, err: err);

    return (code, out.toString(), err.toString());
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mold_cli_features_');
    project = Directory(p.join(tmp.path, 'super_server'))..createSync();
    write(project, 'mold.yaml', '''
name: super_server
version: 1.2.0
variables:
  name:
    description: The package name.
    replaces: super_server
  platform:
    choices: [android, ios]
    default: android
extra_substitutions:
  - from: "{{PLATFORM}}"
    to: "{{ platform }}"
''');
    write(project, 'pubspec.yaml', 'name: super_server\n');
    write(project, 'lib/super_server.dart', '// {{PLATFORM}}\n');
    archive = p.join(tmp.path, 't.mold');
    final (code, _, err) = await mold(['pack', project.path, '-o', archive]);
    expect(code, 0, reason: err);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String target([String name = 'out']) => p.join(tmp.path, name);

  group('pack --check', () {
    late String embed;

    setUp(() => embed = p.join(tmp.path, 'lib', 'template.dart'));

    List<String> pack(List<String> extra) => [
      'pack',
      project.path,
      '-f',
      'bytes',
      '-o',
      embed,
      ...extra,
    ];

    test('passes when the committed file is what packing writes', () async {
      expect((await mold(pack([]))).$1, 0);

      final (code, _, err) = await mold(pack(['--check']));

      expect(code, 0);
      expect(err, contains('Up to date'));
    });

    test('fails, writing nothing, when the project moved on', () async {
      expect((await mold(pack([]))).$1, 0);
      final before = File(embed).readAsBytesSync();
      write(project, 'lib/new.dart', '// super_server\n');

      final (code, _, err) = await mold(pack(['--check']));

      expect(code, 1);
      expect(err, contains('Stale'));
      expect(File(embed).readAsBytesSync(), before);
    });

    test('fails when the file does not exist', () async {
      final (code, _, err) = await mold(pack(['--check']));

      expect(code, 1);
      expect(err, contains('does not exist'));
      expect(File(embed).existsSync(), isFalse);
    });

    test('cannot be combined with --dry-run', () async {
      expect((await mold(pack(['--check', '--dry-run']))).$1, 64);
    });

    test('compression does not make it stale; content does', () async {
      // Written by another compressor — the VM's zlib, another level — as
      // another OS or SDK would. The content is the same, so it is current.
      expect((await mold(pack(['--fast', '--level', '9']))).$1, 0);
      final other = p.join(tmp.path, 'default.dart');
      expect(
        (await mold(['pack', project.path, '-f', 'bytes', '-o', other])).$1,
        0,
      );
      // Otherwise this would pass under a byte comparison too.
      expect(
        File(embed).readAsBytesSync(),
        isNot(File(other).readAsBytesSync()),
      );

      expect((await mold(pack(['--check']))).$1, 0);
      expect((await mold(pack(['--check', '--level', '0']))).$1, 0);
    });

    test('names what changed', () async {
      expect((await mold(pack([]))).$1, 0);
      write(project, 'lib/super_server.dart', '// changed\n');
      write(project, 'lib/extra.dart', '// new\n');

      final (code, _, err) = await mold(pack(['--check']));

      expect(code, 1);
      expect(err, contains('1 changed (lib/super_server.dart)'));
      expect(err, contains('1 added (lib/extra.dart)'));
    });

    test('a different declaration name is stale', () async {
      expect((await mold(pack(['-n', 'other']))).$1, 0);

      final (code, _, err) = await mold(pack(['--check']));

      expect(code, 1);
      expect(err, contains('the source around the archive differs'));
    });

    test('a tar.gz archive is checked by content too', () async {
      final out = p.join(tmp.path, 'committed.mold');
      expect(
        (await mold(['pack', project.path, '-o', out, '--fast'])).$1,
        0,
      );

      expect((await mold(['pack', project.path, '-o', out, '--check'])).$1, 0);
    });

    test('a bad --level is a usage error', () async {
      expect((await mold(pack(['--level', '10']))).$1, 64);
    });
  });

  group('inspect', () {
    test('describes the template without unpacking it', () async {
      final (code, _, err) = await mold(['inspect', archive]);

      expect(code, 0);
      expect(err, contains('super_server 1.2.0 — 3 files'));
      expect(err, contains('name  replaces super_server · required'));
      expect(err, contains('The package name.'));
      expect(err, contains('one of android, ios'));
      expect(err, contains('{{PLATFORM}}  ->  {{ platform }}'));
      expect(err, isNot(contains('lib/super_server.dart')));
    });

    test('--files lists the files', () async {
      final (_, _, err) = await mold(['inspect', archive, '--files']);

      expect(err, contains('lib/super_server.dart'));
    });

    test('--json is the whole description', () async {
      final (code, out, _) = await mold(['inspect', archive, '--json']);
      final doc = jsonDecode(out) as Map<String, Object?>;

      expect(code, 0);
      expect(doc['name'], 'super_server');
      expect((doc['files']! as List<Object?>).length, 3);
      expect(
        (doc['variables']! as List<Object?>).first,
        containsPair('replaces', 'super_server'),
      );
    });

    test('a missing archive is ARCHIVE_NOT_FOUND', () async {
      final (code, _, err) = await mold(['inspect', p.join(tmp.path, 'x')]);

      expect(code, 1);
      expect(err, contains(MoldCode.archiveNotFound));
    });
  });

  group('--vars-file', () {
    List<String> unpack(List<String> extra) => [
      'unpack',
      archive,
      '-t',
      target(),
      '--no-prompt',
      ...extra,
    ];

    test('supplies values from a YAML map', () async {
      final vars = File(p.join(tmp.path, 'vars.yaml'))
        ..writeAsStringSync('name: my_app\nplatform: ios\n');

      final (code, _, err) = await mold(unpack(['--vars-file', vars.path]));

      expect(code, 0, reason: err);
      expect(
        File(p.join(target(), 'lib', 'my_app.dart')).readAsStringSync(),
        '// ios\n',
      );
    });

    test('numbers keep the spelling they were written with', () async {
      // YAML reads 1.10 as 1.1 and 007 as 7; a vars file is text.
      write(project, 'mold.yaml', '''
name: super_server
version: 1.10
variables:
  name:
    replaces: super_server
  build:
    default: "0"
extra_substitutions:
  - from: BUILD
    to: "{{ build }}"
''');
      write(project, 'lib/super_server.dart', '// BUILD\n');
      expect((await mold(['pack', project.path, '-o', archive])).$1, 0);
      final vars = File(p.join(tmp.path, 'vars.yaml'))
        ..writeAsStringSync('name: my_app\nbuild: 007\n');

      final (code, _, err) = await mold(unpack(['--vars-file', vars.path]));
      final (_, _, info) = await mold(['inspect', archive]);

      expect(code, 0, reason: err);
      expect(
        File(p.join(target(), 'lib', 'my_app.dart')).readAsStringSync(),
        '// 007\n',
      );
      expect(info, contains('super_server 1.10'));
    });

    test('--var overrides it', () async {
      final vars = File(p.join(tmp.path, 'vars.json'))
        ..writeAsStringSync('{"name": "my_app", "platform": "ios"}');

      final (code, _, _) = await mold(
        unpack(['--vars-file', vars.path, '--var', 'platform=android']),
      );

      expect(code, 0);
      expect(
        File(p.join(target(), 'lib', 'my_app.dart')).readAsStringSync(),
        '// android\n',
      );
    });

    test('an unknown key is VARIABLE_UNKNOWN, as for --var', () async {
      final vars = File(p.join(tmp.path, 'vars.yaml'))
        ..writeAsStringSync('name: my_app\nnmae: typo\n');

      final (code, _, err) = await mold(unpack(['--vars-file', vars.path]));

      expect(code, 1);
      expect(err, contains(MoldCode.variableUnknown));
    });

    test('a value that is not a scalar is a usage error', () async {
      final vars = File(p.join(tmp.path, 'vars.yaml'))
        ..writeAsStringSync('name: [a, b]\n');

      expect((await mold(unpack(['--vars-file', vars.path]))).$1, 64);
    });

    test('a missing file is a usage error', () async {
      expect((await mold(unpack(['--vars-file', 'nope.yaml']))).$1, 64);
    });

    test('a choice outside the list is VARIABLE_NOT_A_CHOICE', () async {
      final (code, _, err) = await mold(
        unpack(['--var', 'name=my_app', '--var', 'platform=web']),
      );

      expect(code, 1);
      expect(err, contains(MoldCode.variableNotAChoice));
    });
  });

  group('--stamp', () {
    List<String> unpack(List<String> extra) => [
      'unpack',
      archive,
      '-t',
      target(),
      '--no-prompt',
      '--var',
      'name=my_app',
      ...extra,
    ];

    UnpackStamp readStamp() => UnpackStamp.tryParse(
      File(p.join(target(), '.mold.json')).readAsStringSync(),
    )!;

    test('records the template, values and files', () async {
      expect((await mold(unpack(['--stamp']))).$1, 0);

      final stamp = readStamp();
      expect(stamp.template, 'super_server');
      expect(stamp.version, '1.2.0');
      expect(stamp.vars, {'name': 'my_app', 'platform': 'android'});
      expect(stamp.files.keys, [
        'lib/my_app.dart',
        'mold.yaml',
        'pubspec.yaml',
      ]);
    });

    test('feeds a regeneration through --vars-file', () async {
      expect((await mold(unpack(['--stamp', '--var', 'platform=ios']))).$1, 0);
      final stampPath = p.join(target(), '.mold.json');

      final (code, _, err) = await mold([
        'unpack',
        archive,
        '-t',
        target(),
        '--no-prompt',
        '--force',
        '--vars-file',
        stampPath,
      ]);

      expect(code, 0, reason: err);
      expect(readStamp().vars['platform'], 'ios');
    });

    test('a regeneration reports files the template dropped', () async {
      expect((await mold(unpack(['--stamp']))).$1, 0);
      // A newer template without lib/: what the previous unpack wrote there
      // is now stale.
      File(p.join(project.path, 'lib', 'super_server.dart')).deleteSync();
      write(project, 'mold.yaml', '''
name: super_server
version: 1.3.0
variables:
  name:
    replaces: super_server
''');
      expect((await mold(['pack', project.path, '-o', archive])).$1, 0);

      final (dryCode, _, dryErr) = await mold(
        unpack(['--force', '--dry-run']),
      );
      expect(dryCode, 0);
      expect(
        dryErr,
        stringContainsInOrder([
          'No longer in the template (left in place)',
          'lib/my_app.dart',
        ]),
      );

      final (code, _, err) = await mold(unpack(['--force']));
      expect(code, 0);
      expect(err, contains(MoldCode.unpackStaleFiles));
      expect(
        File(p.join(target(), 'lib', 'my_app.dart')).existsSync(),
        isTrue,
        reason: 'stale files are reported, never deleted',
      );
      expect(readStamp().version, '1.3.0', reason: 'kept up to date');
      // Kept, with its old digest, so the next regeneration reports it too.
      expect(readStamp().files.keys, contains('lib/my_app.dart'));
      final (_, _, again) = await mold(unpack(['--force']));
      expect(again, contains(MoldCode.unpackStaleFiles));
    });

    test("a project's own stamp is never packed", () async {
      // A stamped project packed back into a template must not hand its
      // author's values and history to every later unpack.
      write(project, '.mold.json', '{"mold_stamp": 1}');
      expect((await mold(['pack', project.path, '-o', archive])).$1, 0);

      final (_, _, err) = await mold(['inspect', archive, '--files']);
      expect(err, isNot(contains('.mold.json')));
      expect((await mold(unpack(['--stamp']))).$1, 0);
    });

    test('a template file renamed onto the stamp collides', () async {
      write(project, 'mold.yaml', '''
name: super_server
version: 1
variables:
  name:
    replaces: super_server
path_renames:
  - from: pubspec.yaml
    to: .mold.json
''');
      expect((await mold(['pack', project.path, '-o', archive])).$1, 0);

      final (code, _, err) = await mold(unpack(['--stamp']));

      expect(code, 1);
      expect(err, contains(MoldCode.renameCollision));
    });
  });

  group('--json', () {
    test('a dry run is a JSON plan on stdout', () async {
      final (code, out, err) = await mold([
        'unpack',
        archive,
        '-t',
        target(),
        '--no-prompt',
        '--var',
        'name=my_app',
        '--diff',
        '--json',
      ]);
      final doc = jsonDecode(out) as Map<String, Object?>;

      expect(code, 0, reason: err);
      expect(doc['applied'], isFalse);
      expect(doc['values'], {'name': 'my_app', 'platform': 'android'});
      expect(doc['summary'], containsPair('renamed', 1));
      final files = (doc['files']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final renamed = files.singleWhere((f) => f['from'] != f['to']);
      expect(renamed['to'], 'lib/my_app.dart');
      expect(renamed['diff'], contains('+// android'));
      expect(Directory(target()).existsSync(), isFalse);
    });

    test('a real unpack reports what it applied', () async {
      final (code, out, _) = await mold([
        'unpack',
        archive,
        '-t',
        target(),
        '--no-prompt',
        '--var',
        'name=my_app',
        '--json',
      ]);

      expect(code, 0);
      expect((jsonDecode(out) as Map<String, Object?>)['applied'], isTrue);
      expect(File(p.join(target(), 'pubspec.yaml')).existsSync(), isTrue);
    });

    test('a failure is a JSON document of errors, exit 1', () async {
      Directory(target()).createSync();
      File(p.join(target(), 'x')).writeAsStringSync('x');

      final (code, out, _) = await mold([
        'unpack',
        archive,
        '-t',
        target(),
        '--no-prompt',
        '--var',
        'name=my_app',
        '--json',
      ]);
      final doc = jsonDecode(out) as Map<String, Object?>;

      expect(code, 1);
      expect(
        (doc['errors']! as List<Object?>).single,
        containsPair('code', MoldCode.targetOccupied),
      );
    });

    test('a usage error is a JSON document too', () async {
      final (code, out, err) = await mold([
        'unpack',
        archive,
        '--vars-file',
        p.join(tmp.path, 'missing.yaml'),
        '--json',
      ]);
      final doc = jsonDecode(out) as Map<String, Object?>;

      expect(code, 64);
      expect(err, isEmpty);
      expect(
        (doc['errors']! as List<Object?>).single,
        containsPair('code', 'CLI_USAGE'),
      );
    });

    test('warnings go into the document, not stderr', () async {
      write(project, 'mold.yaml', '''
name: super_server
version: 1
variables:
  name:
    replaces: super_server
  unused:
    default: x
''');

      final (code, out, err) = await mold([
        'pack',
        project.path,
        '-o',
        archive,
        '--json',
      ]);
      final doc = jsonDecode(out) as Map<String, Object?>;

      expect(code, 0);
      expect(err, isEmpty);
      expect(
        (doc['warnings']! as List<Object?>).single,
        containsPair('code', MoldCode.manifestUnusedVariable),
      );
    });
  });

  group('UnpackStamp', () {
    test('round-trips through its JSON', () {
      const stamp = UnpackStamp(
        template: 't',
        version: '1',
        vars: {'a': 'b'},
        files: {'x': 'h1', 'y/z': 'h2'},
      );
      final back = UnpackStamp.tryParse(stamp.toJson())!;

      expect(back.vars, stamp.vars);
      expect(back.files, stamp.files);
    });

    test('ignores JSON that is not a stamp', () {
      expect(UnpackStamp.tryParse('{"name": "x"}'), isNull);
      expect(UnpackStamp.tryParse('not json'), isNull);
    });
  });
}
