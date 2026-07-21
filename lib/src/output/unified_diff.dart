import 'dart:math';
import 'dart:typed_data';

/// Renders a unified diff between two versions of a text file.
///
/// Hand-rolled rather than pulled from a package: this is the only diff in the
/// tool, the algorithm is small and well understood, and a dependency for one
/// CLI flag is a poor trade in a package that has five.
class UnifiedDiff {
  const UnifiedDiff({this.context = 3, this.maxWindow = 2000});

  /// Unchanged lines shown around each change.
  final int context;

  /// Largest changed region the quadratic LCS will run on.
  ///
  /// Substitution usually rewrites a handful of lines, so trimming the common
  /// prefix and suffix leaves a tiny window. When it does not — a generated
  /// file rewritten end to end — the diff degrades to a plain
  /// remove-everything/add-everything block rather than growing without
  /// bound.
  ///
  /// The table is a flat [Int32List] — one allocation of 4 bytes per cell
  /// rather than n separate lists. Measured in isolation at this window: 16 MB
  /// for `List<List<int>>` against nothing detectable for the typed array.
  /// Modest, but it makes the bound an actual bound.
  final int maxWindow;

  /// The diff of [before] to [after], or an empty string when they are equal.
  ///
  /// [fromLabel] and [toLabel] head the `---` / `+++` lines; pass the old and
  /// new path so a rename shows up in the diff itself.
  String render({
    required String before,
    required String after,
    required String fromLabel,
    required String toLabel,
  }) {
    if (before == after) {
      return '';
    }

    final a = _lines(before);
    final b = _lines(after);
    final edits = _diff(a, b);
    final hunks = _hunks(edits);
    if (hunks.isEmpty) {
      return '';
    }

    final out = StringBuffer()
      ..writeln('--- $fromLabel')
      ..writeln('+++ $toLabel');
    for (final hunk in hunks) {
      out.writeln(hunk.header);
      for (final edit in hunk.edits) {
        out.writeln('${edit.sign}${edit.text}');
      }
    }

    return out.toString();
  }

  /// Splits [text] into lines, treating a trailing newline as a *terminator*
  /// rather than a separator.
  ///
  /// A plain `split('\n')` on the usual newline-terminated file yields a
  /// phantom empty last element, which every hunk touching the end of a file
  /// then renders as a stray blank context row.
  static List<String> _lines(String text) {
    if (text.isEmpty) {
      return const [];
    }

    final lines = text.split('\n');
    if (lines.last.isEmpty) {
      lines.removeLast();
    }

    return lines;
  }

  /// Line-level edit script, common prefix and suffix trimmed first.
  List<_Edit> _diff(List<String> a, List<String> b) {
    var head = 0;
    while (head < a.length && head < b.length && a[head] == b[head]) {
      head++;
    }

    var tail = 0;
    while (tail < a.length - head &&
        tail < b.length - head &&
        a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
      tail++;
    }

    final midA = a.sublist(head, a.length - tail);
    final midB = b.sublist(head, b.length - tail);

    return [
      for (var i = 0; i < head; i++) _Edit(_Op.keep, a[i]),
      ..._diffMiddle(midA, midB),
      for (var i = a.length - tail; i < a.length; i++) _Edit(_Op.keep, a[i]),
    ];
  }

  List<_Edit> _diffMiddle(List<String> a, List<String> b) {
    if (a.isEmpty && b.isEmpty) {
      return const [];
    }

    if (a.isEmpty) {
      return [for (final line in b) _Edit(_Op.add, line)];
    }

    if (b.isEmpty) {
      return [for (final line in a) _Edit(_Op.remove, line)];
    }

    if (a.length > maxWindow || b.length > maxWindow) {
      return [
        for (final line in a) _Edit(_Op.remove, line),
        for (final line in b) _Edit(_Op.add, line),
      ];
    }

    // Classic LCS table over the trimmed window, flat and typed.
    final width = b.length + 1;
    final lcs = Int32List((a.length + 1) * width);
    int at(int i, int j) => lcs[i * width + j];
    for (var i = a.length - 1; i >= 0; i--) {
      for (var j = b.length - 1; j >= 0; j--) {
        lcs[i * width + j] = a[i] == b[j]
            ? at(i + 1, j + 1) + 1
            : max(at(i + 1, j), at(i, j + 1));
      }
    }

    final edits = <_Edit>[];
    var i = 0;
    var j = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        edits.add(_Edit(_Op.keep, a[i]));
        i++;
        j++;
      } else if (at(i + 1, j) >= at(i, j + 1)) {
        edits.add(_Edit(_Op.remove, a[i]));
        i++;
      } else {
        edits.add(_Edit(_Op.add, b[j]));
        j++;
      }
    }

    while (i < a.length) {
      edits.add(_Edit(_Op.remove, a[i++]));
    }

    while (j < b.length) {
      edits.add(_Edit(_Op.add, b[j++]));
    }

    return edits;
  }

  /// Groups the edit script into hunks, each padded with [context] lines.
  List<_Hunk> _hunks(List<_Edit> edits) {
    final interesting = <int>[
      for (var i = 0; i < edits.length; i++)
        if (edits[i].op != _Op.keep) i,
    ];
    if (interesting.isEmpty) {
      return const [];
    }

    final hunks = <_Hunk>[];
    var start = max(0, interesting.first - context);
    var end = min(edits.length, interesting.first + context + 1);
    for (final index in interesting.skip(1)) {
      if (index - context <= end) {
        end = min(edits.length, index + context + 1);
        continue;
      }

      hunks.add(_hunk(edits, start, end));
      start = max(0, index - context);
      end = min(edits.length, index + context + 1);
    }

    hunks.add(_hunk(edits, start, end));

    return hunks;
  }

  _Hunk _hunk(List<_Edit> edits, int start, int end) {
    var oldStart = 1;
    var newStart = 1;
    for (var i = 0; i < start; i++) {
      if (edits[i].op != _Op.add) {
        oldStart++;
      }

      if (edits[i].op != _Op.remove) {
        newStart++;
      }
    }

    final slice = edits.sublist(start, end);
    final oldCount = slice.where((e) => e.op != _Op.add).length;
    final newCount = slice.where((e) => e.op != _Op.remove).length;

    // An empty range is `-0,0` in unified diff, not `-1,0`; `git apply` and
    // `patch` reject or misplace a hunk that claims to start at line 1 while
    // covering no lines.
    final oldAt = oldCount == 0 ? 0 : oldStart;
    final newAt = newCount == 0 ? 0 : newStart;

    return _Hunk('@@ -$oldAt,$oldCount +$newAt,$newCount @@', slice);
  }
}

enum _Op { keep, add, remove }

class _Edit {
  const _Edit(this.op, this.text);

  final _Op op;
  final String text;

  String get sign => switch (op) {
    _Op.keep => ' ',
    _Op.add => '+',
    _Op.remove => '-',
  };
}

class _Hunk {
  const _Hunk(this.header, this.edits);

  final String header;
  final List<_Edit> edits;
}
