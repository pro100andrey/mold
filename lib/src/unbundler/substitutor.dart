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

  static final _special = RegExp(r'[\\^$.|?*+()[\]{}]');

  static String _escape(String s) =>
      s.replaceAllMapped(_special, (m) => '\\${m[0]}');

  /// Builds the alternation pattern, longest token first. Returns null when
  /// there is nothing to replace.
  static RegExp? _build(Map<String, String> replacements) {
    final keys = replacements.keys.where((k) => k.isNotEmpty).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (keys.isEmpty) {
      return null;
    }

    return RegExp(keys.map(_escape).join('|'));
  }
}
