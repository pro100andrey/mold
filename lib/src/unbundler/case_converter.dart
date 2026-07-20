/// Derives the four canonical casings from a single token and builds the
/// replacement table that maps each casing of a `replaces` token to the
/// matching casing of a target value.
///
/// Tokens are first split into lowercase words, handling `snake_case`,
/// `kebab-case`, `SCREAMING_SNAKE`, `camelCase`, `PascalCase`, and acronym runs
/// (`HTTPServer` → `http`, `server`).
class CaseConverter {
  const CaseConverter();

  /// Matches one word: an acronym run before a Capitalized word, a
  /// lower/Capitalized word, an all-caps run, or a digit run. Separators
  /// (`_`, `-`, spaces) fall between matches and are skipped.
  static final _word = RegExp(
    '[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z0-9]+|[A-Z]+|[0-9]+',
  );

  /// Splits [token] into its lowercase constituent words.
  List<String> splitWords(String token) =>
      _word.allMatches(token).map((m) => m[0]!.toLowerCase()).toList();

  /// `snake_case`
  String toSnake(String token) => splitWords(token).join('_');

  /// `kebab-case`
  String toKebab(String token) => splitWords(token).join('-');

  /// `SCREAMING_SNAKE`
  String toScreamingSnake(String token) =>
      splitWords(token).map((w) => w.toUpperCase()).join('_');

  /// `PascalCase`
  String toPascal(String token) => splitWords(token).map(_capitalize).join();

  /// Builds the replacement table mapping each of the four casings of [from] to
  /// the matching casing of [to]. Empty keys (degenerate tokens) are dropped.
  Map<String, String> replacements(String from, String to) {
    final table = <String, String>{
      toSnake(from): toSnake(to),
      toKebab(from): toKebab(to),
      toScreamingSnake(from): toScreamingSnake(to),
      toPascal(from): toPascal(to),
    }..removeWhere((k, _) => k.isEmpty);
    
    return table;
  }

  String _capitalize(String word) =>
      word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);
}
