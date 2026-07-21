import 'case_converter.dart';

/// A named case conversion, usable in a manifest substitution's `to:` value as
/// `{{ variable | transform }}`.
///
/// The enum identifiers **are** the names written in the manifest, so a lookup
/// is `CaseTransform.values.byName(...)` and the "valid transforms are …"
/// message is generated from `values`. Neither can drift from this list.
///
/// Adding one — `dotCase`, `pathCase` — is one value here plus one method on
/// [CaseConverter].
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
  titleCase;

  /// Applies this transform to [value].
  String apply(String value) {
    const converter = CaseConverter();
    return switch (this) {
      CaseTransform.snakeCase => converter.toSnake(value),
      CaseTransform.kebabCase => converter.toKebab(value),
      CaseTransform.camelCase => converter.toCamel(value),
      CaseTransform.pascalCase => converter.toPascal(value),
      CaseTransform.screamingCase => converter.toScreamingSnake(value),
      CaseTransform.titleCase => converter.toTitle(value),
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
