import 'package:yaml/yaml.dart';

/// The text of [node] as it was written, or null when it is absent or null.
///
/// For a value mold treats as text. YAML reads an unquoted `1.10` as the
/// number 1.1 and `007` as 7, so turning the parsed value back into a string —
/// what the manifest and `--vars-file` did — silently changed `version: 1.10`
/// to `1.1`, a `--vars-file` `build: 007` to `7`, and `choices: [1.10]` to a
/// list that only accepts `1.1`. A plain scalar's source text is what the
/// author meant; a quoted one's value already is.
///
/// Anything that is not a scalar falls back to its value's `toString`, as
/// before — shape errors are the caller's to report.
String? nodeText(YamlNode? node) {
  if (node == null) {
    return null;
  }
  if (node is YamlScalar) {
    final value = node.value;
    return switch (value) {
      null => null,
      String() => value,
      _ => node.span.text,
    };
  }

  return '${node.value}';
}

/// [nodeText] of the value at [key] in [map].
String? textAt(YamlMap map, Object key) => nodeText(map.nodes[key]);
