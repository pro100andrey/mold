import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'case_converter.dart';

/// A named case conversion, usable in a manifest substitution's `to:` value
/// and in its `message` as `{{ variable | transform }}`.
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

  /// `myproject` — the words run together, lowercase: an Android
  /// `applicationId` segment, a Go or Java package name.
  flatCase,

  /// `com.acme` → `com/acme`
  ///
  /// The one transform that is not a case conversion: it swaps `.` for `/` and
  /// leaves every segment spelled as written, because a package path is a
  /// sequence of identifiers rather than a token to be re-worded. Do not
  /// "regularise" it onto [CaseConverter.splitWords] like its neighbours —
  /// that is what it exists to avoid.
  pathCase,

  /// `my_app` → `my_app`, `C:\work` → `"C:\\work"`, `yes` → `"yes"`
  ///
  /// The value as a YAML scalar, written in place of one: `key: {{ v |
  /// yamlString }}`, not inside quotes of the template's own. Plain when the
  /// value reads back as the same string — in block and flow context, and in
  /// YAML 1.1, where `yes` and `on` are booleans — and double-quoted, with
  /// JSON's escapes, when it would not. Not a case conversion either: the
  /// value is kept as written.
  yamlString;

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
      .flatCase => converter.toFlat(value),
      .pathCase => converter.toPath(value),
      .yamlString => _yamlScalar(value),
    };
  }

  /// Whether this transform re-spells a name token. [yamlString] does not: it
  /// quotes a value for YAML, so it explains no spelling of a token found in
  /// a project.
  bool get spellsToken => this != yamlString;

  static String _yamlScalar(String value) {
    if (_plain.hasMatch(value) && !_yaml11Special.hasMatch(value)) {
      try {
        if (loadYaml(value) == value) {
          return value;
        }
      } on YamlException {
        // Not plain YAML after all; quoted below.
      }
    }

    // A JSON string is a YAML double-quoted scalar: every JSON escape is a
    // YAML one.
    return jsonEncode(value);
  }

  /// Characters that mean the same in every YAML context, plain: letters,
  /// digits and `_ . / + ~ -`, with spaces inside but not at either end. No
  /// indicator — `:`, `#`, `,`, brackets, quotes — and no backslash.
  static final _plain = RegExp(
    r'^[A-Za-z0-9_./+~-](?:[A-Za-z0-9_./+~ -]*[A-Za-z0-9_./+~-])?$',
  );

  /// Plain scalars YAML 1.1 reads as something other than a string, which
  /// YAML 1.2 — and `package:yaml` — does not.
  static final _yaml11Special = RegExp(
    r'^(?:y|n|yes|no|on|off)$',
    caseSensitive: false,
  );

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
