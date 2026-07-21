/// How a packed template is emitted on disk by the CLI.
///
/// The core archive bytes are identical across formats; the format only governs
/// how those bytes are written out.
enum OutputFormat {
  /// Raw gzipped tar bytes written to a `.mold` file.
  tarGz('tar.gz'),

  /// A Dart source declaring `const List<int> kXxxTemplate = [...]`.
  bytes('bytes'),

  /// A Dart source declaring a base64 `const String` of the archive.
  base64('base64');

  const OutputFormat(this.flag);

  /// The `--format` flag value that selects this format.
  final String flag;

  /// Resolves a [flag] value to its [OutputFormat].
  ///
  /// Throws [FormatException] for an unknown flag. The CLI cannot reach it —
  /// `argParser` restricts the option to [values] — but a library caller can,
  /// and the bare `firstWhere` raised a `StateError` naming nothing useful,
  /// which no layer catches.
  static OutputFormat fromFlag(String flag) => values.firstWhere(
    (f) => f.flag == flag,
    orElse: () => throw FormatException(
      "Unknown output format '$flag'. Valid formats: "
      '${values.map((f) => f.flag).join(', ')}.',
    ),
  );
}
