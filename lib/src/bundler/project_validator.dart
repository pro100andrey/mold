import 'dart:io';

import 'package:path/path.dart' as p;

import '../manifest/manifest.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';
import 'file_classifier.dart';
import 'file_scanner.dart';

/// Input to the [ProjectValidator]: the source [dir] and its [manifest].
class ProjectInput {
  const ProjectInput({required this.dir, required this.manifest});

  /// The source project directory.
  final String dir;

  /// The manifest describing it.
  final Manifest manifest;
}

/// Validates the source project (pack phase): the directory exists and is
/// non-empty, and each `replaces` token actually occurs in it. Emits a
/// **warning** (not an error) when a token also appears inside larger words.
class ProjectValidator extends ValidatorBase<ProjectInput> {
  const ProjectValidator();

  static const dirNotFound = 'PROJECT_DIR_NOT_FOUND';
  static const dirEmpty = 'PROJECT_DIR_EMPTY';
  static const replacesNotFound = 'PROJECT_REPLACES_NOT_FOUND';
  static const partialOverlap = 'PROJECT_PARTIAL_OVERLAP';
  static const symlinkSkipped = 'PROJECT_SYMLINK_SKIPPED';

  @override
  String get phase => 'project';

  @override
  ValidationResult validate(ProjectInput input) {
    final dir = Directory(input.dir);
    if (!dir.existsSync()) {
      return ValidationResult([
        ValidationError(
          dirNotFound,
          'Source directory not found: ${input.dir}',
        ),
      ]);
    }

    // Validate exactly the files the Bundler will pack: same scanner, same
    // include/exclude filters, same symlink handling. Walking the directory
    // directly would validate against files that never reach the archive.
    final scan = FileScanner(
      include: input.manifest.include,
      exclude: input.manifest.exclude,
    ).scan(input.dir);
    final relPaths = scan.files;
    if (relPaths.isEmpty) {
      return ValidationResult([
        ValidationError(
          dirEmpty,
          'No files to pack in ${input.dir} (empty, or everything is '
          'excluded).',
        ),
      ]);
    }

    final haystack = _haystack(input.dir, input.manifest, relPaths);
    final issues = <ValidationError>[];
    for (final entry in scan.skippedLinks.entries) {
      issues.add(
        ValidationError.warning(
          symlinkSkipped,
          "Symlink '${entry.key}' is not packed: ${entry.value}.",
          field: entry.key,
        ),
      );
    }
    for (final variable in input.manifest.variables) {
      final token = variable.replaces;
      if (token == null || token.isEmpty) {
        continue;
      }

      if (!haystack.contains(token)) {
        issues.add(
          ValidationError(
            replacesNotFound,
            "Variable '${variable.name}': token '$token' does not occur in "
            'the project.',
            field: variable.name,
          ),
        );
      } else if (_hasAdjacentWordChar(haystack, token)) {
        issues.add(
          ValidationError.warning(
            partialOverlap,
            "Variable '${variable.name}': token '$token' also appears inside "
            'larger words; substitution may over-reach.',
            field: variable.name,
          ),
        );
      }
    }

    return ValidationResult(issues);
  }

  /// All relative paths plus the contents of text files, concatenated.
  String _haystack(String dir, Manifest manifest, List<String> relPaths) {
    final classifier = FileClassifier(
      extraBinary: manifest.binaryExtensions.toSet(),
    );
    final buffer = StringBuffer();
    for (final rel in relPaths) {
      buffer.writeln(rel);
      if (!classifier.isBinary(rel)) {
        try {
          buffer.writeln(File(p.join(dir, rel)).readAsStringSync());
        } on FileSystemException {
          // Unreadable file — skip its contents.
        } on FormatException {
          // Non-UTF-8 despite a text extension — skip its contents.
        }
      }
    }

    return buffer.toString();
  }

  /// Whether any occurrence of [token] in [hay] is adjacent to a word char,
  /// i.e. it appears as part of a longer identifier somewhere.
  bool _hasAdjacentWordChar(String hay, String token) {
    final word = RegExp(r'\w');
    for (var i = hay.indexOf(token); i != -1; i = hay.indexOf(token, i + 1)) {
      final before = i > 0 ? hay[i - 1] : '';
      final after = i + token.length < hay.length ? hay[i + token.length] : '';
      if (word.hasMatch(before) || (after.isNotEmpty && word.hasMatch(after))) {
        return true;
      }
    }
    
    return false;
  }
}
