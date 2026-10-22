import 'validation_error.dart';

/// Thrown when an input — the manifest, the project, the archive, the
/// variables or the target — has error-severity issues; each carries a code
/// from `MoldCode`.
class ValidationException implements Exception {
  ValidationException(this.errors);

  /// The error-severity issues that caused the failure.
  final List<ValidationError> errors;

  /// The codes of [errors], in order — what a caller usually branches on.
  Iterable<String> get codes => errors.map((e) => e.code);

  /// The messages of [errors], one per line, without the codes.
  String get message => errors.map((e) => e.message).join('\n');

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

  /// Whether there are no error-severity issues.
  bool get isValid => errors.isEmpty;

  /// Emits every warning to [onWarning], then throws if there are errors.
  ///
  /// The one way the pipeline consumes a result. Calling [throwIfInvalid]
  /// alone is what once dropped every unpack-phase warning: warnings do not
  /// block, so nothing failed and nothing was printed either. Warnings go
  /// first so that, when there are errors too, the warnings explaining them
  /// are not lost to the throw.
  void report(WarningSink? onWarning) {
    if (onWarning != null) {
      warnings.forEach(onWarning);
    }
    throwIfInvalid();
  }

  /// Throws a [ValidationException] if any error-severity issue is present.
  /// Warnings never block.
  void throwIfInvalid() {
    if (!isValid) {
      throw ValidationException(errors);
    }
  }
}
