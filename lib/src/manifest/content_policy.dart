import 'dart:convert';

import 'package:glob/glob.dart';

import '../bundler/file_classifier.dart';
import 'manifest.dart';

/// Decides, per file, whether its content is substituted or copied verbatim.
///
/// The one place that decision is made, so the pack-time token check measures
/// exactly the files unpacking will rewrite. They used to decide separately,
/// and the check counted tokens inside `no_substitute` files — sites
/// substitution never touches.
class ContentPolicy {
  ContentPolicy(Manifest manifest)
    : _classifier = FileClassifier(
        extraBinary: manifest.binaryExtensions.toSet(),
      ),
      _noSubstitute = manifest.noSubstitute.map(Glob.new).toList();

  final FileClassifier _classifier;
  final List<Glob> _noSubstitute;

  /// Whether [path] is copied verbatim whatever it holds: a binary extension,
  /// or a `no_substitute` match.
  bool isVerbatimPath(String path) =>
      _classifier.isBinary(path) || _noSubstitute.any((g) => g.matches(path));

  /// The decoded text of [bytes], or null when the file at [path] is copied
  /// verbatim.
  ///
  /// Verbatim means [isVerbatimPath], or content that is not valid UTF-8.
  /// Extension-based classification calls anything unlisted text, including
  /// extensionless files, so a "text" file can still hold non-UTF-8 bytes;
  /// falling back keeps it intact instead of aborting the unpack partway
  /// through. Classification stays extension-based — no content sniffing.
  String? decode(String path, List<int> bytes) {
    if (isVerbatimPath(path)) {
      return null;
    }

    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }
}
