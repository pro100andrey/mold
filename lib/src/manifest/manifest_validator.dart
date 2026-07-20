import 'package:glob/glob.dart';

import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';
import 'manifest.dart';

/// Validates a [Manifest] (runs for both pack and unpack): required fields,
/// no duplicate variables, valid globs, and non-empty `replaces` tokens.
class ManifestValidator extends ValidatorBase<Manifest> {
  const ManifestValidator();

  static const missingName = 'MANIFEST_MISSING_NAME';
  static const missingVersion = 'MANIFEST_MISSING_VERSION';
  static const duplicateVariable = 'MANIFEST_DUPLICATE_VARIABLE';
  static const invalidGlob = 'MANIFEST_INVALID_GLOB';
  static const emptyReplaces = 'MANIFEST_EMPTY_REPLACES';

  @override
  String get phase => 'manifest';

  @override
  ValidationResult validate(Manifest input) {
    final issues = <ValidationError>[];

    if (input.name.isEmpty) {
      issues.add(
        const ValidationError(
          missingName,
          "Manifest field 'name' is required.",
          field: 'name',
        ),
      );
    }
    if (input.version.isEmpty) {
      issues.add(
        const ValidationError(
          missingVersion,
          "Manifest field 'version' is required.",
          field: 'version',
        ),
      );
    }

    final seen = <String>{};
    for (final variable in input.variables) {
      if (!seen.add(variable.name)) {
        issues.add(
          ValidationError(
            duplicateVariable,
            "Duplicate variable '${variable.name}'.",
            field: variable.name,
          ),
        );
      }
      
      final replaces = variable.replaces;
      if (replaces != null && replaces.isEmpty) {
        issues.add(
          ValidationError(
            emptyReplaces,
            "Variable '${variable.name}' has an empty 'replaces' token.",
            field: variable.name,
          ),
        );
      }
    }

    for (final pattern in [
      ...input.include,
      ...input.exclude,
      ...input.noSubstitute,
    ]) {
      try {
        Glob(pattern);
      } on FormatException {
        issues.add(ValidationError(invalidGlob, "Invalid glob: '$pattern'."));
      }
    }

    return ValidationResult(issues);
  }
}
