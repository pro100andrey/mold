import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../manifest/content_policy.dart';
import '../manifest/manifest.dart';
import '../unbundler/case_converter.dart';
import '../unbundler/case_transform.dart';
import '../unbundler/casing_needle.dart';
import '../unbundler/substitutor.dart';
import '../unbundler/unpack_stamp.dart';
import '../util/sample.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import '../validation/validator_base.dart';
import 'file_scanner.dart';
import 'shipping_checks.dart';

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

  /// Spellings of the token no derived casing matches (`appTemplate`,
  /// `App Template`) → where they occur.
  final Map<String, _Occurrences> uncovered = {};

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

/// Where an uncovered spelling occurs: the files holding it, once per
/// occurrence, and whether in their content, their paths, or both — which
/// decides whether it needs `extra_substitutions`, `path_renames`, or both.
class _Occurrences {
  final List<String> files = [];
  var inContent = false;
  var inPaths = false;
}

/// A spelling of a variable's token that no derived casing covers, but
/// [transform] reproduces — so the `extra_substitutions` entry [suggestion]
/// renames it the way the template meant.
class UncoveredSpelling {
  const UncoveredSpelling({
    required this.variable,
    required this.spelling,
    required this.transform,
    required this.files,
    this.inContent = true,
    this.inPaths = false,
  });

  /// The variable whose token it spells.
  final String variable;

  /// The spelling, as it occurs.
  final String spelling;

  /// The transform producing it from the token.
  final CaseTransform transform;

  /// The files — or paths — it occurs in.
  final List<String> files;

  /// Whether it occurs in file content: [suggestion] belongs in
  /// `extra_substitutions`.
  final bool inContent;

  /// Whether it occurs in a path: [suggestion] belongs in `path_renames`,
  /// which is all that renames paths.
  final bool inPaths;

  /// The entry that renames it.
  Substitution get suggestion =>
      Substitution(from: spelling, to: '{{ $variable | ${transform.name} }}');
}

/// Receives an [UncoveredSpelling].
typedef SuggestionSink = void Function(UncoveredSpelling spelling);

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
/// Those numbers are from the casing-aware boundary rule in [CasingNeedle].
/// Before it, `_` counted as part of the word, which put `app` at 83%, `test`
/// at 95% and `runner` at 26% on the same project — and a self-named project
/// whose files extend its name with `_` (`app_template_test`) at 14% on a
/// real one.
class ProjectValidator extends ValidatorBase<ProjectInput> {
  const ProjectValidator({this.onSuggestion});

  /// Receives each `extra_substitutions` entry `PROJECT_UNCOVERED_CASING`
  /// suggests, as data rather than inside a message — what `mold init`
  /// offers to add.
  final SuggestionSink? onSuggestion;

  static const dirNotFound = 'PROJECT_DIR_NOT_FOUND';
  static const dirEmpty = 'PROJECT_DIR_EMPTY';
  static const replacesNotFound = 'PROJECT_REPLACES_NOT_FOUND';
  static const partialOverlap = 'PROJECT_PARTIAL_OVERLAP';
  static const symlinkSkipped = 'PROJECT_SYMLINK_SKIPPED';
  static const tokenTooGeneric = 'PROJECT_TOKEN_TOO_GENERIC';
  static const tokenInVerbatim = 'PROJECT_TOKEN_IN_VERBATIM';
  static const substitutionUnused = 'PROJECT_SUBSTITUTION_UNUSED';
  static const pathRenameUnused = 'PROJECT_PATH_RENAME_UNUSED';
  static const uncoveredCasing = 'PROJECT_UNCOVERED_CASING';
  static const secretSuspected = 'PROJECT_SECRET_SUSPECTED';
  static const pathNotPortable = 'PROJECT_PATH_NOT_PORTABLE';

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
  ///
  /// An unpack stamp at the root is never packed. It records one unpack into
  /// one directory — its values, its files, their digests — so a template
  /// carrying its author's would hand every later unpack the author's values
  /// and make it judge stale and edited files by the author's history. Only a
  /// stamp: a `.mold.json` of some other tool's is the project's own file, and
  /// leaving it out by its name alone dropped it from every unpack in silence.
  static ScanResult scanFor(String dir, Manifest manifest) => FileScanner(
    include: manifest.include,
    exclude: manifest.exclude,
    useGitignore: manifest.useGitignore,
    reserved: {if (_holdsStamp(dir)) UnpackStamp.fileName},
  ).scan(dir);

