import '../manifest/manifest.dart';

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

  /// Prompts for [variable] — showing its description (if any) and default —
  /// and returns the entered value, or null when there is nothing to return.
  ///
  /// Empty input accepts the default when the variable has one; otherwise the
  /// (possibly empty) input is returned as-is.
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

    final def = variable.defaultValue;
    _out.write('${variable.name}${def != null ? ' [$def]' : ''}: ');

    final line = _readLine();
    if (line == null) {
      _out.writeln(); // Close the dangling prompt line.
      return def;
    }

    final trimmed = line.trim();

    return trimmed.isEmpty && def != null ? def : trimmed;
  }
}
