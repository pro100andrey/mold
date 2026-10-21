import 'dart:convert';
import 'dart:typed_data';

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
  ///
  /// Views into the decoded tar, not copies of it.
  final Map<String, Uint8List> files;

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
  /// Expects a valid archive — run `ArchiveValidator` first. Throws an
  /// [ArchiveTooLargeException] if it expands past [maxDecompressedBytes].
  BundleArchive read(List<int> bytes) {
    final tar = decodeGzipBounded(bytes, maxBytes: maxDecompressedBytes);

    return fromTar(TarDecoder().decodeBytes(tar));
  }

  /// Builds a [BundleArchive] from an already-decoded [archive] — the one
  /// `ArchiveValidator.inspect` hands back, so validating and reading decode
  /// once.
  BundleArchive fromTar(Archive archive) {
    String? manifestYaml;
    final files = <String, Uint8List>{};
    final executable = <String>{};
    for (final file in archive) {
      if (!file.isFile) {
        continue;
      }

      final name = file.name;
      if (name == 'mold.yaml') {
        manifestYaml = utf8.decode(file.content);
      } else if (name.startsWith('files/')) {
        final rel = name.substring('files/'.length);
        // A view into the tar, not a copy. `List<int>.from` made a boxed list
        // — eight bytes per byte of content — and was most of an unpack:
        // 536 ms and ~390 MB for a 48 MB template.
        files[rel] = file.content;
        // 0o100 — owner-execute.
        if (file.mode & 64 != 0) {
          executable.add(rel);
        }
      }
    }

    if (manifestYaml == null) {
      // ArchiveValidator reports a missing manifest before anything reads.
      throw StateError('Archive is missing mold.yaml.');
    }

    return BundleArchive(
      manifestYaml: manifestYaml,
      files: files,
      executable: executable,
    );
  }
}
