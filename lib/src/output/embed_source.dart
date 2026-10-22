import 'dart:convert';

import '../unbundler/case_converter.dart';

/// Builds the embeddable Dart sources for the `bytes` / `base64` output formats.
///
/// These are auto-generated asset blobs (a `const` list / base64 string) with
/// no structure to model, so they are assembled as plain string templates
/// rather than with a code-builder library.
///
/// The output is meant to be committed into someone else's package, so it has
/// to survive that package's tooling unchanged:
///
/// - **Lints.** `// ignore_for_file: type=lint` is the standard header of
///   generated code. Lint sets disagree about these very declarations —
///   `omit_obvious_property_types` wants the type gone, `always_specify_types`
///   wants it kept — so no spelling satisfies every consumer, and guessing one
///   just moves the warning. Errors are still reported.
/// - **`dart format`.** Formatting the file changes nothing, in both the tall
///   style (language 3.7+) and the short one before it. The byte list keeps its
///   packed rows because it opens with a comment — both styles preserve a
///   collection's line breaks once it holds one — and a row is 15 bytes, which
///   stays within 80 columns at three digits each. The base64 declaration is
///   split after `=` exactly when the formatter would split it.
class EmbedSource {
  const EmbedSource();

  static const _header =
      '// AUTO-GENERATED — DO NOT EDIT.\n'
      '// Produced by `mold pack`.\n'
      '\n'
      '// ignore_for_file: type=lint\n';

  /// Bytes per row of the `bytes` source: `255, ` × 15 plus the indent is 76
  /// columns; 16 is 81, which the formatter rewraps.
  static const _bytesPerRow = 15;

  /// The formatter's page width.
  static const _pageWidth = 80;

  /// The `const` identifier for a template named [manifestName]
  /// (e.g. `super_server` → `kSuperServerTemplate`).
  String constName(String manifestName) =>
      'k${const CaseConverter().toPascal(manifestName)}Template';

  /// A Dart source declaring `const List<int> kXxxTemplate = [...]`.
  ///
  /// [doc] becomes the constant's doc comment, one `///` line per line of it.
  String bytesSource({
    required List<int> archive,
    required String name,
    String? doc,
  }) {
    final buffer = StringBuffer()
      ..write(_header)
      ..writeln()
      ..write(_docComment(doc))
      ..writeln('const List<int> ${constName(name)} = <int>[')
      ..writeln('  // ${archive.length} bytes: a gzipped tar archive.');
    for (var i = 0; i < archive.length; i += _bytesPerRow) {
      final row = archive.skip(i).take(_bytesPerRow);
      buffer.writeln('  ${row.join(', ')},');
    }

    return (buffer..writeln('];')).toString();
  }

  /// The archive bytes in [source], a source rendered by [bytesSource] or
  /// [base64Source]; null when it holds neither shape.
  ///
  /// What `pack --check` compares a committed source by: the archive inside
  /// it, not the text around it. Line endings do not matter — a source
  /// committed with LF comes back with CRLF from a Windows checkout.
  List<int>? archiveOf(String source) {
    final list = _bytesList.firstMatch(source);
    if (list != null) {
      final values = <int>[];
      for (final line in list[1]!.split('\n')) {
        final code = line.trim();
        if (code.isEmpty || code.startsWith('//')) {
          continue;
        }
        for (final item in code.split(',')) {
          if (item.trim().isEmpty) {
            continue;
          }
          final value = int.tryParse(item.trim());
          if (value == null || value < 0 || value > 255) {
            return null;
          }
          values.add(value);
        }
      }

      return values;
    }

    final encoded = _base64Literal.firstMatch(source);
    if (encoded == null) {
      return null;
    }
    try {
      return base64.decode(encoded[1]!);
    } on FormatException {
      return null;
    }
  }

  static final _bytesList = RegExp(r'= <int>\[\r?\n(.*?)\];', dotAll: true);
  static final _base64Literal = RegExp(
    r"Base64 =\s*'([A-Za-z0-9+/=]*)';",
  );

  /// A Dart source declaring a base64 `const String kXxxTemplateBase64`.
  ///
  /// [doc] becomes the constant's doc comment, one `///` line per line of it.
  String base64Source({
    required List<int> archive,
    required String name,
    String? doc,
  }) {
    final declaration = 'const String ${constName(name)}Base64 =';
    final literal = "'${base64.encode(archive)}';";
    final oneLine = '$declaration $literal';
    final body = oneLine.length <= _pageWidth
        ? oneLine
        : '$declaration\n    $literal';

    return '$_header\n${_docComment(doc)}$body\n';
  }

  /// [doc] as `///` lines, each ending in a newline; empty for none.
  ///
  /// Lines are kept as given: the formatter leaves comments alone, so one
  /// longer than the page is the caller's to wrap.
  static String _docComment(String? doc) {
    if (doc == null || doc.trim().isEmpty) {
      return '';
    }

    return [
      for (final line in const LineSplitter().convert(doc.trimRight()))
        '///${line.isEmpty ? '' : ' $line'}\n',
    ].join();
  }
}
