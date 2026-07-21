import 'package:path/path.dart' as p;

/// Whether a file is treated as substitutable text or copied verbatim.
enum FileKind {
  /// Text — eligible for path/content substitution.
  text,

  /// Binary — copied byte-for-byte, never substituted.
  binary,
}

/// Classifies files as [FileKind.text] or [FileKind.binary] by extension.
///
/// Classification is extension-based only (no content sniffing — out of scope).
/// A built-in set of known binary extensions can be augmented per template via
/// the `extraBinary` constructor argument (the manifest's `binary_extensions`).
/// Files whose extension is not known-binary — including extensionless files
/// like `Makefile` — are text.
class FileClassifier {
  FileClassifier({Set<String> extraBinary = const {}})
    : _binary = {..._builtinBinary, ...extraBinary.map(_normalize)};

  final Set<String> _binary;

  /// Built-in binary extensions (lowercase, no leading dot).
  static const _builtinBinary = <String>{
    // images
    'png', 'jpg', 'jpeg', 'gif', 'bmp', 'ico', 'webp', 'tiff', 'tif',
    // fonts
    'ttf', 'otf', 'woff', 'woff2', 'eot',
    // audio / video
    'mp3', 'wav', 'ogg', 'flac', 'mp4', 'm4a', 'mov', 'avi', 'webm', 'mkv',
    // archives
    'zip', 'gz', 'tgz', 'bz2', 'xz', 'tar', '7z', 'rar', 'jar',
    // databases
    'db', 'sqlite', 'sqlite3',
    // documents
    'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx',
    // compiled / opaque
    'exe', 'dll', 'so', 'dylib', 'bin', 'dat', 'wasm', 'class', 'pyc',
  };

  /// Classifies the file at [path] by its extension.
  FileKind classify(String path) =>
      isBinary(path) ? FileKind.binary : FileKind.text;

  /// Whether the file at [path] is binary (copied verbatim).
  bool isBinary(String path) {
    final ext = _normalize(p.extension(path));
    return ext.isNotEmpty && _binary.contains(ext);
  }

  /// Lowercases and strips a leading dot from an extension token.
  static String _normalize(String ext) {
    final lower = ext.toLowerCase();

    return lower.startsWith('.') ? lower.substring(1) : lower;
  }
}
