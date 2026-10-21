import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../manifest/content_policy.dart';
import '../manifest/manifest.dart';
import '../unbundler/case_converter.dart';
import '../unbundler/substitutor.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';
import 'file_scanner.dart';

/// How often a token's casings matched, and how much of that was collateral —
/// a match sitting inside a longer identifier.
class _TokenStats {
  var _matches = 0;
  var _adjacent = 0;

  /// Enclosing identifier → how many of [adjacent] it accounts for.
  final Map<String, int> _collisions = {};

  /// Packed files copied verbatim that hold one of the casings, in scan
  /// order. Not counted in [matches]: substitution never reaches them.
  final List<String> verbatimFiles = [];

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
  const ProjectInput({
    required this.dir,
    required this.manifest,
    this.scan,
    this.contents,
  });

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

  /// The bytes of the scanned files, keyed like [ScanResult.files], when the
  /// caller has already read them.
  ///
  /// Same reasoning as [scan]: `Bundler` reads every file to pack it, and the
  /// validator reading each one again — as a string, a second copy of the
  /// whole corpus — was duplicate I/O. A file missing from the map is read
  /// from disk.
  final Map<String, List<int>>? contents;
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
  static const tokenInVerbatim = 'PROJECT_TOKEN_IN_VERBATIM';
  static const substitutionUnused = 'PROJECT_SUBSTITUTION_UNUSED';
  static const pathRenameUnused = 'PROJECT_PATH_RENAME_UNUSED';

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
    final search = _Search(input.manifest, tokens.values);
    _scanCorpus(input, relPaths, search);

    for (final entry in tokens.entries) {
      final name = entry.key;
      final token = entry.value;
      final s = search.stats[token]!;

      final verbatim = s.verbatimFiles;
      if (verbatim.isNotEmpty) {
        issues.add(
          .warning(
            tokenInVerbatim,
            "Variable '$name': token '$token' occurs in ${verbatim.length} "
            'file(s) copied verbatim, which keep it as it is: '
            '${_sample(verbatim)}. Their paths are still renamed; their '
            'content is not (binary_extensions, no_substitute, or not UTF-8).',
            field: name,
          ),
        );
      }

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

    for (final rule in search.contentRules.values) {
      if (rule.hits == 0) {
        issues.add(
          .warning(
            substitutionUnused,
            "extra_substitutions: '${rule.from}' occurs in no substituted "
            'file, so the entry does nothing.',
            field: rule.from,
          ),
        );
      }
    }
    for (final rule in search.pathRules.values) {
      if (rule.hits == 0) {
        issues.add(
          .warning(
            pathRenameUnused,
            "path_renames: '${rule.from}' occurs in no packed path, so the "
            'entry does nothing.',
            field: rule.from,
          ),
        );
      }
    }

    return ValidationResult(issues);
  }

  /// The first few of [paths], for a message.
  static String _sample(List<String> paths, [int limit = 3]) {
    final shown = paths.take(limit).join(', ');

    return paths.length > limit
        ? '$shown and ${paths.length - limit} more'
        : shown;
  }

  /// Runs [search] over every packed path and every substituted text, the
  /// way unpacking will meet them.
  ///
  /// Paths are matched with the path rules (`path_renames`), text with the
  /// content rules (`extra_substitutions`), and a file copied verbatim is
  /// searched only to say that it keeps the token.
  ///
  /// The whole corpus is scanned — a ratio needs every match, so there is no
  /// early exit.
  ///
  /// The manifest file itself is skipped: its `replaces:` line is a
  /// declaration, not evidence that the project uses the token.
  void _scanCorpus(ProjectInput input, List<String> relPaths, _Search search) {
    if (search.isEmpty) {
      return;
    }

    final policy = ContentPolicy(input.manifest);
    final manifestRel = _manifestRel(input);
    for (final rel in relPaths) {
      if (rel == manifestRel) {
        continue;
      }

      search.paths(rel);
      if (policy.isVerbatimPath(rel)) {
        search.verbatim(rel, () => _read(input, rel));
        continue;
      }

      final bytes = _read(input, rel);
      if (bytes == null) {
        continue;
      }
      final text = policy.decode(rel, bytes);
      if (text == null) {
        search.verbatim(rel, () => bytes);
      } else {
        search.content(text);
      }
    }
  }

  /// The manifest's own path relative to the project, when it lies inside it.
  ///
  /// Resolved once: canonicalizing every packed path to compare it with the
  /// manifest's was a string-heavy call per file.
  static String? _manifestRel(ProjectInput input) {
    final manifestPath = input.manifest.path;
    if (manifestPath == null) {
      return null;
    }
    final root = p.canonicalize(input.dir);
    final manifest = p.canonicalize(manifestPath);
    if (!p.isWithin(root, manifest)) {
      return null;
    }

    return p.posix.joinAll(p.split(p.relative(manifest, from: root)));
  }

  static List<int>? _read(ProjectInput input, String rel) {
    final given = input.contents?[rel];
    if (given != null) {
      return given;
    }
    try {
      return File(p.join(input.dir, rel)).readAsBytesSync();
    } on FileSystemException {
      // Unreadable file — nothing to search.
      return null;
    }
  }
}

/// How often one explicit substitution's `from` was met.
class _RuleUse {
  _RuleUse(this.from);

  final String from;
  var hits = 0;
}

/// What one matched literal counts towards: a token casing, an explicit
/// substitution, or — when an `extra_substitutions.from` equals a derived
/// casing — both.
class _Site {
  _Site({this.needle, this.stats});

  _Needle? needle;
  _TokenStats? stats;
  _RuleUse? rule;
}