  static bool _holdsStamp(String dir) {
    final file = File(p.join(dir, UnpackStamp.fileName));
    try {
      return file.existsSync() &&
          UnpackStamp.tryParse(file.readAsStringSync()) != null;
    } on FileSystemException {
      return false; // Unreadable or not UTF-8: not a stamp mold wrote.
    }
  }

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

    issues.addAll(_portability(relPaths));

    final tokens = <String, String>{
      for (final variable in input.manifest.variables)
        if (variable.replaces case final t? when t.isNotEmpty) variable.name: t,
    };
    final search = _Search(input.manifest, tokens.values);
    _scanCorpus(input, relPaths, search, issues);

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
            '${sample(verbatim)}. Their paths are still renamed; their '
            'content is not (binary_extensions, no_substitute, or not UTF-8).',
            field: name,
          ),
        );
      }

      if (s.uncovered.isNotEmpty) {
        final (warning, fixable) = _uncovered(name, token, s.uncovered);
        issues.add(warning);
        fixable.forEach(onSuggestion ?? (_) {});
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

  /// The warning for spellings of [token] substitution will not reach, with
  /// the entries that would — and those entries as data, for
  /// [onSuggestion].
  ///
  /// An entry is suggested only where a transform reproduces the spelling
  /// exactly from the token, so pasting it renames that site the way the
  /// template meant; a spelling no transform produces (`app.template`) is
  /// named without a guess. A spelling in content goes under
  /// `extra_substitutions`, one in a path under `path_renames`: each list
  /// reaches only its own.
  static (ValidationError, List<UncoveredSpelling>) _uncovered(
    String name,
    String token,
    Map<String, _Occurrences> uncovered,
  ) {
    final spellings = uncovered.entries.toList()
      ..sort((a, b) => b.value.files.length.compareTo(a.value.files.length));
    final listed = [
      for (final MapEntry(key: spelling, value: where) in spellings)
        "'$spelling' (${where.files.length}: ${sample(where.files.toSet())})",
    ].join(', ');

    final fixable = <UncoveredSpelling>[];
    final unmatched = <String>[];
    for (final MapEntry(key: spelling, value: where) in spellings) {
      if (_transformFor(token, spelling) case final transform?) {
        fixable.add(
          UncoveredSpelling(
            variable: name,
            spelling: spelling,
            transform: transform,
            files: where.files.toSet().toList(),
            inContent: where.inContent,
            inPaths: where.inPaths,
          ),
        );
      } else {
        unmatched.add("'$spelling'");
      }
    }

    String entries(bool Function(UncoveredSpelling) where) => fixable
        .where(where)
        .map(
          (s) =>
              '  - from: "${s.suggestion.from}"\n'
              '    to: "${s.suggestion.to}"',
        )
        .join('\n');
    final content = entries((s) => s.inContent);
    final paths = entries((s) => s.inPaths);
    final advice = [
      if (content.isNotEmpty) 'extra_substitutions:\n$content',
      if (paths.isNotEmpty) 'path_renames:\n$paths',
    ];

    final warning = ValidationError.warning(
      uncoveredCasing,
      "Variable '$name': $listed spell token '$token' in a way no derived "
      'casing matches, so unpacking leaves them as they are.'
      '${advice.isEmpty ? '' : ' To rename them too, add to '
                '${advice.join('\nand to ')}'}'
      '${unmatched.isEmpty ? '' : '\nNo transform produces '
                '${unmatched.join(', ')}; give each a literal entry.'}',
      field: name,
    );

    return (warning, fixable);
  }

  /// The transform that spells [token] as [spelling] exactly, if any.
  static CaseTransform? _transformFor(String token, String spelling) =>
      CaseTransform.values
          .where((t) => t.spellsToken && t.apply(token) == spelling)
          .firstOrNull;

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
  ///
  /// The same pass looks for secrets, by name and in text — the one read of
  /// every file this validator makes.
  void _scanCorpus(
    ProjectInput input,
    List<String> relPaths,
    _Search search,
    List<ValidationError> issues,
  ) {
    void secret(String rel, String what) => issues.add(
      ValidationError.warning(
        secretSuspected,
        "'$rel' looks like $what. A template is shared, so it would ship "
        'with it — exclude it, unless it is a placeholder.',
        field: rel,
      ),
    );

    final policy = ContentPolicy(input.manifest);
    final manifestRel = _manifestRel(input);
    for (final rel in relPaths) {
      if (rel == manifestRel) {
        continue;
      }

      search.paths(rel);
      final byName = secretByName(rel);
      if (byName != null) {
        secret(rel, byName);
      }
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
        continue;
      }
      search.content(rel, text);
      if (byName == null) {
        if (secretInContent(text) case final what?) {
          secret(rel, 'it holds $what');
        }
      }
    }
  }

  /// Paths that cannot all exist on every platform the template may be
  /// unpacked on.
  static List<ValidationError> _portability(List<String> relPaths) => [
    for (final group in caseCollisions(relPaths))
      ValidationError.warning(
        pathNotPortable,
        '${group.join(', ')} differ only in case; on macOS and Windows they '
        'are one file, and unpacking there keeps only the last.',
        field: group.first,
      ),
    for (final rel in relPaths)
      if (windowsProblem(rel) case final problem?)
        ValidationError.warning(
          pathNotPortable,
          "'$rel' cannot be created on Windows: $problem.",
          field: rel,
        ),
  ];

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

  CasingNeedle? needle;

  /// The tokens deriving [needle] — more than one when they share a casing.
  List<_TokenStats>? stats;
  _RuleUse? rule;
}

