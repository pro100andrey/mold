import 'dart:convert';

import 'package:archive/archive.dart';

/// Assembles the template archive: a gzipped tar laid out as `mold.yaml`
/// (the embedded manifest) plus a `files/` tree (the project verbatim).
class ArchiveWriter {
  const ArchiveWriter();

  /// Builds the gzipped tar bytes from the manifest [manifestYaml] and the
  /// captured [files] (relative path → bytes).
  List<int> write({
    required String manifestYaml,
    required Map<String, List<int>> files,
  }) {
    final archive = Archive()
      ..addFile(_entry('mold.yaml', utf8.encode(manifestYaml)));
    for (final entry in files.entries) {
      archive.addFile(_entry('files/${entry.key}', entry.value));
    }
    
    final tar = TarEncoder().encode(archive);

    return const GZipEncoder().encode(tar);
  }

  ArchiveFile _entry(String name, List<int> bytes) =>
      ArchiveFile(name, bytes.length, bytes);
}
