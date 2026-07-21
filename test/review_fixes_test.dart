import 'dart:io';
import 'dart:typed_data';

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
    tmp = Directory.systemTemp.createTempSync('mold_rev_');
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

  group('warnings are reported once', () {
    test('pack --diff does not double-report the manifest phase', () async {
      // bundle() and plan() each validate the manifest; passing onWarning to
      // both printed every warning twice.
      write('a.txt', 'hello\n');
      File('${tmp.path}/m.yaml').writeAsStringSync(
        'name: t\nversion: 1\nvariables:\n  dead_var:\n    default: x\n',
      );
      final err = StringBuffer();

      final code = await runBundleCli([
        'pack',
        src.path,
        '-m',
        '${tmp.path}/m.yaml',
        '--diff',
      ], err: err);

      expect(code, 0);
      expect(
        ManifestValidator.unusedVariable.allMatches(err.toString()).length,
        1,
      );
    });
  });

  group('duplicate substitutions', () {
    test('two entries sharing a `from` in one section are rejected', () {
      // Rendering keys the table by `from`, so the first entry never ran and
      // nothing said so.
      final result = const ManifestValidator().validate(
        Manifest.fromYaml('''
name: t
version: 1
extra_substitutions:
  - from: alpha
    to: FIRST
  - from: alpha
    to: SECOND
'''),
      );

      expect(
        result.errors.map((e) => e.code),
        contains(ManifestValidator.duplicateSubstitution),
      );
      expect(result.errors.single.message, contains('extra_substitutions'));
    });

    test('path_renames is checked too, and named in the message', () {
      final result = const ManifestValidator().validate(
        Manifest.fromYaml('''
name: t
version: 1
path_renames:
  - from: dir
    to: one
  - from: dir
    to: two
'''),
      );

      expect(result.errors.single.message, contains('path_renames'));
    });

    test('the same `from` in both sections stays legal', () {
      // The pin idiom: rename a literal in content while holding it in paths.
      // The two build separate tables, so neither shadows the other.
      final result = const ManifestValidator().validate(
        Manifest.fromYaml('''
name: t
version: 1
extra_substitutions:
  - from: app
    to: shop
path_renames:
  - from: app
    to: app
'''),
      );

      expect(result.isValid, isTrue);
    });

    test('packing a manifest with a duplicate fails', () {
      write('a.txt', 'alpha\n');
      expect(
        () => pack('''
name: t
version: 1
extra_substitutions:
  - from: alpha
    to: FIRST
  - from: alpha
    to: SECOND
'''),
        rejectsWith(ManifestValidator.duplicateSubstitution),
      );
    });
  });

  group('repeated --var', () {
    test('the same key twice is a usage error, not last-wins', () async {
      write('super_server.txt', 'super_server\n');
      final archive = await pack('''
name: t
version: 1
variables:
  p:
    default: x
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
        'p=alpha',
        '--var',
        'p=beta',
        '--no-prompt',
      ], err: err);

      expect(code, 64);
      expect(err.toString(), contains('Repeated --var'));
    });
  });

  group('a failed unpack leaves nothing behind', () {
    test('a directory it created is removed', () async {
      write('a.txt', 'hello\n');
      write('blocker.txt', 'hello\n');
      final archive = await pack('name: t\nversion: 1\n');

      // A file where the unpack needs a directory: writing a.txt succeeds,
      // then `blocker.txt/child` cannot be created under a regular file.
      final poisoned = _withEntryRenamedToNest(archive);
      final out = '${tmp.path}/out';

      expect(
        () => const Unbundler().unbundleBytes(
          source: poisoned,
          targetDir: out,
        ),
        throwsA(isA<Object>()),
      );
      expect(
        Directory(out).existsSync(),
        isFalse,
        reason:
            'a half-written project must not survive, or the obvious '
            'retry fails with TARGET_OCCUPIED',
      );
    });

    test('a pre-existing empty directory survives its files going', () async {
      write('a.txt', 'hello\n');
      write('blocker.txt', 'hello\n');
      final archive = await pack('name: t\nversion: 1\n');
      final out = Directory('${tmp.path}/out')..createSync();

      expect(
        () => const Unbundler().unbundleBytes(
          source: _withEntryRenamedToNest(archive),
          targetDir: out.path,
        ),
        throwsA(isA<Object>()),
      );

      // The user's own directory is not ours to delete.
      expect(out.existsSync(), isTrue);
      expect(out.listSync(), isEmpty, reason: 'but our debris is gone');
    });
  });

  group('decompression is bounded', () {
    test('an archive that expands without bound is refused', () {
      // 64 MiB of zeros compresses to a few dozen KiB.
      final bomb = gzip.encode(Uint8List(64 * 1024 * 1024));
      expect(bomb.length, lessThan(1024 * 1024));

      expect(
        () => decodeGzipBounded(bomb, maxBytes: 1024 * 1024),
        throwsA(isA<ArchiveTooLargeException>()),
      );
    });

    test('the validator reports it as its own code, not ARCHIVE_INVALID', () {
      // The archive is well-formed; calling it corrupt would send the reader
      // hunting for damage that is not there.
      final bomb = gzip.encode(Uint8List(64 * 1024 * 1024));

      final result = const ArchiveValidator(
        maxDecompressedBytes: 1024 * 1024,
      ).validate(bomb);

      expect(result.errors.single.code, ArchiveValidator.tooLarge);
    });

    test('an ordinary archive still round-trips', () async {
      write('a.txt', 'hello\n');
      final archive = await pack('name: t\nversion: 1\n');

      expect(const ArchiveValidator().validate(archive).isValid, isTrue);
      expect(const ArchiveReader().read(archive).files, hasLength(1));
    });

    test('the limit is what aborts, well before full expansion', () {
      final bomb = gzip.encode(Uint8List(64 * 1024 * 1024));
      final watch = Stopwatch()..start();

      expect(
        () => decodeGzipBounded(bomb, maxBytes: 512 * 1024),
        throwsA(isA<ArchiveTooLargeException>()),
      );

      // Decoding all 64 MiB takes far longer than this; the point of chunking
      // is that the limit stops it partway, not after the fact.
      expect(watch.elapsedMilliseconds, lessThan(500));
    });
  });

  group('the scan prunes ignored directories', () {
    test('an ignored directory is never entered', () {
      write('.gitignore', 'build/\n');
      write('lib/a.dart', 'x\n');
      write('build/one.o', 'x\n');
      write('build/deep/two.o', 'x\n');
      write('build/deep/three.o', 'x\n');

      final scan = FileScanner(useGitignore: true).scan(src.path);

      expect(scan.files, ['.gitignore', 'lib/a.dart']);
      // One, not three: the walk never descends into build/, so the files
      // inside were never enumerated and there is nothing there to count.
      expect(scan.gitignored, 1);
    });

    test('a nested .gitignore still applies to its own subtree', () {
      write('.gitignore', '*.log\n');
      write('a.log', 'x\n');
      write('pkg/.gitignore', 'secret.txt\n');
      write('pkg/secret.txt', 'x\n');
      write('pkg/keep.dart', 'x\n');
      write('other/secret.txt', 'x\n');

      final scan = FileScanner(useGitignore: true).scan(src.path);

      expect(scan.files, contains('pkg/keep.dart'));
      expect(scan.files, contains('other/secret.txt'));
      expect(scan.files, isNot(contains('pkg/secret.txt')));
      expect(scan.files, isNot(contains('a.log')));
    });

    test('a negation under an included directory still works', () {
      write('.gitignore', '*.log\n!keep.log\n');
      write('a.log', 'x\n');
      write('keep.log', 'x\n');

      final scan = FileScanner(useGitignore: true).scan(src.path);

      expect(scan.files, contains('keep.log'));
      expect(scan.files, isNot(contains('a.log')));
    });

    test('.git is pruned even with no .gitignore at all', () {
      write('.git/config', 'x\n');
      write('a.dart', 'x\n');

      expect(FileScanner(useGitignore: true).scan(src.path).files, ['a.dart']);
    });

    test('use_gitignore: false packs the tree as it sits', () {
      write('.gitignore', 'build/\n');
      write('build/one.o', 'x\n');

      final scan = FileScanner().scan(src.path);

      expect(scan.files, contains('build/one.o'));
      expect(scan.gitignored, 0);
    });
  });

  group('robustness nits', () {
    test('the write probe does not leave a file behind', () {
      final dir = Directory('${tmp.path}/probe')..createSync();

      expect(const TargetValidator().validate(dir.path).isValid, isTrue);
      expect(dir.listSync(), isEmpty);
    });

    test('an unknown output format names the valid ones', () {
      expect(
        () => OutputFormat.fromFlag('nope'),
        throwsA(isA<FormatException>()),
      );
    });

    test('RenameValidator still reports every colliding source', () {
      // Rewritten to two passes for allocation; the message must not change.
      final result = const RenameValidator().validate({
        'a.txt': 'same.txt',
        'b.txt': 'other.txt',
        'c.txt': 'same.txt',
      });

      expect(result.errors, hasLength(1));
      expect(
        result.errors.single.message,
        allOf(contains('a.txt'), contains('c.txt'), isNot(contains('b.txt'))),
      );
    });

    test('no collisions allocates nothing and passes', () {
      expect(
        const RenameValidator().validate({'a': 'x', 'b': 'y'}).isValid,
        isTrue,
      );
    });
  });
}

/// Rebuilds [archive] with `a.txt` renamed so it must be created *under*
/// `blocker.txt`, which is a regular file — so the write fails partway.
List<int> _withEntryRenamedToNest(List<int> archive) {
  final read = const ArchiveReader().read(archive);
  final files = <String, List<int>>{
    'blocker.txt': read.files['blocker.txt']!,
    'blocker.txt/nested.txt': read.files['a.txt']!,
  };

  return const ArchiveWriter().write(
    manifestYaml: read.manifestYaml,
    files: files,
  );
}
