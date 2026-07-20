import 'package:archive/archive.dart';

import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';

/// Validates raw archive bytes (unpack phase): a decodable gzip+tar that
/// contains the embedded `mold.yaml` and a `files/` tree.
class ArchiveValidator extends ValidatorBase<List<int>> {
  const ArchiveValidator();

  static const invalid = 'ARCHIVE_INVALID';
  static const missingManifest = 'ARCHIVE_MISSING_MANIFEST';
  static const missingFiles = 'ARCHIVE_MISSING_FILES';

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
    
    return ValidationResult(issues);
  }
}
