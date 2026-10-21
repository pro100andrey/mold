import '../util/bytes.dart';
import 'archive_reader.dart';

/// How two template archives differ in what they hold — never in how it is
/// compressed.
///
/// The question `pack --check` asks of a committed archive is whether it
/// would unpack to what the project now is. Comparing compressed bytes asks
/// a different one, and answers it wrongly whenever the compressor differs —
/// another OS, another SDK, another level — while the content is the same.
class ArchiveDiff {
  ArchiveDiff(BundleArchive committed, BundleArchive current)
    : manifestChanged = committed.manifestYaml != current.manifestYaml,
      added = [
        for (final path in current.files.keys)
          if (!committed.files.containsKey(path)) path,
      ],
      removed = [
        for (final path in committed.files.keys)
          if (!current.files.containsKey(path)) path,
      ],
      changed = [
        for (final MapEntry(key: path, value: bytes) in current.files.entries)
          if (committed.files[path] case final before?
              when !sameBytes(before, bytes))
            path,
      ],
      modeChanged = [
        for (final path in current.files.keys)
          if (committed.files.containsKey(path) &&
              committed.executable.contains(path) !=
                  current.executable.contains(path))
            path,
      ];

  /// Whether the embedded `mold.yaml` differs.
  final bool manifestChanged;

  /// Files the current archive has and the committed one lacks.
  final List<String> added;

  /// Files the committed archive has and the current one lacks.
  final List<String> removed;

  /// Files in both whose content differs.
  final List<String> changed;

  /// Files in both whose executable bit differs.
  final List<String> modeChanged;

  /// Whether the two hold the same thing.
  bool get isEmpty =>
      !manifestChanged &&
      added.isEmpty &&
      removed.isEmpty &&
      changed.isEmpty &&
      modeChanged.isEmpty;

  /// One phrase per kind of difference, for a message.
  List<String> describe() {
    String some(List<String> paths) {
      final shown = paths.take(3).join(', ');
      return paths.length > 3 ? '$shown and ${paths.length - 3} more' : shown;
    }

    final modes = '${modeChanged.length} with a different executable bit';

    return [
      if (manifestChanged) 'the manifest changed',
      if (changed.isNotEmpty) '${changed.length} changed (${some(changed)})',
      if (added.isNotEmpty) '${added.length} added (${some(added)})',
      if (removed.isNotEmpty) '${removed.length} removed (${some(removed)})',
      if (modeChanged.isNotEmpty) '$modes (${some(modeChanged)})',
    ];
  }
}
