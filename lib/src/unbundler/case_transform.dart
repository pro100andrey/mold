import 'case_converter.dart';

/// A named case conversion, usable in a manifest substitution's `to:` value as
/// `{{ variable | transform }}`.
///
/// The enum identifiers **are** the names written in the manifest, so a lookup
/// is `CaseTransform.values.byName(...)` and the "valid transforms are …"
/// message is generated from `values`. Neither can drift from this list.
///
/// Adding one — `dotCase`, the inverse of [pathCase] — is one value here plus
/// one method on [CaseConverter].
enum CaseTransform {
  /// `my_project`
  snakeCase,

  /// `my-project`
  kebabCase,

  /// `myProject`
  camelCase,

  /// `MyProject`
  pascalCase,

  /// `MY_PROJECT`
  screamingCase,

  /// `My Project`
  titleCase,

  /// `com.acme` → `com/acme`
  ///
  /// The one transform that is not a case conversion: it swaps `.` for `/` and
  /// leaves every segment spelled as written, because a package path is a
  /// sequence of identifiers rather than a token to be re-worded. Do not
  /// "regularise" it onto [CaseConverter.splitWords] like its neighbours —
  /// that is what it exists to avoid.
  pathCase;

  /// Applies this transform to [value].
  String apply(String value) {
    const converter = CaseConverter();
    return switch (this) {
      .snakeCase => converter.toSnake(value),
      .kebabCase => converter.toKebab(value),
      .camelCase => converter.toCamel(value),
      .pascalCase => converter.toPascal(value),
      .screamingCase => converter.toScreamingSnake(value),
      .titleCase => converter.toTitle(value),
      .pathCase => converter.toPath(value),
    };
  }

  /// The transform named [name], or null when there is no such transform.
  static CaseTransform? byNameOrNull(String name) {
    for (final transform in values) {
      if (transform.name == name) {
        return transform;
      }
    }

    return null;
  }

  /// All transform names, for an error message listing the valid choices.
  static String get names => values.map((t) => t.name).join(', ');
}
