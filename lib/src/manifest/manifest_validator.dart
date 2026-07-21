import 'package:glob/glob.dart';

import '../unbundler/case_converter.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';
import 'manifest.dart';
import 'substitution_template.dart';

/// Validates a [Manifest] (runs for both pack and unpack): required fields,
/// no duplicate variables, valid globs, usable `replaces` tokens, and
/// well-formed substitution templates.
///
/// Template checks run here, at a phase that executes at **both** pack and
/// unpack, so a template author learns about a bad placeholder from
/// `mold pack` rather than from a user's failed unpack.
class ManifestValidator extends ValidatorBase<Manifest> {
  const ManifestValidator();

  static const missingName = 'MANIFEST_MISSING_NAME';
  static const missingVersion = 'MANIFEST_MISSING_VERSION';
  static const duplicateVariable = 'MANIFEST_DUPLICATE_VARIABLE';
  static const invalidGlob = 'MANIFEST_INVALID_GLOB';
  static const emptyReplaces = 'MANIFEST_EMPTY_REPLACES';
  static const unsupportedReplaces = 'MANIFEST_UNSUPPORTED_REPLACES';
  static const malformedPlaceholder = 'MANIFEST_MALFORMED_PLACEHOLDER';
  static const unterminatedPlaceholder = 'MANIFEST_UNTERMINATED_PLACEHOLDER';
  static const unknownTransform = 'MANIFEST_UNKNOWN_TRANSFORM';
  static const unknownVariable = 'MANIFEST_UNKNOWN_VARIABLE';
  static const unusedVariable = 'MANIFEST_UNUSED_VARIABLE';

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
      if (replaces != null &&
          replaces.isNotEmpty &&
          const CaseConverter().splitWords(replaces).isEmpty) {
        issues.add(
          ValidationError(
            unsupportedReplaces,
            "Variable '${variable.name}': token '$replaces' has no ASCII "
            'word characters, so it would substitute nothing.',
            field: variable.name,
          ),
        );
      }
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

    for (final pattern in input.globPatterns) {
      try {
        Glob(pattern);
      } on FormatException {
        issues.add(ValidationError(invalidGlob, "Invalid glob: '$pattern'."));
      }
    }

    issues.addAll(_checkTemplates(input, seen));

    return ValidationResult(issues);
  }

  /// Checks every substitution template: syntax, transform names, and that
  /// each `{{ name }}` refers to a variable the manifest declares.
  ///
  /// Also warns about a variable that nothing can use — no `replaces` and no
  /// placeholder referencing it — which would prompt the user for a value that
  /// goes nowhere. A warning, not an error: a library caller may legitimately
  /// declare a variable for a downstream consumer.
  List<ValidationError> _checkTemplates(
    Manifest input,
    Set<String> declaredNames,
  ) {
    final issues = <ValidationError>[];
    final referenced = <String>{};

    input.replacementTemplates.forEach((from, to) {
      final template = SubstitutionTemplate.parse(to);
      for (final error in template.errors) {
        issues.add(
          ValidationError(
            switch (error.kind) {
              TemplateErrorKind.unterminated => unterminatedPlaceholder,
              TemplateErrorKind.malformed => malformedPlaceholder,
              TemplateErrorKind.unknownTransform => unknownTransform,
            },
            error.message,
            field: from,
          ),
        );
      }
      for (final name in template.variableNames) {
        referenced.add(name);
        if (!declaredNames.contains(name)) {
          issues.add(
            ValidationError(
              unknownVariable,
              "Substitution '$from' references '{{ $name }}', which is not a "
              'declared variable.',
              field: from,
            ),
          );
        }
      }
    });

    for (final variable in input.variables) {
      if (variable.replaces == null && !referenced.contains(variable.name)) {
        issues.add(
          ValidationError.warning(
            unusedVariable,
            "Variable '${variable.name}' has no 'replaces' and is not "
            'referenced by any substitution, so it does nothing.',
            field: variable.name,
          ),
        );
      }
    }

    return issues;
  }
}
