import 'dart:io';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

void main() {
  group('GitignoreRules', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_gi_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    void write(String rel, String content) {
      File('${tmp.path}/$rel')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    GitignoreRules load() => GitignoreRules.load(tmp.path);

    test('an unanchored rule matches at every depth, including zero', () {
      // The trap: package:glob's `**/` means one-or-more, so a naive
      // translation to `**/*.log` silently misses a root-level file.
      write('.gitignore', '*.log\n');

      final rules = load();
      expect(rules.isIgnored('a.log'), isTrue);
      expect(rules.isIgnored('sub/a.log'), isTrue);
      expect(rules.isIgnored('deep/er/a.log'), isTrue);
      expect(rules.isIgnored('a.txt'), isFalse);
    });

    test('a leading slash anchors to the root', () {
      write('.gitignore', '/build/\n');

      final rules = load();
      expect(rules.isIgnored('build/a.o'), isTrue);
      expect(rules.isIgnored('sub/build/a.o'), isFalse);
    });

    test('an interior slash anchors too', () {
      write('.gitignore', 'android/app/debug\n');

      final rules = load();
      expect(rules.isIgnored('android/app/debug'), isTrue);
      expect(rules.isIgnored('sub/android/app/debug'), isFalse);
    });

    test('a trailing slash matches the directory contents', () {
      write('.gitignore', '.idea/\n');

      final rules = load();
      expect(rules.isIgnored('.idea/workspace.xml'), isTrue);
      expect(rules.isIgnored('sub/.idea/workspace.xml'), isTrue);
      expect(rules.isIgnored('ideas/x.txt'), isFalse);
    });

    test('a bare name matches both the file and a directory of that name', () {
      write('.gitignore', 'coverage\n');

      final rules = load();
      expect(rules.isIgnored('coverage'), isTrue);
      expect(rules.isIgnored('coverage/lcov.info'), isTrue);
    });

    test('negation rescues a file an earlier rule caught', () {
      write('.gitignore', '*.pbxuser\n!default.pbxuser\n');

      final rules = load();
      expect(rules.isIgnored('x.pbxuser'), isTrue);
      expect(rules.isIgnored('default.pbxuser'), isFalse);
    });

    test('order decides: the last matching rule wins', () {
      write('.gitignore', '!keep.log\n*.log\n');

      final rules = load();
      // The negation comes first, so the later blanket rule re-ignores it.
      expect(rules.isIgnored('keep.log'), isTrue);
    });

    test('a nested .gitignore is scoped to its own directory', () {
      write('.gitignore', '# nothing here\n');
      write('ios/.gitignore', 'Flutter/ephemeral/\n');

      final rules = load();
      expect(rules.isIgnored('ios/Flutter/ephemeral/x'), isTrue);
      expect(
        rules.isIgnored('macos/Flutter/ephemeral/x'),
        isFalse,
        reason: 'the ios rule must not reach macos',
      );
    });

    test('a **/ inside a nested rule still matches at zero depth', () {
      // The bug a diff against real git caught: macOS ships
      // `**/Flutter/ephemeral/`, which scoped to `macos/` becomes
      // `macos/**/Flutter/ephemeral` — and package:glob would not match
      // `macos/Flutter/ephemeral/x`, the exact path it exists for.
      write('macos/.gitignore', '**/Flutter/ephemeral/\n');

      final rules = load();
      expect(rules.isIgnored('macos/Flutter/ephemeral/x'), isTrue);
      expect(rules.isIgnored('macos/deep/Flutter/ephemeral/x'), isTrue);
    });

    test('comments and blank lines are skipped', () {
      write('.gitignore', '\n# a comment\n\n  \n*.log\n');

      final rules = load();
      expect(rules.isIgnored('a.log'), isTrue);
      expect(rules.isIgnored('a.txt'), isFalse);
    });

    test('.git is always ignored, without being listed', () {
      write('.gitignore', '# empty\n');

      expect(load().isIgnored('.git/config'), isTrue);
    });

    test('a tree with no .gitignore ignores nothing but .git', () {
      write('a.txt', 'x');

      final rules = load();
      expect(rules.isIgnored('a.txt'), isFalse);
      expect(rules.isIgnored('.git/HEAD'), isTrue);
    });
  });

  group('use_gitignore in the manifest', () {
    late Directory tmp;
    late Directory src;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mold_giman_');
      src = Directory('${tmp.path}/src')..createSync(recursive: true);
      File('${src.path}/.gitignore').writeAsStringSync('build/\n');
      File('${src.path}/keep.txt').writeAsStringSync('super_server');
      File('${src.path}/build/derived.o')
        ..createSync(recursive: true)
        ..writeAsStringSync('junk');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('defaults to true, so a gitignored file is not packed', () {
      final m = Manifest.fromYaml('name: t\nversion: 1\n');
      expect(m.useGitignore, isTrue);

      final scan = FileScanner(useGitignore: m.useGitignore).scan(src.path);
      expect(scan.files, isNot(contains('build/derived.o')));
      expect(scan.files, contains('keep.txt'));
      expect(scan.gitignored, 1);
    });

    test('use_gitignore: false packs the project as it sits on disk', () {
      final m = Manifest.fromYaml(
        'name: t\nversion: 1\nuse_gitignore: false\n',
      );
      expect(m.useGitignore, isFalse);

      final scan = FileScanner(useGitignore: m.useGitignore).scan(src.path);
      expect(scan.files, contains('build/derived.o'));
      expect(scan.gitignored, 0);
    });

    test('round-trips through toYaml', () {
      const off = Manifest(name: 't', version: '1', useGitignore: false);
      expect(Manifest.fromYaml(off.toYaml()), equals(off));

      const on = Manifest(name: 't', version: '1');
      expect(Manifest.fromYaml(on.toYaml()), equals(on));
    });
  });
}
