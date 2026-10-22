import '../manifest/manifest.dart';
import '../unbundler/variables_validator.dart';

/// Reads a line of input, or null at end-of-input.
typedef LineReader = String? Function();

/// Interactively prompts for a single variable's value.
///
/// The line reader and output sink are injected so the prompter can be driven
/// from tests without touching real stdin/stdout.
class VariablePrompter {
  VariablePrompter(this._out, this._readLine);

  final StringSink _out;
  final LineReader _readLine;

  /// How many times an answer validation would refuse is asked again before
  /// it is returned anyway, for the validator to report.
  ///
  /// Bounded so a reader that keeps yielding the same line — a script piping
  /// a fixed answer — cannot loop forever.
  static const maxAttempts = 3;

  /// Prompts for [variable] — showing its description (if any) and default —
  /// and returns the entered value, or null when there is nothing to return.
  ///
  /// Empty input accepts the default when the variable has one; otherwise the
  /// (possibly empty) input is returned as-is. An answer validation would
  /// refuse — not a choice, not matching the pattern, not a name token — is
  /// explained and asked again, up to [maxAttempts] times.
  ///
  /// **End of input is not an answer.** With stdin closed — a CI job piping
  /// from `/dev/null` without `--no-prompt` — the reader yields null, and a
  /// variable with no default resolves to null rather than to `''`. Coercing
  /// it to an empty string produced a successfully-scaffolded, wrongly
  /// populated project and exit 0.
  String? promptFor(TemplateVariable variable) {
    if (variable.description.isNotEmpty) {
      _out.writeln(variable.description);
    }

    if (variable.choices.isNotEmpty) {
      _out.writeln('One of: ${variable.choices.join(', ')}');
    }

    final def = variable.defaultValue;
    for (var attempt = 1; ; attempt++) {
      _out.write('${variable.name}${def != null ? ' [$def]' : ''}: ');

      final line = _readLine();
      if (line == null) {
        _out.writeln(); // Close the dangling prompt line.
        return def;
      }

      final trimmed = line.trim();
      final value = trimmed.isEmpty && def != null ? def : trimmed;

      // Asked again here rather than refused after every other prompt:
      // one typo used to cost the whole session, answers included.
      final issue = VariablesValidator.checkValue(variable, value);
      if (issue == null || attempt == maxAttempts) {
        return value;
      }
      _out.writeln(issue.message);
    }
  }
}
