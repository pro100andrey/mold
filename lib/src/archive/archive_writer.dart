import 'dart:convert';

import 'package:archive/archive.dart';

/// Assembles the template archive: a gzipped tar laid out as `mold.yaml`
/// (the embedded manifest) plus a `files/` tree (the project verbatim).
///
/// **Memory.** The whole project is held in memory, and so are the tar and the
/// gzip built from it: measured at a 1140 MiB peak for a 221 MiB tree, about
/// 4x. That is inherent to returning the archive as bytes — which `pack
/// --diff`, the embeddable output formats and `unbundleBytes` all require —
/// combined with `package:archive`'s non-streaming encoders. Scoping the
/// intermediate `Archive` so it is collectable before gzip runs was tried and
/// measured at zero effect, so it is not done here.
///
/// Templates are source projects, so this is a bound worth knowing rather than
/// a problem in practice; packing a tree of many gigabytes would need a
/// streaming encoder writing straight to a file, and a different signature.
///
/// **Time.** gzip is most of a pack — about 590 ms of 1.3 s for a 48 MB
/// corpus at the default level. [compressionLevel] trades it for size; the
/// archive stays reproducible at any one level.
class ArchiveWriter {
  const ArchiveWriter({this.compressionLevel = defaultLevel});

  /// zlib's own default, a balance of speed and size.
  static const defaultLevel = 6;

  /// The gzip level, 0 (store) to 9 (smallest). Anything else is a
  /// [RangeError] from [write].
  final int compressionLevel;

  /// Tar mode for a regular file, and for one that is owner-executable.
  static const _regular = 420; // 0644
  static const _executable = 493; // 0755

  /// Tar mtime for every entry. A template's identity is its content, not the
  /// moment it was packed, and `package:archive` defaults the field to
  /// `DateTime.now()` — so leaving it unset makes two packs of the same tree
  /// differ in both bytes and length.
  static const _modTime = 0;

  /// Builds the gzipped tar bytes from the manifest [manifestYaml] and the
  /// captured [files] (relative path → bytes).
  ///
  /// Paths listed in [executable] are recorded with mode 0755, so a template's
  /// scripts and hooks survive a pack/unpack round trip; everything else gets
  /// 0644. Only the executable bit is carried — the rest of the source mode is
  /// deliberately not reproduced.
  ///
  /// Entry timestamps are fixed at the epoch rather than read from the clock,
  /// so packing the same tree twice yields identical bytes — what a `--format
  /// bytes` blob committed beside the code needs, and what a template archive
  /// under version control needs. Nothing reads them back: the reader drops
  /// them, and unpacking writes files fresh.
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

    // Checked here, not by an assert in the const constructor: release builds
    // drop asserts, and an out-of-range level would reach the encoder.
    RangeError.checkValueInInterval(compressionLevel, 0, 9, 'compressionLevel');
    final tar = TarEncoder().encode(archive);

    return const GZipEncoder().encodeBytes(tar, level: compressionLevel);
  }

  ArchiveFile _entry(String name, List<int> bytes, int mode) =>
      ArchiveFile(name, bytes.length, bytes)
        ..mode = mode
        ..lastModTime = _modTime;
}
