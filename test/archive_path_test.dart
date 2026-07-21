import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mold/mold.dart';
import 'package:test/test.dart';

ArchiveFile _entry(String name, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

List<int> _archiveWith(List<String> filePaths) {
  final archive = Archive()
    ..addFile(_entry('mold.yaml', 'name: evil\nversion: 1.0.0\n'));
  for (final path in filePaths) {
    archive.addFile(_entry('files/$path', 'payload'));
  }
  return const GZipEncoder().encode(TarEncoder().encode(archive));
}

void main() {
  group('isContainedArchivePath', () {
    test('accepts ordinary relative paths', () {
      expect(isContainedArchivePath('a.txt'), isTrue);
      expect(isContainedArchivePath('lib/src/a.dart'), isTrue);
      expect(isContainedArchivePath('a/../b.txt'), isTrue, reason: 'stays in');
      expect(isContainedArchivePath('./a.txt'), isTrue);
    });

    test('rejects traversal out of the tree', () {
      expect(isContainedArchivePath('../a.txt'), isFalse);
      expect(isContainedArchivePath('a/../../b.txt'), isFalse);
      expect(isContainedArchivePath('..'), isFalse);
    });

    test('rejects absolute and drive-qualified paths', () {
      expect(isContainedArchivePath('/etc/passwd'), isFalse);
      expect(isContainedArchivePath(r'C:\Windows\system32'), isFalse);
      // Forward slashes, so the backslash guard does not fire first and the
      // windows-absolute check is the thing actually under test.
      expect(isContainedArchivePath('C:/Windows/system32'), isFalse);
    });

    test('accepts a drive-relative name, which cannot escape', () {
      // `C:notes.txt` has no separator after the colon, so p.join keeps it
      // under the target (C:\target\C:notes.txt) rather than rooting it.
      expect(isContainedArchivePath('C:notes.txt'), isTrue);
    });

    test('rejects backslashes, which separate on Windows', () {
      expect(isContainedArchivePath(r'a\..\..\b.txt'), isFalse);
    });

    test('rejects the empty path', () {
      expect(isContainedArchivePath(''), isFalse);
    });
  });

  group('unpack rejects escaping archives', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_slip_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a `..` entry is refused and nothing is written outside', () {
      final victim = Directory('${tmp.path}/victim')
        ..createSync(recursive: true);
      final bytes = _archiveWith(['ok.txt', '../ESCAPED.txt']);

      expect(
        () => const Unbundler().unbundle(
          bytes: bytes,
          targetDir: '${victim.path}/out',
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(File('${victim.path}/ESCAPED.txt').existsSync(), isFalse);
    });

    test('a deep `..` entry is refused', () {
      final victim = Directory('${tmp.path}/victim')
        ..createSync(recursive: true);
      final bytes = _archiveWith(['sub/../../SNEAK.txt']);

      expect(
        () => const Unbundler().unbundle(
          bytes: bytes,
          targetDir: '${victim.path}/out',
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(File('${victim.path}/SNEAK.txt').existsSync(), isFalse);
    });

    test('the validator reports ARCHIVE_UNSAFE_PATH', () {
      final result = const ArchiveValidator().validate(
        _archiveWith(['ok.txt', '../ESCAPED.txt']),
      );
      expect(result.isValid, isFalse);
      expect(
        result.errors.map((e) => e.code),
        contains(ArchiveValidator.unsafePath),
      );
    });

    test('a well-formed archive still unpacks', () async {
      final bytes = _archiveWith(['ok.txt', 'sub/deep.txt']);
      await const Unbundler().unbundle(
        bytes: bytes,
        targetDir: '${tmp.path}/out',
      );
      expect(File('${tmp.path}/out/ok.txt').readAsStringSync(), 'payload');
      expect(File('${tmp.path}/out/sub/deep.txt').existsSync(), isTrue);
    });
  });
}
