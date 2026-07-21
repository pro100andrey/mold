import 'dart:convert';

import 'package:archive/archive.dart';

import 'archive_codec.dart';

/// The decoded contents of a template archive: the embedded manifest YAML and
/// the captured project files (relative path under `files/` → bytes).
class BundleArchive {
  const BundleArchive({
    required this.manifestYaml,
    required this.files,
    this.executable = const {},
  });

  /// The raw `mold.yaml` text embedded in the archive.
  final String manifestYaml;

  /// The captured files, keyed by their path relative to `files/`.
  final Map<String, List<int>> files;

  /// The subset of [files] keys recorded with an owner-executable mode.
  final Set<String> executable;
}

/// Reads a gzipped-tar template archive back into a [BundleArchive].
class ArchiveReader {
  const ArchiveReader({
    this.maxDecompressedBytes = defaultMaxDecompressedBytes,
  });

  /// The ceiling on the decompressed archive. See [decodeGzipBounded].
  final int maxDecompressedBytes;

  /// Decodes [bytes] (gzip + tar) into the embedded manifest and `files/` tree.
  ///
  /// Throws a [FormatException] if the archive is missing `mold.yaml`, and an
  /// [ArchiveTooLargeException] if it expands past [maxDecompressedBytes].
  BundleArchive read(List<int> bytes) {
    final tar = decodeGzipBounded(bytes, maxBytes: maxDecompressedBytes);
    final archive = TarDecoder().decodeBytes(tar);

    String? manifestYaml;
    final files = <String, List<int>>{};
    final executable = <String>{};
    for (final file in archive) {
      if (!file.isFile) {
        continue;
      }

      final name = file.name;
      if (name == 'mold.yaml') {
        manifestYaml = utf8.decode(file.content as List<int>);
      } else if (name.startsWith('files/')) {
        final rel = name.substring('files/'.length);
        files[rel] = .from(file.content as List<int>);
        // 0o100 — owner-execute.
        if (file.mode & 64 != 0) {
          executable.add(rel);
        }
      }
    }

    if (manifestYaml == null) {
      throw const FormatException('Archive is missing mold.yaml.');
    }

    return BundleArchive(
      manifestYaml: manifestYaml,
      files: files,
      executable: executable,
    );
  }
}
