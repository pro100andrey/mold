import 'dart:io';

import 'package:mold/mold.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('mold pack/unpack CLI', () {
    late Directory tmp;
    late Directory project;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mold_cli_');
      project = Directory(p.join(tmp.path, 'super_server'))
        ..createSync(recursive: true);
      File(
        p.join(project.path, 'main.dart'),
      ).writeAsStringSync('void main() {}\n');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    void writeManifest() => File(
      p.join(project.path, 'mold.yaml'),
    ).writeAsStringSync('name: super_server\nversion: 1.0.0\n');

    test('pack resolves the default <dir>/mold.yaml manifest', () async {
      writeManifest();
      final out = p.join(tmp.path, 'out.mold');
      final code = await runBundleCli(['pack', project.path, '-o', out]);
      expect(code, 0);
      expect(File(out).existsSync(), isTrue);
    });

    test('pack with missing manifest and no -m errors with code 64', () async {
      final err = _Sink();
      final code = await runBundleCli(['pack', project.path], err: err);
      expect(code, 64);
      expect(err.text, contains('No manifest'));
    });

    test('pack then unpack round-trips through the CLI', () async {
      writeManifest();
      final archive = p.join(tmp.path, 'out.mold');
      expect(await runBundleCli(['pack', project.path, '-o', archive]), 0);

      final target = p.join(tmp.path, 'extracted');
      expect(await runBundleCli(['unpack', archive, '-t', target]), 0);

      expect(
        File(p.join(target, 'main.dart')).readAsStringSync(),
        'void main() {}\n',
      );
    });

    test('pack with no source dir errors with code 64', () async {
      final err = _Sink();
      expect(await runBundleCli(['pack'], err: err), 64);
      expect(err.text, contains('Missing'));
    });

    test('an unknown command is a usage error (code 64)', () async {
      final err = _Sink();
      expect(await runBundleCli(['frobnicate'], err: err), 64);
      expect(err.text, contains('Could not find a command'));
    });

    test('an IO failure exits 1, not with a stack trace', () async {
      writeManifest();
      // The output's parent is an existing *file*, so createSync throws a
      // FileSystemException. Portable: no chmod, no platform guard.
      final blocker = File(p.join(tmp.path, 'blocker'))..writeAsStringSync('');
      final err = _Sink();

      final code = await runBundleCli([
        'pack',
        project.path,
        '-o',
        p.join(blocker.path, 'out.mold'),
      ], err: err);

      expect(code, 1);
      expect(err.text, isNotEmpty);
    });

    test('unpack --var feeds substitution through the CLI', () async {
      File(p.join(project.path, 'mold.yaml')).writeAsStringSync('''
name: super_server
version: 1.0.0
variables:
  project_name:
    default: fallback
    replaces: super_server
''');
      File(
        p.join(project.path, 'main.dart'),
      ).writeAsStringSync('// super_server\n');

      final archive = p.join(tmp.path, 'out.mold');
      expect(await runBundleCli(['pack', project.path, '-o', archive]), 0);

      final target = p.join(tmp.path, 'extracted');
      expect(
        await runBundleCli([
          'unpack',
          archive,
          '-t',
          target,
          '--var',
          'project_name=my_project',
        ]),
        0,
      );
      expect(
        File(p.join(target, 'main.dart')).readAsStringSync(),
        '// my_project\n',
      );
    });

    test('pack -f bytes emits a Dart source with the no-edit header', () async {
      writeManifest();
      final out = p.join(tmp.path, 'tpl.dart');
      expect(
        await runBundleCli(['pack', project.path, '-o', out, '-f', 'bytes']),
        0,
      );
      final src = File(out).readAsStringSync();
      expect(src, contains('AUTO-GENERATED — DO NOT EDIT'));
      expect(src, contains('const List<int> kSuperServerTemplate = <int>['));
    });

    test('pack -f bytes names the const after -n, not the manifest', () async {
      writeManifest();
      final out = p.join(tmp.path, 'foo.dart');
      expect(
        await runBundleCli([
          'pack',
          project.path,
          '-o',
          out,
          '-n',
          'foo',
          '-f',
          'bytes',
        ]),
        0,
      );
      final src = File(out).readAsStringSync();
      expect(src, contains('const List<int> kFooTemplate = <int>['));
      expect(src, isNot(contains('kSuperServerTemplate')));
    });

    test('pack -f bytes defaults the output extension to .dart', () async {
      writeManifest();
      // No -o: default path is ./<name>.dart, written into cwd. Run in a temp
      // cwd via an explicit -o to keep the test hermetic, asserting the stem.
      final out = p.join(tmp.path, 'super_server.dart');
      expect(
        await runBundleCli(['pack', project.path, '-o', out, '-f', 'base64']),
        0,
      );
      expect(
        File(out).readAsStringSync(),
        contains('const String kSuperServerTemplateBase64 ='),
      );
    });

    test('unpack --no-prompt uses manifest defaults', () async {
      File(p.join(project.path, 'mold.yaml')).writeAsStringSync('''
name: super_server
version: 1.0.0
variables:
  project_name:
    default: my_project
    replaces: super_server
''');
      File(
        p.join(project.path, 'main.dart'),
      ).writeAsStringSync('// super_server\n');

      final archive = p.join(tmp.path, 'out.mold');
      expect(await runBundleCli(['pack', project.path, '-o', archive]), 0);

      final target = p.join(tmp.path, 'extracted');
      expect(
        await runBundleCli(['unpack', archive, '-t', target, '--no-prompt']),
        0,
      );
      expect(
        File(p.join(target, 'main.dart')).readAsStringSync(),
        '// my_project\n',
      );
    });

    test('unpack --no-prompt with a required default-less var fails', () async {
      File(p.join(project.path, 'mold.yaml')).writeAsStringSync('''
name: super_server
version: 1.0.0
variables:
  org:
    description: Org id
    replaces: super_server
''');
      // Real content: the manifest no longer vouches for its own token, so
      // the project must actually contain it.
      File(
        p.join(project.path, 'main.dart'),
      ).writeAsStringSync('// super_server\n');

      final archive = p.join(tmp.path, 'out.mold');
      expect(await runBundleCli(['pack', project.path, '-o', archive]), 0);

      final err = _Sink();
      final code = await runBundleCli(
        ['unpack', archive, '-t', p.join(tmp.path, 'x'), '--no-prompt'],
        err: err,
      );
      expect(code, 1);
      expect(err.text, contains('org'));
    });

    test('unpack --dry-run reports the plan and writes nothing', () async {
      File(p.join(project.path, 'mold.yaml')).writeAsStringSync('''
name: super_server
version: 1.0.0
variables:
  project_name:
    default: my_project
    replaces: super_server
''');
      File(
        p.join(project.path, 'main.dart'),
      ).writeAsStringSync('// super_server\n');

      final archive = p.join(tmp.path, 'out.mold');
      expect(await runBundleCli(['pack', project.path, '-o', archive]), 0);

      final target = p.join(tmp.path, 'never_created');
      final err = _Sink();
      final code = await runBundleCli([
        'unpack',
        archive,
        '-t',
        target,
        '--var',
        'project_name=my_project',
        '--no-prompt',
        '--dry-run',
      ], err: err);

      expect(code, 0);
      expect(err.text, contains('Dry run'));
      expect(err.text, contains('main.dart'));
      expect(
        Directory(target).existsSync(),
        isFalse,
        reason: 'a dry run must not create the target',
      );
    });

    test('unpack --diff shows the content change', () async {
      File(p.join(project.path, 'mold.yaml')).writeAsStringSync('''
name: super_server
version: 1.0.0
variables:
  project_name:
    default: my_project
    replaces: super_server
''');
      File(
        p.join(project.path, 'main.dart'),
      ).writeAsStringSync('// super_server\n');

      final archive = p.join(tmp.path, 'out.mold');
      expect(await runBundleCli(['pack', project.path, '-o', archive]), 0);

      final err = _Sink();
      final code = await runBundleCli([
        'unpack',
        archive,
        '-t',
        p.join(tmp.path, 'nope'),
        '--var',
        'project_name=my_project',
        '--no-prompt',
        '--diff',
      ], err: err);

      expect(code, 0);
      // --diff implies --dry-run, so the plan is printed too.
      expect(err.text, contains('Dry run'));
      expect(err.text, contains('-// super_server'));
      expect(err.text, contains('+// my_project'));
    });

    test('pack --dry-run lists the capture and writes no archive', () async {
      writeManifest();
      final out = p.join(tmp.path, 'never.mold');
      final err = _Sink();

      final code = await runBundleCli([
        'pack',
        project.path,
        '-o',
        out,
        '--dry-run',
      ], err: err);

      expect(code, 0);
      expect(err.text, contains('Dry run'));
      expect(err.text, contains('main.dart'));
      expect(File(out).existsSync(), isFalse);
    });

    test('unpack with a malformed --var errors with code 64', () async {
      final archive = p.join(tmp.path, 'out.mold');
      writeManifest();
      expect(await runBundleCli(['pack', project.path, '-o', archive]), 0);

      final err = _Sink();
      final code = await runBundleCli(
        ['unpack', archive, '-t', p.join(tmp.path, 'x'), '--var', 'novalue'],
        err: err,
      );
      expect(code, 64);
      expect(err.text, contains('Invalid --var'));
    });
  });
}

/// A tiny [StringSink] that accumulates written text for assertions.
class _Sink implements StringSink {
  final _buffer = StringBuffer();
  String get text => _buffer.toString();

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void noSuchMethod(Invocation invocation) {}
}
