import 'dart:io';

import 'package:path/path.dart' as p;

import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';

/// Validates the unpack destination (unpack phase): the parent directory
/// exists, the destination is free, and the parent is writable. Checks
/// short-circuit — a missing parent reports alone, since the rest can't be
/// probed.
class TargetValidator extends ValidatorBase<String> {
  const TargetValidator();

  static const parentNotFound = 'TARGET_PARENT_NOT_FOUND';
  static const occupied = 'TARGET_OCCUPIED';
  static const notWritable = 'TARGET_NOT_WRITABLE';

  @override
  String get phase => 'target';

  @override
  ValidationResult validate(String input) {
    final absolute = p.absolute(input);
    final parent = Directory(p.dirname(absolute));
    if (!parent.existsSync()) {
      return ValidationResult([
        ValidationError(
          parentNotFound,
          'Parent directory does not exist: ${parent.path}',
        ),
      ]);
    }

    final dir = Directory(input);
    final asFile = File(input);
    final occupiedDir = dir.existsSync() && dir.listSync().isNotEmpty;
    if (occupiedDir || asFile.existsSync()) {
      return ValidationResult([
        ValidationError(occupied, 'Target already exists: $input'),
      ]);
    }

    // When the target already exists (empty, so not `occupied`), it is the
    // directory files get written into — probing the parent would pass on a
    // read-only target and let writeAsStringSync throw uncaught later.
    final probeDir = dir.existsSync() ? dir : parent;
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

  /// Best-effort writability probe: create and delete a temp file in [dir].
  bool _canWrite(Directory dir) {
    final probe = File(p.join(dir.path, '.mold_write_probe'));
    try {
      probe
        ..writeAsStringSync('')
        ..deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
