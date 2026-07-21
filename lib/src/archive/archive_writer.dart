import 'dart:convert';

import 'package:archive/archive.dart';

/// Assembles the template archive: a gzipped tar laid out as `mold.yaml`
/// (the embedded manifest) plus a `files/` tree (the project verbatim).
class ArchiveWriter {
  const ArchiveWriter();

  /// Tar mode for a regular file, and for one that is owner-executable.
  static const _regular = 420; // 0644
  static const _executable = 493; // 0755

  /// Builds the gzipped tar bytes from the manifest [manifestYaml] and the
  /// captured [files] (relative path → bytes).
  ///
  /// Paths listed in [executable] are recorded with mode 0755, so a template's
  /// scripts and hooks survive a pack/unpack round trip; everything else gets
  /// 0644. Only the executable bit is carried — the rest of the source mode is
  /// deliberately not reproduced.
  List<int> write({
    required String manifestYaml,
    required Map<String, List<int>> files,
    Set<String> executable = const {},
  }) {
    final archive = Archive()
      ..addFile(_entry('mold.yaml', utf8.encode(manifestYaml), _regular));
    for (final entry in files.entries) {
      archive.addFile(
        _entry(
          'files/${entry.key}',
          entry.value,
          executable.contains(entry.key) ? _executable : _regular,
        ),
      );
    }

    final tar = TarEncoder().encode(archive);

    return const GZipEncoder().encode(tar);
  }

  ArchiveFile _entry(String name, List<int> bytes, int mode) =>
      ArchiveFile(name, bytes.length, bytes)..mode = mode;
}
