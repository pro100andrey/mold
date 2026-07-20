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
  /// and returns the entered value. Empty input accepts the default when the
  /// variable has one; otherwise the (possibly empty) input is returned as-is.
  String promptFor(TemplateVariable variable) {
    if (variable.description.isNotEmpty) {
      _out.writeln(variable.description);
    }
    
    final def = variable.defaultValue;
    _out.write('${variable.name}${def != null ? ' [$def]' : ''}: ');

    final line = _readLine()?.trim() ?? '';
    return line.isEmpty && def != null ? def : line;
  }
}
