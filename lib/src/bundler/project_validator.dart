import 'dart:io';

import 'package:path/path.dart' as p;

import '../manifest/manifest.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';
import 'file_classifier.dart';
import 'file_scanner.dart';

/// Which `replaces` tokens were seen while scanning, and which of them also
/// occurred inside a larger word.
class _TokenOccurrence {
  final Set<String> found = {};
  final Set<String> overlapping = {};
}

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
    // Built before the empty check: when every file turned out to be a skipped
    // symlink, these warnings are the explanation for the error below.
    final issues = <ValidationError>[
      for (final entry in scan.skippedLinks.entries)
        ValidationError.warning(
          symlinkSkipped,
          "Symlink '${entry.key}' is not packed: ${entry.value.message}.",
          field: entry.key,
        ),
    ];

    final relPaths = scan.files;
    if (relPaths.isEmpty) {
      return ValidationResult([
        ...issues,
        ValidationError(
          dirEmpty,
          'No files to pack in ${input.dir} (empty, or everything is '
          'excluded or skipped).',
        ),
      ]);
    }

    final tokens = <String, String>{
      for (final variable in input.manifest.variables)
        if (variable.replaces case final t? when t.isNotEmpty) variable.name: t,
    };
    final occurrence = _findTokens(input.dir, input.manifest, relPaths, tokens);

    for (final entry in tokens.entries) {
      final name = entry.key;
      final token = entry.value;
      if (!occurrence.found.contains(token)) {
        issues.add(
          ValidationError(
            replacesNotFound,
            "Variable '$name': token '$token' does not occur in the project.",
            field: name,
          ),
        );
      } else if (occurrence.overlapping.contains(token)) {
        issues.add(
          ValidationError.warning(
            partialOverlap,
            "Variable '$name': token '$token' also appears inside larger "
            'words; substitution may over-reach.',
            field: name,
          ),
        );
      }
    }

    return ValidationResult(issues);
  }

  /// Which [tokens] occur anywhere in the packed paths and text contents, and
  /// which of those also appear inside larger words.
  ///
  /// Scans file by file and stops as soon as every token is decided on both
  /// counts, so a large project is never concatenated into one string nor
  /// re-walked once per variable.
  _TokenOccurrence _findTokens(
    String dir,
    Manifest manifest,
    List<String> relPaths,
    Map<String, String> tokens,
  ) {
    final result = _TokenOccurrence();
    if (tokens.isEmpty) {
      return result;
    }
    final distinct = tokens.values.toSet();
    final classifier = FileClassifier(
      extraBinary: manifest.binaryExtensions.toSet(),
    );

    for (final rel in relPaths) {
      var chunk = '$rel\n';
      if (!classifier.isBinary(rel)) {
        try {
          chunk += File(p.join(dir, rel)).readAsStringSync();
        } on FileSystemException {
          // Unreadable file — skip its contents.
        } on FormatException {
          // Non-UTF-8 despite a text extension — skip its contents.
        }
      }

      for (final token in distinct) {
        if (result.overlapping.contains(token)) {
          continue; // Already decided on both counts.
        }
        if (chunk.contains(token)) {
          result.found.add(token);
          if (_hasAdjacentWordChar(chunk, token)) {
            result.overlapping.add(token);
          }
        }
      }
      if (result.overlapping.length == distinct.length) {
        break;
      }
    }

    return result;
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
