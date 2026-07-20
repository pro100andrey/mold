import '../manifest/manifest.dart';
import 'variable_prompter.dart';

/// Resolves a value for every declared variable, with a fixed precedence:
///
/// 1. an explicit `--var key=value`;
/// 2. under [noPrompt], the manifest `default` (never blocks on input);
/// 3. otherwise an interactive prompt via [prompter].
///
/// With neither a prompter nor [noPrompt] (a non-interactive library call),
/// an unresolved variable falls back to its default or, lacking one, is left
/// out of the result for `VariablesValidator` to report.
class VariableResolver {
  const VariableResolver({this.prompter, this.noPrompt = false});

  /// The prompter used for unresolved variables when prompting is enabled.
  final VariablePrompter? prompter;

  /// When true, never prompt: resolve from `--var` and manifest defaults only.
  final bool noPrompt;

  /// Resolves [variables] against the [explicit] `--var` map, returning a name
  /// → value map.
  ///
  /// A variable that cannot be resolved — no explicit value, no prompt, no
  /// default — is **omitted** rather than raising here, so `VariablesValidator`
  /// reports it as a structured VARIABLE_MISSING along with every other gap.
  /// Throwing on the first one surfaced them one at a time and bypassed the
  /// validation phase entirely.
  Map<String, String> resolve(
    List<TemplateVariable> variables,
    Map<String, String> explicit,
  ) {
    final out = <String, String>{};
    for (final variable in variables) {
      final value = _resolveOne(variable, explicit);
      if (value != null) {
        out[variable.name] = value;
      }
    }

    return out;
  }

  String? _resolveOne(TemplateVariable variable, Map<String, String> explicit) {
    final given = explicit[variable.name];
    if (given != null) {
      return given;
    }

    if (!noPrompt && prompter != null) {
      return prompter!.promptFor(variable);
    }

    return variable.defaultValue;
  }
}
