import '../manifest/manifest.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';

/// Input to the [VariablesValidator]: the declared [variables] and the resolved
/// [values].
class VariablesInput {
  const VariablesInput({
    required this.variables,
    required this.values,
    this.explicit = const {},
  });

  /// The manifest's declared variables.
  final List<TemplateVariable> variables;

  /// The resolved name → value map.
  final Map<String, String> values;

  /// The values supplied explicitly (`--var key=value`), before resolution.
  ///
  /// Kept separate from [values] because resolution *drops* keys that name no
  /// declared variable, so by then a typo is indistinguishable from never
  /// having been passed.
  final Map<String, String> explicit;
}

/// Validates resolved variables (unbundle phase): every required variable has a
/// value, each `replaces` value is a well-formed name token, and every
/// explicitly supplied value names a variable that exists.
class VariablesValidator extends ValidatorBase<VariablesInput> {
  const VariablesValidator();

  static const missing = 'VARIABLE_MISSING';
  static const invalidFormat = 'VARIABLE_INVALID_FORMAT';
  static const unknown = 'VARIABLE_UNKNOWN';

  /// A value used for a `replaces` token must read like an identifier: start
  /// with a letter, then letters/digits/space/underscore/hyphen.
  static final _nameFormat = RegExp(r'^[A-Za-z][A-Za-z0-9 _-]*$');

  @override
  String get phase => 'variables';

  @override
  ValidationResult validate(VariablesInput input) {
    final issues = <ValidationError>[];

    // A `--var` naming nothing was silently discarded, so a mistyped key left
    // the variable on its default and scaffolded a wrong project with exit 0 —
    // the failure mode this package refuses everywhere else.
    final declared = {for (final v in input.variables) v.name};
    final known = declared.isEmpty
        ? '(none)'
        : (declared.toList()..sort()).join(', ');
    for (final name in input.explicit.keys) {
      if (!declared.contains(name)) {
        issues.add(
          ValidationError(
            unknown,
            "No variable '$name' is declared by this template. "
            'Declared: $known.',
            field: name,
          ),
        );
      }
    }

    for (final variable in input.variables) {
      final value = input.values[variable.name];
      // An absent key is only a problem when nothing can fill it. A caller
      // passing a partial map for variables that declare defaults is valid —
      // requiring the map to be post-resolver would couple this validator to
      // one caller without saying so in its signature.
      if (value == null) {
        if (variable.defaultValue == null) {
          issues.add(
            ValidationError(
              missing,
              "Required variable '${variable.name}' has no value and no "
              'default.',
              field: variable.name,
            ),
          );
        }
        continue;
      }

      if (variable.replaces != null && !_nameFormat.hasMatch(value)) {
        issues.add(
          ValidationError(
            invalidFormat,
            "Variable '${variable.name}' value '$value' is not a valid name "
            'token.',
            field: variable.name,
          ),
        );
      }
    }

    return ValidationResult(issues);
  }
}
