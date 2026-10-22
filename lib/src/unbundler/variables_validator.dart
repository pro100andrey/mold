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
    this.recorded = const {},
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

  /// The values a previous unpack recorded (an `UnpackStamp`'s), used where
  /// [explicit] has none.
  ///
  /// Unlike [explicit], a name here the template does not declare is not a
  /// mistake: the template has dropped or renamed the variable since. It is
  /// reported, and the value is not used.
  final Map<String, String> recorded;
}

/// Validates resolved variables (unbundle phase): every required variable has a
/// value, each `replaces` value is a well-formed name token, and every
/// explicitly supplied value names a variable that exists.
class VariablesValidator extends ValidatorBase<VariablesInput> {
  const VariablesValidator();

  static const missing = 'VARIABLE_MISSING';
  static const invalidFormat = 'VARIABLE_INVALID_FORMAT';
  static const unknown = 'VARIABLE_UNKNOWN';
  static const patternMismatch = 'VARIABLE_PATTERN_MISMATCH';
  static const notAChoice = 'VARIABLE_NOT_A_CHOICE';

  /// A warning: [VariablesInput.recorded] names a variable that is gone.
  static const dropped = 'VARIABLE_DROPPED';

  /// Raised while planning, not by [validate]: finding it needs the
  /// template's content.
  static const valuePresent = 'VARIABLE_VALUE_PRESENT';

  /// A value used for a `replaces` token must be a name the casings can be
  /// derived from: ASCII letters, digits, space, underscore and hyphen,
  /// starting with a letter or digit and holding at least one letter. A
  /// leading separator would be dropped by the casings but written as is by
  /// a plain `{{ name }}`.
  ///
  /// A leading digit is allowed — `3d-viewer` is a fine npm package, Go
  /// module or directory, if not a Dart one. A language that forbids it says
  /// so with the variable's `pattern`.
  static final _nameFormat = RegExp(
    r'^(?=.*[A-Za-z])[A-Za-z0-9][A-Za-z0-9 _-]*$',
  );

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

    for (final name in input.recorded.keys) {
      if (!declared.contains(name) && !input.explicit.containsKey(name)) {
        issues.add(
          ValidationError.warning(
            dropped,
            "The recorded value of '$name' is not used: this template no "
            'longer declares it. Declared: $known.',
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

      final issue = checkValue(variable, value);
      if (issue != null) {
        issues.add(issue);
      }
    }

    return ValidationResult(issues);
  }

  /// What is wrong with [value] for [variable], or null when it is
  /// acceptable: not a choice, not matching the pattern, or — for a
  /// `replaces` variable — not a name token.
  ///
  /// One check for the prompter and the validator, so a prompt re-asks for
  /// exactly what validation would refuse.
  static ValidationError? checkValue(TemplateVariable variable, String value) {
    if (variable.choices.isNotEmpty && !variable.choices.contains(value)) {
      return ValidationError(
        notAChoice,
        "Variable '${variable.name}' value '$value' is not one of: "
        '${variable.choices.join(', ')}.',
        field: variable.name,
      );
    }
    if (variable.pattern != null && !variable.accepts(value)) {
      return ValidationError(
        patternMismatch,
        "Variable '${variable.name}' value '$value' does not match "
        "pattern '${variable.pattern}'.",
        field: variable.name,
      );
    }
    if (variable.replaces != null && !_nameFormat.hasMatch(value)) {
      return ValidationError(
        invalidFormat,
        "Variable '${variable.name}' value '$value' is not a valid name "
        'token.',
        field: variable.name,
      );
    }

    return null;
  }
}
