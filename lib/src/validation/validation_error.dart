/// Whether an issue blocks the operation ([error]) or is advisory ([warning]).
enum Severity {
  /// Blocks the operation; surfaces via `ValidationResult.throwIfInvalid`.
  error,

  /// Advisory only; the operation proceeds.
  warning,
}

/// A single structured validation issue with a stable [code].
class ValidationError {
  const ValidationError(
    this.code,
    this.message, {
    this.field,
    this.severity = Severity.error,
  });

  /// A warning-severity issue (does not block).
  const ValidationError.warning(this.code, this.message, {this.field})
    : severity = Severity.warning;

  /// Stable machine code, e.g. `MANIFEST_MISSING_NAME`.
  final String code;

  /// Human-facing explanation.
  final String message;

  /// The manifest field or variable name the issue concerns, if any.
  final String? field;

  /// Whether this blocks (error) or is advisory (warning).
  final Severity severity;

  /// Whether this is an error-severity issue.
  bool get isError => severity == Severity.error;

  @override
  String toString() => '[$code] $message';
}
