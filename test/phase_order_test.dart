import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mold/mold.dart';
import 'package:test/test.dart';

/// An archive declaring one variable that has no default, so resolving it
/// requires either `--var` or a prompt.
List<int> _archiveNeedingInput() {
  ArchiveFile entry(String name, String content) {
    final bytes = utf8.encode(content);
    return ArchiveFile(name, bytes.length, bytes);
  }

  final archive = Archive()
    ..addFile(
      entry(
        'mold.yaml',
        'name: demo\nversion: 1.0.0\n'
            'variables:\n  org:\n    replaces: super_server\n',
      ),
    )
    ..addFile(entry('files/a.txt', 'super_server'));
  return const GZipEncoder().encode(TarEncoder().encode(archive));
}

void main() {
  group('phase order', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_order_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('an occupied target fails before any prompt is issued', () {
      final occupied = Directory('${tmp.path}/out')..createSync();
      File('${occupied.path}/existing.txt').writeAsStringSync('keep me');

      var prompts = 0;
      final resolver = VariableResolver(
        prompter: VariablePrompter(StringBuffer(), () {
          prompts++;
          return 'typed';
        }),
      );

      expect(
        () => const Unbundler().unbundle(
          bytes: _archiveNeedingInput(),
          targetDir: occupied.path,
          resolver: resolver,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        prompts,
        0,
        reason: 'the user must not type answers that are then discarded',
      );
      expect(File('${occupied.path}/existing.txt').existsSync(), isTrue);
    });

    test('a missing variable is reported as VARIABLE_MISSING', () {
      expect(
        () => const Unbundler().unbundle(
          bytes: _archiveNeedingInput(),
          targetDir: '${tmp.path}/out',
          resolver: const VariableResolver(noPrompt: true),
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.errors.map((x) => x.code),
            'codes',
            contains(VariablesValidator.missing),
          ),
        ),
      );
    });
  });

  group('TargetValidator write probe', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_probe_'));
    tearDown(() {
      // Restore permissions so the temp tree can be removed. Guarded: there is
      // no chmod on Windows, and the group's other test runs there.
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['-R', 'u+w', tmp.path]);
      }
      tmp.deleteSync(recursive: true);
    });

    test(
      'an existing but read-only target is rejected, not left to crash',
      () {
        final target = Directory('${tmp.path}/out')..createSync();
        Process.runSync('chmod', ['500', target.path]);

        final result = const TargetValidator().validate(target.path);

        expect(
          result.errors.map((e) => e.code),
          contains(TargetValidator.notWritable),
          reason: 'the parent is writable; the target itself is not',
        );
      },
      testOn: '!windows',
    );

    test('an existing empty writable target is accepted', () {
      final target = Directory('${tmp.path}/ok')..createSync();
      expect(const TargetValidator().validate(target.path).isValid, isTrue);
    });
  });
}
