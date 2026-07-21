import '../manifest/manifest.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';

/// Input to the [VariablesValidator]: the declared [variables] and the resolved
/// [values].
class VariablesInput {
  const VariablesInput({required this.variables, required this.values});

  /// The manifest's declared variables.
  final List<TemplateVariable> variables;

  /// The resolved name → value map.
  final Map<String, String> values;
}

/// Validates resolved variables (unbundle phase): every required variable has a
/// value, and each `replaces` value is a well-formed name token.
class VariablesValidator extends ValidatorBase<VariablesInput> {
  const VariablesValidator();

  static const missing = 'VARIABLE_MISSING';
  static const invalidFormat = 'VARIABLE_INVALID_FORMAT';

  /// A value used for a `replaces` token must read like an identifier: start
  /// with a letter, then letters/digits/space/underscore/hyphen.
  static final _nameFormat = RegExp(r'^[A-Za-z][A-Za-z0-9 _-]*$');

  @override
  String get phase => 'variables';

  @override
  ValidationResult validate(VariablesInput input) {
    final issues = <ValidationError>[];
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
