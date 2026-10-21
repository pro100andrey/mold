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

  static const invalid = 'MANIFEST_INVALID';
  static const notFound = 'MANIFEST_NOT_FOUND';
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
  static const duplicateSubstitution = 'MANIFEST_DUPLICATE_SUBSTITUTION';
  static const conflictingTokens = 'MANIFEST_CONFLICTING_TOKENS';
  static const invalidPattern = 'MANIFEST_INVALID_PATTERN';
  static const invalidDefault = 'MANIFEST_INVALID_DEFAULT';
  static const unknownKey = 'MANIFEST_UNKNOWN_KEY';

  @override
  String get phase => 'manifest';

  @override
  ValidationResult validate(Manifest input) {
    final issues = <ValidationError>[
      for (final MapEntry(key: path, value: guess) in input.unknownKeys.entries)
        ValidationError.warning(
          unknownKey,
          "Unknown manifest key '$path'"
          "${guess == null ? '.' : " — did you mean '$guess'?"}"
          ' It is ignored.',
          field: path,
        ),
    ];

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

      issues.addAll(_checkConstraints(variable));
    }

    issues.addAll(_conflictingTokens(input.variables));

    for (final pattern in input.globPatterns) {
      try {
        Glob(pattern);
      } on FormatException {
        issues.add(ValidationError(invalidGlob, "Invalid glob: '$pattern'."));
      }
    }

    issues
      ..addAll(_duplicates('extra_substitutions', input.extraSubstitutions))
      ..addAll(_duplicates('path_renames', input.pathRenames))
      ..addAll(_checkTemplates(input, seen));

    return ValidationResult(issues);
  }

  /// A `pattern` that does not compile, and a `default` its own constraints
  /// reject — a default the user could never have typed.
  static List<ValidationError> _checkConstraints(TemplateVariable variable) {
    final pattern = variable.pattern;
    if (pattern != null) {
      try {
        RegExp(pattern);
      } on FormatException catch (e) {
        return [
          ValidationError(
            invalidPattern,
            "Variable '${variable.name}': pattern '$pattern' is not a valid "
            'regular expression: ${e.message}',
            field: variable.name,
          ),
        ];
      }
    }

    final defaultValue = variable.defaultValue;
    if (defaultValue != null && !variable.accepts(defaultValue)) {
      return [
        ValidationError(
          invalidDefault,
          "Variable '${variable.name}': default '$defaultValue' is not "
          'allowed by its own ${_describeConstraints(variable)}.',
          field: variable.name,
        ),
      ];
    }

    return const [];
  }

  /// `pattern '…'`, `choices […]`, or both — for a message.
  static String _describeConstraints(TemplateVariable variable) => [
    if (variable.pattern case final p?) "pattern '$p'",
    if (variable.choices.isNotEmpty) 'choices (${variable.choices.join(', ')})',
  ].join(' and ');

  /// Pairs of variables whose `replaces` tokens derive a casing in common.
  ///
  /// The replacement table is keyed by casing, so a shared one belongs to the
  /// later variable and the earlier one silently loses those sites —
  /// `my_app` and `my-app` share every casing but kebab. Containment is not
  /// reported: `app` inside `my_app` resolves by longest match, which is
  /// well-defined.
  static List<ValidationError> _conflictingTokens(
    List<TemplateVariable> variables,
  ) {
    const converter = CaseConverter();
    final claimed = <String, TemplateVariable>{};
    final issues = <ValidationError>[];
    for (final variable in variables) {
      final replaces = variable.replaces;
      if (replaces == null || replaces.isEmpty) {
        continue;
      }
      final shared = <String, List<String>>{};
      for (final casing in converter.replacements(replaces, replaces).keys) {
        final earlier = claimed[casing];
        if (earlier != null && earlier.name != variable.name) {
          (shared[earlier.name] ??= []).add(casing);
        }
        claimed[casing] = variable;
      }
      for (final MapEntry(key: earlier, value: casings) in shared.entries) {
        issues.add(
          ValidationError.warning(
            conflictingTokens,
            "Variables '$earlier' and '${variable.name}' both derive "
            '${casings.join(', ')}; those sites take the value of '
            "'${variable.name}', the later one.",
            field: variable.name,
          ),
        );
      }
    }

    return issues;
  }

  /// Entries within one section that share a `from`.
  ///
  /// Rendering keys the replacement table by `from`, so a repeated one means
  /// the later entry wins and the earlier never runs — a rule the author wrote
  /// and the tool silently ignored.
  ///
  /// Deliberately per-section, not across both: the two sections build
  /// separate tables, and a `from` appearing in each is the documented idiom
  /// for renaming a literal in content while pinning it in paths.
  static List<ValidationError> _duplicates(
    String section,
    List<Substitution> entries,
  ) {
    final seen = <String>{};

    return [
      for (final entry in entries)
        if (!seen.add(entry.from))
          ValidationError(
            duplicateSubstitution,
            "Duplicate '$section' entry for '${entry.from}'. Only the last "
            'would apply; the earlier one would never run.',
            field: entry.from,
          ),
    ];
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

    for (final substitution in input.replacementTemplates) {
      final from = substitution.from;
      final template = SubstitutionTemplate.parse(substitution.to);
      for (final error in template.errors) {
        issues.add(
          ValidationError(
            switch (error.kind) {
              .unterminated => unterminatedPlaceholder,
              .malformed => malformedPlaceholder,
              .unknownTransform => unknownTransform,
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
    }

    for (final variable in input.variables) {
      if (variable.replaces == null && !referenced.contains(variable.name)) {
        issues.add(
          .warning(
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
