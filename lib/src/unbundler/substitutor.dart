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

    return RegExp(sorted.map(_escape).join('|'));
  }
}
