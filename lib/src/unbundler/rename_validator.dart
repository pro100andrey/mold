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

  @override
  String get phase => 'rename';

  /// Validates the `from` → `to` mapping of every archive entry.
  @override
  ValidationResult validate(Map<String, String> input) {
    // Keyed by destination, insertion-ordered, so the message lists the
    // colliding sources in archive order and is reproducible.
    final sources = <String, List<String>>{};
    input.forEach((from, to) => (sources[to] ??= []).add(from));

    return ValidationResult([
      for (final entry in sources.entries)
        if (entry.value.length > 1)
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
