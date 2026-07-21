import 'package:mold/mold.dart';
import 'package:test/test.dart';

void main() {
  const diff = UnifiedDiff();

  /// Number of hunk headers — counting '@@' occurrences would double-count,
  /// since each header both opens and closes with it.
  int hunkCount(String out) =>
      out.split('\n').where((l) => l.startsWith('@@')).length;

  String render(String before, String after) => diff.render(
    before: before,
    after: after,
    fromLabel: 'a.txt',
    toLabel: 'a.txt',
  );

  group('UnifiedDiff', () {
    test('identical input produces nothing', () {
      expect(render('same\ntext\n', 'same\ntext\n'), isEmpty);
    });

    test('a one-line change shows the pair with context', () {
      final out = render(
        'one\ntwo\nthree\nfour\nfive\n',
        'one\ntwo\nCHANGED\nfour\nfive\n',
      );

      expect(out, contains('--- a.txt'));
      expect(out, contains('+++ a.txt'));
      expect(out, contains('-three'));
      expect(out, contains('+CHANGED'));
      expect(out, contains(' two'), reason: 'context line');
      expect(out, contains(' four'), reason: 'context line');
    });

    test('added lines are additions, not a rewrite of the whole file', () {
      final out = render('a\nb\n', 'a\nNEW\nb\n');

      expect(out, contains('+NEW'));
      expect(out, isNot(contains('-a')));
      expect(out, isNot(contains('-b')));
    });

    test('removed lines are removals', () {
      final out = render('a\nGONE\nb\n', 'a\nb\n');

      expect(out, contains('-GONE'));
      expect(out, isNot(contains('+a')));
    });

    test('distant changes become separate hunks', () {
      final before = ['x', ...List.filled(20, 'pad'), 'y'].join('\n');
      final after = ['X', ...List.filled(20, 'pad'), 'Y'].join('\n');
      final out = render(before, after);

      expect(hunkCount(out), 2);
    });

    test('adjacent changes merge into one hunk', () {
      final out = render('a\nb\nc\n', 'A\nB\nc\n');

      expect(hunkCount(out), 1);
    });

    test('hunk headers carry line numbers and counts', () {
      final out = render('a\nb\nc\n', 'a\nB\nc\n');

      expect(out, matches(RegExp(r'@@ -\d+,\d+ \+\d+,\d+ @@')));
    });

    test('an empty original is all additions', () {
      final out = render('', 'a\nb\n');

      expect(out, contains('+a'));
      expect(out, contains('+b'));
    });

    test('a rewrite larger than maxWindow degrades to a block replace', () {
      const small = UnifiedDiff(maxWindow: 2);
      final out = small.render(
        before: 'a\nb\nc\nd\n',
        after: 'w\nx\ny\nz\n',
        fromLabel: 'f',
        toLabel: 'f',
      );

      // Every old line removed, every new line added — bounded, still correct.
      expect(out, contains('-a'));
      expect(out, contains('+w'));
    });

    test('labels distinguish a renamed file', () {
      final out = diff.render(
        before: 'super_server\n',
        after: 'my_project\n',
        fromLabel: 'lib/super_server.dart',
        toLabel: 'lib/my_project.dart',
      );

      expect(out, contains('--- lib/super_server.dart'));
      expect(out, contains('+++ lib/my_project.dart'));
    });
  });
}
