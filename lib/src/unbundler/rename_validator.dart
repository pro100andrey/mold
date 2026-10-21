import '../archive/archive_path.dart';
import '../bundler/shipping_checks.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';

/// Validates the planned path renames (unpack phase): no two archive entries
/// may land on the same path.
///
/// Substitution rewrites paths, and nothing stops two distinct entries from
/// being rewritten to one destination — a `path_renames` pair pointing at the
/// same target, or a `replaces` token whose casings converge, as `my_app.txt`
/// and `my-app.txt` both do under a single-word value. The writer would then
/// create the file twice and the last entry would win, so the archive would
/// unpack with fewer files than it holds.
///
/// Silently, and that is the point of this phase: the loss is invisible in the
/// result, and the surviving file is whichever the archive happened to list
/// last. A template that cannot round-trip its own files must not be unpacked
/// at all.
class RenameValidator extends ValidatorBase<Map<String, String>> {
  const RenameValidator();

  static const collision = 'RENAME_COLLISION';
  static const unsafePath = 'RENAME_UNSAFE_PATH';
  static const caseCollision = 'RENAME_CASE_COLLISION';

  @override
  String get phase => 'rename';

  /// Validates the `from` → `to` mapping of every archive entry.
  ///
  /// Also checks each destination stays inside the target. `ArchiveValidator`
  /// checks the paths the archive holds; substitution then rewrites them, and
  /// a `path_renames` value — rendered from a variable at unpack — can turn a
  /// contained path into `../x`. Checked here, after substitution, so no
  /// rename can write outside the target directory.
  @override
  ValidationResult validate(Map<String, String> input) {
    final unsafe = [
      for (final MapEntry(key: from, value: to) in input.entries)
        if (!isContainedArchivePath(to))
          ValidationError(
            unsafePath,
            "Archive entry 'files/$from' is renamed to '$to', which is not a "
            'contained relative path (traversal, absolute, or '
            'drive-qualified).',
            field: from,
          ),
    ];
    if (unsafe.isNotEmpty) {
      return ValidationResult(unsafe);
    }

    // Two passes so the common case — every destination distinct — allocates
    // one Set rather than a growable List per file. Only destinations that
    // actually collide get a list built for them.
    final seen = <String>{};
    final collided = <String>{};
    for (final to in input.values) {
      if (!seen.add(to)) {
        collided.add(to);
      }
    }
    // Destinations equal but for case are one file on macOS and Windows.
    // A warning, not an error: on a case-sensitive filesystem both survive,
    // and pack already warned if the template itself held such a pair —
    // this catches the ones renaming creates.
    final caseIssues = [
      for (final group in caseCollisions(input.values.toSet()))
        if (!group.any(collided.contains))
          ValidationError.warning(
            caseCollision,
            '${group.join(', ')} differ only in case after renaming; on a '
            'case-insensitive filesystem only the last survives.',
            field: group.first,
          ),
    ];
    if (collided.isEmpty) {
      return ValidationResult(caseIssues);
    }

    // Insertion-ordered, so the message lists the sources in archive order and
    // the same archive always produces the same message.
    final sources = <String, List<String>>{};
    input.forEach((from, to) {
      if (collided.contains(to)) {
        (sources[to] ??= []).add(from);
      }
    });

    return ValidationResult([
      ...caseIssues,
      for (final entry in sources.entries)
        ValidationError(
          collision,
          '${entry.value.length} archive entries would all be written to '
          "'${entry.key}': ${entry.value.join(', ')}. Only the last would "
          'survive. Give them distinct names, or use path_renames to pin '
          'one of them.',
          field: entry.key,
        ),
    ]);
  }
}
