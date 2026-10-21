/// Applies a fixed replacement table to strings (file paths and text content)
/// in a single left-to-right pass.
///
/// All `from` tokens are matched simultaneously via one alternation, so a value
/// substituted in cannot itself be re-substituted (no cascading). Longer tokens
/// are tried first, so an overlapping shorter token never pre-empts a longer
/// match at the same position.
class Substitutor {
  Substitutor(Map<String, String> replacements)
    : _table = Map.of(replacements)..removeWhere((k, _) => k.isEmpty),
      _pattern = _build(replacements);

  final Map<String, String> _table;

  /// The literals this substitutor rewrites.
  Iterable<String> get keys => _table.keys;
  final RegExp? _pattern;

  /// Rewrites [input], replacing every occurrence of any `from` token with its
  /// mapped value. Returns [input] unchanged when the table is empty.
  String apply(String input) {
    final pattern = _pattern;
    if (pattern == null) {
      return input;
    }

    return input.replaceAllMapped(pattern, (m) => _table[m[0]!]!);
  }

  /// [apply] and [count] in one pass: the rewritten text and how many
  /// replacements it took.
  ///
  /// A preview needs both, and two passes ran the pattern over every text
  /// file twice.
  (String, int) applyCounted(String input) {
    final pattern = _pattern;
    if (pattern == null) {
      return (input, 0);
    }

    var count = 0;
    final out = input.replaceAllMapped(pattern, (m) {
      count++;
      return _table[m[0]!]!;
    });

    return (out, count);
  }

  /// This substitutor, also reporting where any of [watched] occurs in the
  /// text it rewrites — in the same pass. See [Watching].
  Watching watching(Iterable<String> watched) => Watching._(this, watched);

  /// How many replacements [apply] would make in [input].
  ///
  /// Counted from the same pattern [apply] uses, so a preview reports exactly
  /// what a rewrite performs.
  int count(String input) {
    final pattern = _pattern;

    return pattern == null ? 0 : pattern.allMatches(input).length;
  }

  static final _special = RegExp(r'[\\^$.|?*+()[\]{}]');

  static String _escape(String s) =>
      s.replaceAllMapped(_special, (m) => '\\${m[0]}');

  static RegExp? _build(Map<String, String> replacements) =>
      alternation(replacements.keys);

  /// The pattern matching any of [keys] the way [apply] does: one
  /// alternation, longest key first, so a shorter key never pre-empts a longer
  /// one at the same position. Null when there is nothing to match.
  ///
  /// Public so a measurement of what substitution would do — the pack-time
  /// token check — can match with substitution's own pattern rather than an
  /// approximation of it.
  static RegExp? alternation(Iterable<String> keys) {
    final sorted = keys.where((k) => k.isNotEmpty).toSet().toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (sorted.isEmpty) {
      return null;
    }

    return RegExp(
      '${firstCharGuard(sorted)}(?:${sorted.map(_escape).join('|')})',
    );
  }

  /// A lookahead admitting only the characters [keys] can start with, to put
  /// in front of their alternation.
  ///
  /// It changes no match — every key starts with one of them — but it lets
  /// the regex engine skip a position on one class test instead of trying
  /// every alternative there. On a 48 MB corpus: 127 → 78 ms for one token's
  /// four casings, 248 → 98 ms for eight literals.
  static String firstCharGuard(Iterable<String> keys) {
    final firsts = {for (final k in keys) k[0]};
    final escaped = firsts.map(
      (c) => const {r'\', ']', '^', '-'}.contains(c) ? '\\$c' : c,
    );

    return '(?=[${escaped.join()}])';
  }
}

/// A [Substitutor] that also reports where other literals occur in the text it
/// rewrites, outside the sites it substitutes.
///
/// One scan instead of two. The watched literals join the substitution keys in
/// one alternation, so finding them costs nothing extra; what keeps the
/// rewrite identical to [Substitutor.applyCounted] is that a watched match is
/// never allowed to hide a key. Where the alternation picks a watched literal
/// at a position, the keys are tried at that same position first — a key
/// found there is substituted as the plain substitutor would — and otherwise
/// the scan resumes one character later, so a key starting inside the watched
/// literal is still found.
class Watching {
  Watching._(this._substitutor, Iterable<String> watched)
    : _watched = watched
          .where((w) => w.isNotEmpty && !_substitutor._table.containsKey(w))
          .toSet() {
    _combined = Substitutor.alternation({
      ..._substitutor._table.keys,
      ..._watched,
    });
  }

  final Substitutor _substitutor;
  final Set<String> _watched;
  late final RegExp? _combined;

  /// [Substitutor.applyCounted], calling [onWatched] with each watched
  /// literal met in [input] and where it starts.
  (String, int) applyCounted(
    String input,
    void Function(String text, int start) onWatched,
  ) {
    final combined = _combined;
    if (_watched.isEmpty || combined == null) {
      return _substitutor.applyCounted(input);
    }

    final keys = _substitutor._pattern;
    final table = _substitutor._table;
    final out = StringBuffer();
    var count = 0;
    var copied = 0;
    var from = 0;
    while (from < input.length) {
      final m = combined.allMatches(input, from).firstOrNull;
      if (m == null) {
        break;
      }
      final text = m[0]!;
      final key = table.containsKey(text)
          ? text
          : keys?.matchAsPrefix(input, m.start)?[0];
      if (key == null) {
        // Only where nothing is substituted: a watched literal a key covers
        // is rewritten, not met.
        onWatched(text, m.start);
        from = m.start + 1;
        continue;
      }

      out
        ..write(input.substring(copied, m.start))
        ..write(table[key]);
      count++;
      copied = from = m.start + key.length;
    }

    if (count == 0) {
      return (input, 0);
    }
    out.write(input.substring(copied));

    return (out.toString(), count);
  }
}