/// The token check's matcher: every literal substitution would act on, in
/// one alternation per side, so it meets the corpus exactly as unpacking
/// will.
///
/// One pattern rather than an `indexOf` loop per casing. The loop scanned
/// every text once per casing and was most of the pack time — about 600 ms of
/// 1.3 s on a 48 MB corpus, against about 110 ms for the alternation. And the
/// alternation is the substitutor's own (longest first, non-overlapping), so
/// the explicit substitutions take part too: a site an `extra_substitutions`
/// entry claims is no longer counted against the token, which is the remedy
/// the too-generic error recommends — and which used to change nothing.
class _Search {
  factory _Search(Manifest manifest, Iterable<String> tokens) {
    final stats = <String, _TokenStats>{};
    final needles = <String, (_Needle, _TokenStats)>{};
    for (final token in tokens) {
      final s = stats.putIfAbsent(token, _TokenStats.new);
      // A later variable wins a shared casing, as in the substitution table.
      for (final needle in _Needle.casingsOf(token)) {
        needles[needle.text] = (needle, s);
      }
    }

    Map<String, _Site> sites(
      List<Substitution> rules,
      Map<String, _RuleUse> uses,
    ) {
      final out = {
        for (final MapEntry(key: text, value: (needle, s)) in needles.entries)
          text: _Site(needle: needle, stats: s),
      };
      for (final rule in rules) {
        final use = uses.putIfAbsent(rule.from, () => _RuleUse(rule.from));
        (out[rule.from] ??= _Site()).rule = use;
      }

      return out;
    }

    final contentRules = <String, _RuleUse>{};
    final pathRules = <String, _RuleUse>{};
    final contentSites = sites(manifest.extraSubstitutions, contentRules);
    final pathSites = sites(manifest.pathRenames, pathRules);

    return _Search._(
      stats: stats,
      contentRules: contentRules,
      pathRules: pathRules,
      contentSites: contentSites,
      pathSites: pathSites,
      contentPattern: Substitutor.alternation(contentSites.keys),
      pathPattern: Substitutor.alternation(pathSites.keys),
      needlePattern: Substitutor.alternation(needles.keys),
      needleStats: {
        for (final MapEntry(key: text, value: (_, s)) in needles.entries)
          text: s,
      },
    );
  }

  _Search._({
    required this.stats,
    required this.contentRules,
    required this.pathRules,
    required this._contentSites,
    required this._pathSites,
    required this._contentPattern,
    required this._pathPattern,
    required this._needlePattern,
    required this._needleStats,
  });

  /// Per `replaces` token.
  final Map<String, _TokenStats> stats;

  /// Per `extra_substitutions.from`.
  final Map<String, _RuleUse> contentRules;

  /// Per `path_renames.from`.
  final Map<String, _RuleUse> pathRules;

  final Map<String, _Site> _contentSites;
  final Map<String, _Site> _pathSites;
  final RegExp? _contentPattern;
  final RegExp? _pathPattern;
  final RegExp? _needlePattern;
  final Map<String, _TokenStats> _needleStats;

  /// Whether there is nothing to look for at all.
  bool get isEmpty => _contentPattern == null && _pathPattern == null;

  /// Counts the matches in the packed path [rel].
  void paths(String rel) => _tally(rel, _pathPattern, _pathSites);

  /// Counts the matches in the substituted text [text].
  void content(String text) => _tally(text, _contentPattern, _contentSites);

  /// Notes which tokens the verbatim file [rel] holds.
  ///
  /// Searched as Latin-1, which maps each byte to one character: the casings
  /// are ASCII, so a match is a byte-for-byte occurrence whatever the file's
  /// encoding, and decoding cannot fail. [bytes] is only called when there is
  /// a token to look for.
  void verbatim(String rel, List<int>? Function() bytes) {
    final pattern = _needlePattern;
    if (pattern == null) {
      return;
    }
    final data = bytes();
    if (data == null) {
      return;
    }

    final found = <_TokenStats>{
      for (final m in pattern.allMatches(latin1.decode(data)))
        _needleStats[m[0]!]!,
    };
    for (final s in found) {
      s.verbatimFiles.add(rel);
    }
  }

  static void _tally(String hay, RegExp? pattern, Map<String, _Site> sites) {
    if (pattern == null) {
      return;
    }
    for (final m in pattern.allMatches(hay)) {
      final site = sites[m[0]!]!;
      site.rule?.hits++;
      final needle = site.needle;
      if (needle != null) {
        _record(hay, m.start, m.end, needle, site.stats!);
      }
    }
  }

  /// Records one match of [needle] at [start]..[end] in [hay], with the
  /// enclosing identifier when the match is part of a longer word.
  ///
  /// What counts as "part of a longer word" is the needle's own casing — see
  /// [_Needle]. Treating every `\w` as a continuation made `_` one, so
  /// `app_template_test` counted as over-reach for `replaces: app_template`
  /// although rewriting it to `my_app_test` is exactly the point.
  static void _record(
    String hay,
    int start,
    int end,
    _Needle needle,
    _TokenStats into,
  ) {
    final before =
        start > 0 && needle.continuesBefore(hay.codeUnitAt(start - 1));
    final after =
        end < hay.length && needle.continuesAfter(hay.codeUnitAt(end));
    if (!before && !after) {
      into.record();
      return;
    }

    // Expand outward to name the identifier this match is buried in.
    var from = start;
    while (from > 0 && _isWord(hay.codeUnitAt(from - 1))) {
      from--;
    }
    var to = end;
    while (to < hay.length && _isWord(hay.codeUnitAt(to))) {
      to++;
    }

    into.record(enclosing: hay.substring(from, to));
  }

  /// `\w`, on a code unit.
  static bool _isWord(int u) => _Needle._isAlnum(u) || u == 0x5F;
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
