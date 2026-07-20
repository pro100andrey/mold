import 'dart:convert';

import 'package:archive/archive.dart';

/// The decoded contents of a template archive: the embedded manifest YAML and
/// the captured project files (relative path under `files/` → bytes).
class BundleArchive {
  const BundleArchive({required this.manifestYaml, required this.files});

  /// The raw `mold.yaml` text embedded in the archive.
  final String manifestYaml;

  /// The captured files, keyed by their path relative to `files/`.
  final Map<String, List<int>> files;
}

/// Reads a gzipped-tar template archive back into a [BundleArchive].
class ArchiveReader {
  const ArchiveReader();

  /// Decodes [bytes] (gzip + tar) into the embedded manifest and `files/` tree.
  ///
  /// Throws a [FormatException] if the archive is missing `mold.yaml`.
  BundleArchive read(List<int> bytes) {
    final tar = const GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(tar);

    String? manifestYaml;
    final files = <String, List<int>>{};
    for (final file in archive) {
      if (!file.isFile) {
        continue;
      }

      final name = file.name;
      if (name == 'mold.yaml') {
        manifestYaml = utf8.decode(file.content as List<int>);
      } else if (name.startsWith('files/')) {
        files[name.substring('files/'.length)] = .from(
          file.content as List<int>,
        );
      }
    }

    if (manifestYaml == null) {
      throw const FormatException('Archive is missing mold.yaml.');
    }

    return BundleArchive(manifestYaml: manifestYaml, files: files);
  }
}
