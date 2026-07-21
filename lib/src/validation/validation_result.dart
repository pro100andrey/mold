import 'validation_error.dart';

/// Thrown by [ValidationResult.throwIfInvalid] when error-severity issues are
/// present.
class ValidationException implements Exception {
  ValidationException(this.errors);

  /// The error-severity issues that caused the failure.
  final List<ValidationError> errors;

  @override
  String toString() {
    final lines = errors.map((e) => '  $e').join('\n');
    return 'Validation failed:\n$lines';
  }
}

/// The outcome of a validation phase: its [errors] and [warnings].
class ValidationResult {
  ValidationResult(List<ValidationError> issues)
    : errors = issues
          .where((e) => e.severity == .error)
          .toList(growable: false),
      warnings = issues
          .where((e) => e.severity == .warning)
          .toList(growable: false);

  /// An empty (passing) result.
  ValidationResult.ok() : this(const []);

  /// Error-severity issues (block the operation).
  final List<ValidationError> errors;

  /// Warning-severity issues (advisory; do not block).
  final List<ValidationError> warnings;

  /// True when there are no error-severity issues.
  bool get isValid => errors.isEmpty;

  /// Throws a [ValidationException] if any error-severity issue is present.
  /// Warnings never block.
  void throwIfInvalid() {
    if (!isValid) {
      throw ValidationException(errors);
    }
  }
}
