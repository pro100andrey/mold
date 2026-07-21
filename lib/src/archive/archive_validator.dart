import 'package:archive/archive.dart';

import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';
import 'archive_path.dart';

/// Validates raw archive bytes (unpack phase): a decodable gzip+tar that
/// contains the embedded `mold.yaml` and a `files/` tree, and whose entries all
/// stay inside that tree (no `..` traversal out of the target directory).
class ArchiveValidator extends ValidatorBase<List<int>> {
  const ArchiveValidator();

  static const invalid = 'ARCHIVE_INVALID';
  static const missingManifest = 'ARCHIVE_MISSING_MANIFEST';
  static const missingFiles = 'ARCHIVE_MISSING_FILES';
  static const unsafePath = 'ARCHIVE_UNSAFE_PATH';

  @override
  String get phase => 'archive';

  @override
  ValidationResult validate(List<int> input) {
    final Archive archive;
    try {
      final tar = const GZipDecoder().decodeBytes(input);
      archive = TarDecoder().decodeBytes(tar);
    } on Object {
      return ValidationResult([
        const ValidationError(invalid, 'Not a valid gzipped tar archive.'),
      ]);
    }

    final names = archive.files
        .where((f) => f.isFile)
        .map((f) => f.name)
        .toList(growable: false);

    final issues = <ValidationError>[];
    if (!names.contains('mold.yaml')) {
      issues.add(
        const ValidationError(
          missingManifest,
          'Archive is missing the embedded mold.yaml.',
        ),
      );
    }

    if (!names.any((n) => n.startsWith('files/'))) {
      issues.add(
        const ValidationError(
          missingFiles,
          'Archive is missing a files/ tree.',
        ),
      );
    }

    for (final name in names) {
      if (!name.startsWith('files/')) {
        continue;
      }

      final rel = name.substring('files/'.length);
      if (!isContainedArchivePath(rel)) {
        issues.add(
          ValidationError(
            unsafePath,
            "Archive entry '$name' is not a contained relative path "
            '(traversal, absolute, or drive-qualified).',
          ),
        );
      }
    }

    return ValidationResult(issues);
  }
}