/// Finds spellings of a token that no derived casing matches.
///
/// The four casings are not every way a name gets written. Flutter's own
/// template spells the project name in camelCase in the iOS and macOS bundle
/// identifier (`com.example.appTemplate`) and in Title Case in the macOS
/// product name — sites a rename silently misses, leaving the scaffolded app
/// shipping under its template's identity.
///
/// Matched case-insensitively with any one of ` ._-` or nothing between the
/// words, then every spelling that is a derived casing — or that an explicit
/// substitution already claims — is discarded. What is left is reported.
/// Single-word tokens are skipped: with no words to join, the only spellings
/// left are mixed-case oddities.
class _Variants {
  factory _Variants(Map<String, _TokenStats> stats, Set<String> covered) {
    const converter = CaseConverter();
    final byKey = <String, _TokenStats>{};
    final parts = <String>[];
    for (final MapEntry(key: token, value: s) in stats.entries) {
      final words = converter.splitWords(token);
      if (words.length < 2) {
        continue;
      }
      byKey.putIfAbsent(words.join(), () => s);
      parts.add(words.map(RegExp.escape).join('[ ._-]?'));
    }

    final firsts = [
      for (final token in stats.keys)
        if (converter.splitWords(token) case [final first, _, ...])
          for (final c in [first[0], first[0].toUpperCase()]) c,
    ];

    return _Variants._(
      parts.isEmpty
          ? null
          : RegExp(
              '${Substitutor.firstCharGuard(firsts)}'
              '(?:${parts.map((p) => '(?:$p)').join('|')})',
              caseSensitive: false,
            ),
      byKey,
      covered,
    );
  }

  _Variants._(this._pattern, this._byKey, this._covered);

  final RegExp? _pattern;

  /// Words joined, lowercase → the token they spell.
  final Map<String, _TokenStats> _byKey;

  /// Every derived casing; a match spelled like one is not a variant.
  final Set<String> _covered;

  static final _separators = RegExp('[ ._-]');

  /// Records the variants in [hay] — the file [rel], or its path — outside
  /// the [claimed] spans.
  void scan(
    String hay,
    String rel,
    List<int> claimed, {
    required bool inPath,
  }) {
    final pattern = _pattern;
    if (pattern == null) {
      return;
    }
    for (final m in pattern.allMatches(hay)) {
      final text = m[0]!;
      if (_covered.contains(text) ||
          _within(claimed, m.start, m.end) ||
          !_whole(hay, m.start, m.end)) {
        continue;
      }
      final s = _byKey[text.toLowerCase().replaceAll(_separators, '')];
      if (s != null) {
        final where = s.uncovered[text] ??= _Occurrences();
        where.files.add(rel);
        if (inPath) {
          where.inPaths = true;
        } else {
          where.inContent = true;
        }
      }
    }
  }

  static bool _within(List<int> spans, int start, int end) {
    for (var i = 0; i < spans.length; i += 2) {
      if (start >= spans[i] && end <= spans[i + 1]) {
        return true;
      }
    }

    return false;
  }

