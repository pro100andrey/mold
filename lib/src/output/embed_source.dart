import 'dart:convert';

import '../unbundler/case_converter.dart';

/// Builds the embeddable Dart sources for the `bytes` / `base64` output formats.
///
/// These are auto-generated asset blobs (a `const` list / base64 string) with
/// no structure to model, so they are assembled as plain string templates
/// rather than with a code-builder library.
class EmbedSource {
  const EmbedSource();

  static const _header =
      '// AUTO-GENERATED — DO NOT EDIT.\n'
      '// Produced by `mold pack`.\n';

  /// The `const` identifier for a template named [manifestName]
  /// (e.g. `super_server` → `kSuperServerTemplate`).
  String constName(String manifestName) =>
      'k${const CaseConverter().toPascal(manifestName)}Template';

  /// A Dart source declaring `const List<int> kXxxTemplate = [...]`.
  String bytesSource({required List<int> archive, required String name}) {
    final buffer = StringBuffer()
      ..write(_header)
      ..writeln()
      ..writeln('const List<int> ${constName(name)} = <int>[')
      ..write('  ');
    for (var i = 0; i < archive.length; i++) {
      // Wrap for readability without exceeding line-length lints.
      buffer
        ..write('${archive[i]},')
        ..write((i + 1) % 16 == 0 ? '\n  ' : ' ');
    }

    return (buffer
          ..writeln()
          ..writeln('];'))
        .toString();
  }

  /// A Dart source declaring a base64 `const String kXxxTemplateBase64`.
  String base64Source({required List<int> archive, required String name}) {
    final encoded = base64.encode(archive);
    return '$_header\n'
        "const String ${constName(name)}Base64 =\n    '$encoded';\n";
  }
}
