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
  const ProjectInput({required this.dir, required this.manifest, this.scan});

  /// The source project directory.
  final String dir;

  /// The manifest describing it.
  final Manifest manifest;

  /// An already-performed scan of [dir], when the caller has one.
  ///
  /// The validator scans in order to validate exactly the files that get
  /// packed, and `Bundler` then needs the very same scan to read them. Letting
  /// it hand the result over turns two full tree walks — each re-reading and
  /// re-compiling every `.gitignore` — into one; on a project of 1000 packed
  /// and 2000 ignored files the duplicate walk was about 40% of pack time.
  ///
  /// Null means "scan it yourself", which is what a caller validating a
  /// directory it has not touched does.
  final ScanResult? scan;
}

/// Validates the source project (pack phase): the directory has files to pack,
/// and each `replaces` token occurs in a form substitution would actually
/// rewrite.
///
/// Overlap is measured as a **proportion**, not a yes/no. Substitution is
/// literal, so a token that is mostly a substring of other words corrupts the
/// project — on a fresh `flutter create` project (Flutter 3.47), 75%
/// collateral for `bin`, 73% for `test` and 65% for `app`, against under 5%
/// for `runner` and for the project's own name. A boolean cannot separate
/// those; a ratio can.
///
/// Those numbers are from the casing-aware boundary rule in [_Needle]. Before
/// it, `_` counted as part of the word, which put `app` at 83%, `test` at 95%
/// and `runner` at 26% on the same project — and a self-named project whose
/// files extend its name with `_` (`app_template_test`) at 14% on a real one.
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

  /// Scans [dir] with the filters [manifest] declares.
  ///
  /// The one place that maps a manifest onto a [FileScanner], so the validator,
  /// the bundler and `pack --dry-run` cannot end up filtering differently — a
  /// divergence would mean validating one set of files and packing another.
  static ScanResult scanFor(String dir, Manifest manifest) => FileScanner(
    include: manifest.include,
    exclude: manifest.exclude,
    useGitignore: manifest.useGitignore,
  ).scan(dir);

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
    final scan = input.scan ?? scanFor(input.dir, input.manifest);
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
          .warning(
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

    final casings = {
      for (final token in tokens.values) token: _Needle.casingsOf(token),
    };
    final classifier = FileClassifier(
      extraBinary: manifest.binaryExtensions.toSet(),
    );
    final manifestPath = manifest.path;
    final excluded = manifestPath == null ? null : p.canonicalize(manifestPath);

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
        for (final needle in entry.value) {
          _count(chunk, needle, target);
        }
      }
    }

    return stats;
  }

  /// One word character. Static because [_count] runs once per packed file per
  /// casing — a local rebuilt the pattern thousands of times per pack.
  static final _word = RegExp(r'\w');

  /// Tallies every occurrence of [needle] in [hay] into [into], recording the
  /// enclosing identifier whenever the match is part of a longer word.
  ///
  /// What counts as "part of a longer word" is the needle's own casing — see
  /// [_Needle]. Treating every `\w` as a continuation made `_` one,
  /// so `app_template_test` counted as over-reach for `replaces: app_template`
  /// although rewriting it to `my_app_test` is exactly the point.
  void _count(String hay, _Needle needle, _TokenStats into) {
    final text = needle.text;
    for (var i = hay.indexOf(text); i != -1; i = hay.indexOf(text, i + 1)) {
      final end = i + text.length;
      final before = i > 0 && needle.continuesBefore(hay.codeUnitAt(i - 1));
      final after =
          end < hay.length && needle.continuesAfter(hay.codeUnitAt(end));
      if (!before && !after) {
        into.record();
        continue;
      }

      // Expand outward to name the identifier this match is buried in.
      var start = i;
      while (start > 0 && _word.hasMatch(hay[start - 1])) {
        start--;
      }

      var stop = end;
      while (stop < hay.length && _word.hasMatch(hay[stop])) {
        stop++;
      }

      into.record(enclosing: hay.substring(start, stop));
    }
  }
}

/// One derived casing of a `replaces` token, and the rule for which adjacent
/// characters extend it into a longer word.
///
/// The rule follows the casing, because each casing has its own word
/// boundaries:
///
/// - **snake, kebab, SCREAMING** — joined by a separator, so a letter or digit
///   continues the word and anything else (`_`, `-`, `.`, `/`, …) ends it.
///   `_` ends a kebab needle too: both are segment separators, and a mixed
///   form like `my-app_test` (file names, generated identifiers) holds the
///   kebab token as a whole segment, which is what the rename should reach.
/// - **Pascal** — joined by capitals, so after the needle only a lowercase
///   letter continues it (`AppTemplateer`); a capital starts the next word
///   (`AppTemplateTest`). Before it, nothing does: the needle opens on a
///   capital, which is itself a word start in any camel or Pascal identifier
///   (`MyAppTemplate`, `HTTPAppTemplate`, `_AppTemplate`). A digit after a
///   needle that ends in a digit continues the number.
///
/// Real over-reach is still caught: `my_app` in `my_appendix`, `app` in
/// `application`, `MyApp` in `MyApplication`.
class _Needle {
  const _Needle(this.text, {required this.pascal});

  /// The casings of [token] substitution would rewrite, each with its rule.
  ///
  /// Claimed in `CaseConverter.replacements` order, so when two casings
  /// coincide (`app` is both snake and kebab) the needle keeps the rule of
  /// the casing the substitutor itself would credit with it.
  static List<_Needle> casingsOf(String token) {
    const converter = CaseConverter();
    final pascal = converter.toPascal(token);
    final keys = converter.replacements(token, token).keys;

    return [for (final key in keys) _Needle(key, pascal: key == pascal)];
  }

  /// The literal searched for.
  final String text;

  /// Whether [text] is the PascalCase form.
  final bool pascal;

  /// Whether the character [unit] just before a match extends it.
  bool continuesBefore(int unit) => !pascal && _isAlnum(unit);

  /// Whether the character [unit] just after a match extends it.
  bool continuesAfter(int unit) {
    if (!pascal) {
      return _isAlnum(unit);
    }

    return _isLower(unit) ||
        (_isDigit(unit) && _isDigit(text.codeUnitAt(text.length - 1)));
  }

  static bool _isAlnum(int u) => _isLower(u) || _isUpper(u) || _isDigit(u);
  static bool _isLower(int u) => u >= 0x61 && u <= 0x7A;
  static bool _isUpper(int u) => u >= 0x41 && u <= 0x5A;
  static bool _isDigit(int u) => u >= 0x30 && u <= 0x39;
}
