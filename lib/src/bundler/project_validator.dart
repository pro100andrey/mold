import 'dart:io';

import 'package:path/path.dart' as p;

import '../manifest/manifest.dart';
import '../unbundler/case_converter.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';
import 'file_classifier.dart';
import 'file_scanner.dart';

/// How often a token's casings matched, and how much of that was collateral —
/// a match sitting inside a longer identifier.
class _TokenStats {
  var _matches = 0;
  var _adjacent = 0;

  /// Enclosing identifier → how many of [adjacent] it accounts for.
  final Map<String, int> _collisions = {};

  /// Total occurrences of any derived casing.
  int get matches => _matches;

  /// How many of [matches] sit inside a longer word.
  int get adjacent => _adjacent;

  /// The share of matches that would rewrite part of a longer word.
  double get ratio => _matches == 0 ? 0 : _adjacent / _matches;

  /// Records one match, and the identifier enclosing it when there is one.
  void record({String? enclosing}) {
    _matches++;
    if (enclosing != null) {
      _adjacent++;
      _collisions[enclosing] = (_collisions[enclosing] ?? 0) + 1;
    }
  }

  /// The worst offenders, most frequent first, for the error message.
  String describe([int limit = 3]) {
    final sorted = _collisions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => '${e.key} (${e.value})').join(', ');
  }
}

/// Input to the [ProjectValidator]: the source [dir] and its [manifest].
class ProjectInput {
  const ProjectInput({required this.dir, required this.manifest});

  /// The source project directory.
  final String dir;

  /// The manifest describing it.
  final Manifest manifest;
}

/// Validates the source project (pack phase): the directory has files to pack,
/// and each `replaces` token occurs in a form substitution would actually
/// rewrite.
///
/// Overlap is measured as a **proportion**, not a yes/no. Substitution is
/// literal, so a token that is mostly a substring of other words corrupts the
/// project — measured at 95% collateral for `bin` and 84% for `app` on real
/// corpora, against 14% for a self-named project whose own filenames
/// legitimately extend it. A boolean cannot separate those; a ratio can.
class ProjectValidator extends ValidatorBase<ProjectInput> {
  const ProjectValidator();

  static const dirNotFound = 'PROJECT_DIR_NOT_FOUND';
  static const dirEmpty = 'PROJECT_DIR_EMPTY';
  static const replacesNotFound = 'PROJECT_REPLACES_NOT_FOUND';
  static const partialOverlap = 'PROJECT_PARTIAL_OVERLAP';
  static const symlinkSkipped = 'PROJECT_SYMLINK_SKIPPED';
  static const tokenTooGeneric = 'PROJECT_TOKEN_TOO_GENERIC';

  /// At or above this share of collateral matches, packing is refused.
  static const _errorRatio = 0.30;

  /// At or above this share, packing warns.
  static const _warnRatio = 0.05;

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
    final stats = _findTokens(input.dir, input.manifest, relPaths, tokens);

    for (final entry in tokens.entries) {
      final name = entry.key;
      final token = entry.value;
      final s = stats[token]!;

      if (s.matches == 0) {
        issues.add(
          ValidationError(
            replacesNotFound,
            "Variable '$name': token '$token' does not occur in the project.",
            field: name,
          ),
        );
        continue;
      }

      final percent = (s.ratio * 100).round();
      if (s.ratio >= _errorRatio) {
        issues.add(
          ValidationError(
            tokenTooGeneric,
            "Variable '$name': token '$token' matches ${s.matches} times; "
            '${s.adjacent} ($percent%) inside longer words: ${s.describe()}. '
            'Substituting it would rewrite those too — pick a more '
            'distinctive token, or replace these sites with explicit '
            'extra_substitutions.',
            field: name,
          ),
        );
      } else if (s.ratio >= _warnRatio) {
        issues.add(
          ValidationError.warning(
            partialOverlap,
            "Variable '$name': token '$token' matches ${s.matches} times; "
            '${s.adjacent} ($percent%) inside longer words: ${s.describe()}. '
            'Substitution may over-reach.',
            field: name,
          ),
        );
      }
    }

    return ValidationResult(issues);
  }

  /// Counts, per token, how often any of its **derived casings** occurs in the
  /// packed paths and text, and how many of those sit inside a longer word.
  ///
  /// Searching the raw `replaces` string was a false-negative the size of the
  /// casing expansion: `replaces: my_app` against a project containing
  /// `MyApplication` and `MY_APPENDIX` validated clean and then corrupted both.
  /// The needles come from `CaseConverter.replacements`, the substitutor's own
  /// source of truth, so the check cannot drift from what substitution does.
  ///
  /// The whole corpus is scanned — a ratio needs every match, so there is no
  /// early exit.
  ///
  /// The manifest file itself is skipped: its `replaces:` line is a
  /// declaration, not evidence that the project uses the token.
  Map<String, _TokenStats> _findTokens(
    String dir,
    Manifest manifest,
    List<String> relPaths,
    Map<String, String> tokens,
  ) {
    final stats = {for (final t in tokens.values) t: _TokenStats()};
    if (tokens.isEmpty) {
      return stats;
    }

    const converter = CaseConverter();
    final casings = {
      for (final token in tokens.values)
        token: converter.replacements(token, token).keys.toSet(),
    };
    final classifier = FileClassifier(
      extraBinary: manifest.binaryExtensions.toSet(),
    );
    final manifestPath = manifest.path;
    final excluded = manifestPath == null
        ? null
        : p.canonicalize(manifestPath);

    for (final rel in relPaths) {
      if (excluded != null && p.canonicalize(p.join(dir, rel)) == excluded) {
        continue;
      }

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

      for (final entry in casings.entries) {
        final target = stats[entry.key]!;
        for (final casing in entry.value) {
          _count(chunk, casing, target);
        }
      }
    }

    return stats;
  }

  /// Tallies every occurrence of [needle] in [hay] into [into], recording the
  /// enclosing identifier whenever the match is part of a longer word.
  void _count(String hay, String needle, _TokenStats into) {
    final word = RegExp(r'\w');
    for (var i = hay.indexOf(needle); i != -1; i = hay.indexOf(needle, i + 1)) {
      final end = i + needle.length;
      final before = i > 0 && word.hasMatch(hay[i - 1]);
      final after = end < hay.length && word.hasMatch(hay[end]);
      if (!before && !after) {
        into.record();
        continue;
      }

      // Expand outward to name the identifier this match is buried in.
      var start = i;
      while (start > 0 && word.hasMatch(hay[start - 1])) {
        start--;
      }
      var stop = end;
      while (stop < hay.length && word.hasMatch(hay[stop])) {
        stop++;
      }
      into.record(enclosing: hay.substring(start, stop));
    }
  }
}
