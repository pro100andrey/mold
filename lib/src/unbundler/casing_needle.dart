import 'case_converter.dart';

/// One derived casing of a `replaces` token, and the rule for which adjacent
/// characters extend it into a longer word.
///
/// The rule follows the casing, because each casing has its own word
/// boundaries:
///
/// - **snake, kebab, SCREAMING** — joined by a separator, so a letter or digit
///   continues the word and anything else (`_`, `-`, `.`, `/`, …) ends it.
///   `_` ends a kebab needle too: both are segment separators, and a mixed
///   form like `my-app_test` (file names, generated identifiers) holds the
///   kebab token as a whole segment, which is what the rename should reach.
/// - **Pascal** — joined by capitals, so after the needle only a lowercase
///   letter continues it (`AppTemplateer`); a capital starts the next word
///   (`AppTemplateTest`). Before it, nothing does: the needle opens on a
///   capital, which is itself a word start in any camel or Pascal identifier
///   (`MyAppTemplate`, `HTTPAppTemplate`, `_AppTemplate`). A digit after a
///   needle that ends in a digit continues the number.
///
/// Real over-reach is still caught: `my_app` in `my_appendix`, `app` in
/// `application`, `MyApp` in `MyApplication`.
class CasingNeedle {
  const CasingNeedle(this.text, {required this.pascal});

  /// The casings of [token] substitution would rewrite, each with its rule.
  ///
  /// Claimed in `CaseConverter.replacements` order, so when two casings
  /// coincide (`app` is both snake and kebab) the needle keeps the rule of
  /// the casing the substitutor itself would credit with it.
  static List<CasingNeedle> casingsOf(String token) {
    const converter = CaseConverter();
    final pascal = converter.toPascal(token);
    final keys = converter.replacements(token, token).keys;

    return [for (final key in keys) CasingNeedle(key, pascal: key == pascal)];
  }

  /// The literal searched for.
  final String text;

  /// Whether [text] is the PascalCase form.
  final bool pascal;

  /// Whether the character [unit] just before a match extends it.
  bool continuesBefore(int unit) => !pascal && isAlnum(unit);

  /// Whether the match of [text] at [start] in [hay] is a whole word — no
  /// adjacent character extends it.
  bool isWholeAt(String hay, int start) {
    final end = start + text.length;
    final before = start > 0 && continuesBefore(hay.codeUnitAt(start - 1));
    final after = end < hay.length && continuesAfter(hay.codeUnitAt(end));

    return !before && !after;
  }

  /// Whether the character [unit] just after a match extends it.
  bool continuesAfter(int unit) {
    if (!pascal) {
      return isAlnum(unit);
    }

    return isLower(unit) ||
        (isDigit(unit) && isDigit(text.codeUnitAt(text.length - 1)));
  }

  /// An ASCII letter or digit.
  static bool isAlnum(int u) => isLower(u) || isUpper(u) || isDigit(u);

  /// An ASCII lowercase letter.
  static bool isLower(int u) => u >= 0x61 && u <= 0x7A;

  /// An ASCII uppercase letter.
  static bool isUpper(int u) => u >= 0x41 && u <= 0x5A;

  /// An ASCII digit.
  static bool isDigit(int u) => u >= 0x30 && u <= 0x39;
}
