import 'dart:io';

import 'package:path/path.dart' as p;

import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';

/// Validates the unpack destination (unpack phase): it is, or can become, a
/// directory, it is free, and it is writable. Checks short-circuit — a target
/// that cannot be a directory reports alone, since the rest can't be probed.
///
/// Missing directories on the way to the target are fine: the unpack creates
/// them, like the target itself. Only a file in the way is refused — at the
/// target ([notDirectory]) or at one of its parents. Validating creates
/// nothing, so a dry run into a new nested directory checks the same things
/// the real unpack does.
///
/// With [overwrite], a non-empty directory is accepted: the unpack writes the
/// template's files over the same paths and leaves every other file alone.
/// A target that is a file is refused either way — there is no directory to
/// write into. What the template's files would land on is checked separately,
/// by [validateDestinations], once renaming has decided where they go.
class TargetValidator extends ValidatorBase<String> {
  const TargetValidator({this.overwrite = false});

  /// The target, or a directory on the way to it, is a file.
  static const notDirectory = 'TARGET_NOT_DIRECTORY';

  /// The target is a non-empty directory, and [overwrite] is off.
  static const occupied = 'TARGET_OCCUPIED';
  static const notWritable = 'TARGET_NOT_WRITABLE';
  static const pathConflict = 'TARGET_PATH_CONFLICT';

  /// Whether a non-empty target directory is written into rather than refused.
  final bool overwrite;

  @override
  String get phase => 'target';

  @override
  ValidationResult validate(String input) {
    final absolute = p.absolute(input);

    // The target itself, then each parent up to the first that exists: the
    // directories the unpack will create, and the one it creates them in.
    var existing = absolute;
    var type = FileSystemEntity.typeSync(existing);
    while (type == .notFound && p.dirname(existing) != existing) {
      existing = p.dirname(existing);
      type = FileSystemEntity.typeSync(existing);
    }
    if (type != .directory) {
      final what = existing == absolute
          ? 'Target already exists and is a file, not a directory: $input'
          : 'Cannot create target $input: $existing is a file, not a '
                'directory.';
      return ValidationResult([ValidationError(notDirectory, what)]);
    }

    final dir = Directory(input);
    if (!overwrite && existing == absolute && dir.listSync().isNotEmpty) {
      return ValidationResult([
        ValidationError(
          occupied,
          'Target already exists and is not empty: $input; only an '
          'overwrite unpack writes into one.',
        ),
      ]);
    }

    // When the target already exists, it is the directory files get written
    // into — probing its parent would pass on a read-only target and let
    // writeAsStringSync throw uncaught later. When it does not, the first
    // existing parent is where the unpack creates the missing directories.
    final probeDir = Directory(existing);
    if (!_canWrite(probeDir)) {
      return ValidationResult([
        ValidationError(
          notWritable,
          'No write permission for: ${probeDir.path}',
        ),
      ]);
    }

    return .ok();
  }

  /// Checks that each of [relPaths] can be written under [targetDir] as a
  /// regular file, before anything is.
  ///
  /// Only an occupied target can fail this — into an empty one, every path is
  /// free — so it runs for [overwrite] alone. Each path conflicts when:
  ///
  /// - it is an existing directory, so a file cannot replace it;
  /// - one of its parents is an existing file, so the directory it needs
  ///   cannot be made;
  /// - it, or one of its parents inside [targetDir], is a symlink. Writing
  ///   through one would land outside the target, and keeping every write
  ///   inside it is a guarantee the archive validator already makes about
  ///   entry paths; an occupied target must not be the way around it.
  ///
  /// Checked up front because each of these would otherwise fail partway
  /// through the writes, after files were already replaced.
  ValidationResult validateDestinations(
    String targetDir,
    Iterable<String> relPaths,
  ) {
    // Parent directories are shared by most entries; stat each once.
    final types = <String, FileSystemEntityType>{};
    FileSystemEntityType typeOf(String path) => types.putIfAbsent(
      path,
      () => FileSystemEntity.typeSync(path, followLinks: false),
    );

    final issues = <ValidationError>[];
    for (final rel in relPaths) {
      final segments = p.posix.split(rel);
      var current = targetDir;
      String? problem;
      for (var i = 0; i < segments.length && problem == null; i++) {
        current = p.join(current, segments[i]);
        final last = i == segments.length - 1;
        final type = typeOf(current);
        if (type == .notFound) {
          break;
        }

        final shown = p.posix.joinAll(segments.take(i + 1));
        if (type == .link) {
          problem = "'$shown' is a symlink; mold does not write through one";
        } else if (last && type == .directory) {
          problem = "'$shown' is a directory";
        } else if (!last && type != .directory) {
          problem = "'$shown' is a file, but the template puts files under it";
        }
      }

      if (problem != null) {
        issues.add(
          ValidationError(
            pathConflict,
            "Cannot write '$rel' into $targetDir: $problem.",
            field: rel,
          ),
        );
      }
    }

    return ValidationResult(issues);
  }

  /// Best-effort writability probe: create and delete a temp entry in [dir].
  ///
  /// The name is unique per probe, so the probe cannot clobber a file the user
  /// already has in a non-empty target — a fixed name would have overwritten
  /// one called that, then deleted it.
  bool _canWrite(Directory dir) {
    final Directory probe;
    try {
      probe = dir.createTempSync('.mold_write_probe_');
    } on FileSystemException {
      return false;
    }
    // Deleted in a separate step, and a failure here does not make the
    // directory unwritable — the create above already proved it is. Leaving
    // the probe behind would make the target non-empty, so the next run would
    // report TARGET_OCCUPIED instead of the real problem.
    try {
      probe.deleteSync();
    } on FileSystemException {
      // Best-effort; the verdict stands on the create.
    }

    return true;
  }
}