  /// Whether the match stands as a word: a letter or digit before it
  /// continues it only when the match opens lowercase (`myapptemplate`), one
  /// after it only when it is lowercase or a digit — a capital starts the
  /// next camel word (`appTemplateTests`).
  static bool _whole(String hay, int start, int end) {
    if (start > 0 &&
        CasingNeedle.isAlnum(hay.codeUnitAt(start - 1)) &&
        CasingNeedle.isLower(hay.codeUnitAt(start))) {
      return false;
    }
    if (end < hay.length) {
      final next = hay.codeUnitAt(end);
      if (CasingNeedle.isLower(next) || CasingNeedle.isDigit(next)) {
        return false;
      }
    }

    return true;
  }
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
    final needles = <String, (CasingNeedle, List<_TokenStats>)>{};
    for (final token in tokens) {
      final s = stats.putIfAbsent(token, _TokenStats.new);
      // A casing two tokens share is counted for both. Unpacking gives it to
      // the later variable — MANIFEST_CONFLICTING_TOKENS says so — but the
      // earlier token does occur, and crediting the later one alone failed
      // the pack with "does not occur in the project".
      for (final needle in CasingNeedle.casingsOf(token)) {
        final owners = (needles[needle.text] ??= (needle, [])).$2;
        if (!owners.contains(s)) {
          owners.add(s);
        }
      }
    }

    Map<String, _Site> sites(
      List<Substitution> rules,
      Map<String, _RuleUse> uses,
    ) {
      final out = {
        for (final MapEntry(key: text, value: (needle, owners))
            in needles.entries)
          text: _Site(needle: needle, stats: owners),
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
      variants: _Variants(stats, needles.keys.toSet()),
      needleStats: {
        for (final MapEntry(key: text, value: (_, owners)) in needles.entries)
          text: owners,
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
    required this._variants,
  });

  /// Per `replaces` token.
  final Map<String, _TokenStats> stats;

  final _Variants _variants;

  /// Per `extra_substitutions.from`.
  final Map<String, _RuleUse> contentRules;

  /// Per `path_renames.from`.
  final Map<String, _RuleUse> pathRules;

  final Map<String, _Site> _contentSites;
  final Map<String, _Site> _pathSites;
  final RegExp? _contentPattern;
  final RegExp? _pathPattern;
  final RegExp? _needlePattern;
  final Map<String, List<_TokenStats>> _needleStats;

  /// Whether there is nothing to look for at all.
  bool get isEmpty => _contentPattern == null && _pathPattern == null;

  /// Counts the matches in the packed path [rel].
  void paths(String rel) {
    final claimed = _tally(rel, _pathPattern, _pathSites);
    _variants.scan(rel, rel, claimed, inPath: true);
  }

  /// Counts the matches in the substituted text [text].
  void content(String rel, String text) {
    final claimed = _tally(text, _contentPattern, _contentSites);
    _variants.scan(text, rel, claimed, inPath: false);
  }

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
        ..._needleStats[m[0]!]!,
    };
    for (final s in found) {
      s.verbatimFiles.add(rel);
    }
  }

  /// Counts the matches of [pattern] in [hay]; returns the spans explicit
  /// substitutions claim, as start, end pairs.
  static List<int> _tally(
    String hay,
    RegExp? pattern,
    Map<String, _Site> sites,
  ) {
    if (pattern == null) {
      return const [];
    }
    final claimed = <int>[];
    for (final m in pattern.allMatches(hay)) {
      final site = sites[m[0]!]!;
      if (site.rule case final rule?) {
        rule.hits++;
        claimed
          ..add(m.start)
          ..add(m.end);
      }
      final needle = site.needle;
      if (needle != null) {
        for (final owner in site.stats!) {
          _record(hay, m.start, m.end, needle, owner);
        }
      }
    }

    return claimed;
  }

  /// Records one match of [needle] at [start]..[end] in [hay], with the
  /// enclosing identifier when the match is part of a longer word.
  ///
  /// What counts as "part of a longer word" is the needle's own casing — see
  /// [CasingNeedle]. Treating every `\w` as a continuation made `_` one, so
  /// `app_template_test` counted as over-reach for `replaces: app_template`
  /// although rewriting it to `my_app_test` is exactly the point.
  static void _record(
    String hay,
    int start,
    int end,
    CasingNeedle needle,
    _TokenStats into,
  ) {
    if (needle.isWholeAt(hay, start)) {
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
  static bool _isWord(int u) => CasingNeedle.isAlnum(u) || u == 0x5F;
}
