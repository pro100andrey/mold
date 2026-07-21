import 'validation_result.dart';

/// A validation phase: produces a [ValidationResult] for an input of type [T].
///
/// Validators are run in a fixed order by the bundler/unbundler; the first
/// phase whose result is invalid aborts before the next phase runs.
abstract class ValidatorBase<T> {
  const ValidatorBase();

  /// The ordered phase name this validator guards (e.g. `manifest`).
  String get phase;

  /// Validates [input] and returns the collected issues.
  ValidationResult validate(T input);
}
