import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// One `.gitignore` line, translated to the globs that implement it.
///
/// A list of globs rather than one brace-alternation pattern: a legal filename
/// may contain `,` or `{`, which would have to be escaped inside `{a,b}` and is
/// easy to get subtly wrong.
///
/// The globs match a path **itself**, never its contents — descent is the
/// caller's job, walked component by component, which is how a rule on a
/// directory reaches everything beneath it.
class _Rule {
  const _Rule(this.globs, {required this.negated, required this.dirOnly});

  final List<Glob> globs;

  /// A `!` rule, which *un*-ignores a path an earlier rule caught.
  final bool negated;

  /// A trailing-slash rule, which matches directories but never files.
  final bool dirOnly;

  bool matches(String rel, {required bool isDirectory}) =>
      (!dirOnly || isDirectory) && globs.any((g) => g.matches(rel));
}

/// The `.gitignore` rules of a project tree, as a single ordered matcher.
///
/// Implements the subset of the format that appears in practice: nested
/// `.gitignore` files scoped to their own directory, `!` negation, `/`
/// anchoring, trailing-`/` directory-only rules, and `#` comments.
///
/// Evaluation walks a path component by component, deciding each prefix by
/// last-match-wins. That order is what makes negation behave like git's: once
/// a directory is excluded, git never descends into it, so a `!` rule beneath
/// an excluded directory cannot rescue anything. Testing the full path against
/// every rule instead would silently re-include those files.
///
/// Translation to `package:glob` has one trap worth naming: `**/` there means
/// *one or more* directories, while gitignore means *zero or more*. Every
/// occurrence is therefore expanded both ways — see [_expandDoubleStars].
class GitignoreRules {
  const GitignoreRules._(this._rules);

  /// Rules that ignore nothing.
  const GitignoreRules.empty() : _rules = const [];

  /// Builds the rules from the `.gitignore` files among [entities], each path
  /// interpreted relative to [rootDir].
  ///
  /// Takes an already-walked listing rather than walking itself: `FileScanner`
  /// has to enumerate the tree anyway, and a second recursive `listSync` over
  /// the same directories is pure duplicate I/O.
  ///
  /// Order matters — git lets a deeper file override a shallower one, and a
  /// later line override an earlier one — so files are sorted shallowest
  /// first and line order is preserved.
  factory GitignoreRules.fromListing(
    String rootDir,
    Iterable<FileSystemEntity> entities,
  ) {
    final files = [
      for (final e in entities)
        if (e is File && p.basename(e.path) == '.gitignore') e.path,
    ]..sort((a, b) {
      final byDepth = p.split(a).length.compareTo(p.split(b).length);
      return byDepth != 0 ? byDepth : a.compareTo(b);
    });

    final rules = <_Rule>[
      // git never tracks its own directory and never lists it in .gitignore,
      // so nothing would exclude it otherwise.
      _Rule(
        [Glob('.git'), Glob('**/.git')],
        negated: false,
        dirOnly: true,
      ),
    ];
    for (final file in files) {
      final scope = p.posix.joinAll(
        p.split(p.relative(p.dirname(file), from: rootDir)),
      );
      rules.addAll(
        _parse(File(file).readAsLinesSync(), scope == '.' ? '' : scope),
      );
    }

    return GitignoreRules._(rules);
  }

  /// Reads every `.gitignore` under [rootDir] by walking it.
  ///
  /// Convenience for callers that do not already have a listing;
  /// `FileScanner` uses [GitignoreRules.fromListing] instead.
  factory GitignoreRules.load(String rootDir) {
    final root = Directory(rootDir);
    if (!root.existsSync()) {
      return const GitignoreRules.empty();
    }

    return GitignoreRules.fromListing(
      rootDir,
      root.listSync(recursive: true, followLinks: false),
    );
  }

  final List<_Rule> _rules;

  /// Whether [relPath] — POSIX-separated, relative to the project root — is
  /// ignored.
  ///
  /// Each ancestor directory is decided before the file itself. An excluded
  /// directory ends the walk immediately: git does not descend into one, so
  /// nothing inside can be re-included by a later `!` rule.
  bool isIgnored(String relPath) {
    final parts = relPath.split('/');
    var prefix = '';
    for (var i = 0; i < parts.length; i++) {
      prefix = i == 0 ? parts[i] : '$prefix/${parts[i]}';
      final isLast = i == parts.length - 1;
      final ignored = _verdict(prefix, isDirectory: !isLast);
      if (isLast) {
        return ignored;
      }
      if (ignored) {
        return true;
      }
    }

    return false;
  }

  /// The last-match-wins verdict for a single path.
  bool _verdict(String path, {required bool isDirectory}) {
    var ignored = false;
    for (final rule in _rules) {
      if (rule.matches(path, isDirectory: isDirectory)) {
        ignored = !rule.negated;
      }
    }

    return ignored;
  }

  /// How many readings of one pattern the `**/` expansion may produce.
  ///
  /// Each `**/` doubles the list, so an unusual pattern with many of them
  /// would compile exponentially many globs, each tested against every file.
  /// Beyond this the pattern keeps its literal `**/` segments only — still
  /// correct for every path at depth one or more, just not for the
  /// zero-directory reading of the extra segments.
  static const _maxExpansions = 16;

  /// Every reading of [pattern] where each `**/` segment matches zero or more
  /// directories.
  ///
  /// `package:glob` treats `**/` as *one or more*, so `a/**/b` misses `a/b`.
  /// gitignore means zero or more, and the gap is not only at the start of a
  /// pattern: macOS's stock `**/Flutter/ephemeral/` scoped to `macos/` becomes
  /// `macos/**/Flutter/ephemeral`, which would silently skip the very files it
  /// exists for.
  static List<String> _expandDoubleStars(String pattern) {
    if (!pattern.contains('**/')) {
      return [pattern];
    }
    final index = pattern.indexOf('**/');
    final head = pattern.substring(0, index);
    final tail = pattern.substring(index + 3);

    final out = <String>[];
    for (final rest in _expandDoubleStars(tail)) {
      out.add('$head**/$rest');
      if (out.length < _maxExpansions) {
        out.add('$head$rest');
      }
    }

    return out;
  }

  static List<_Rule> _parse(List<String> lines, String scope) {
    final rules = <_Rule>[];
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }

      final negated = line.startsWith('!');
      var pattern = negated ? line.substring(1) : line;

      final dirOnly = pattern.endsWith('/');
      if (dirOnly) {
        pattern = pattern.substring(0, pattern.length - 1);
      }
      if (pattern.startsWith('/')) {
        pattern = pattern.substring(1);
      }
      // Checked before anything indexes into it: a line of `/` or `!/` leaves
      // nothing behind, and reading past the end of an empty pattern used to
      // throw RangeError out of the CLI as an unhandled error.
      if (pattern.isEmpty) {
        continue;
      }

      // A leading slash anchors to this file's directory; so does any interior
      // slash. A trailing slash alone does not, and has already been stripped.
      final anchored = line.startsWith('/') ||
          line.startsWith('!/') ||
          pattern.contains('/');

      // Unanchored rules match at any depth — including zero, which `**/`
      // alone does not cover.
      final bases = anchored
          ? _expandDoubleStars(pattern)
          : [
              ..._expandDoubleStars(pattern),
              ..._expandDoubleStars('**/$pattern'),
            ];
      rules.add(
        _Rule(
          [
            for (final base in bases)
              Glob(scope.isEmpty ? base : '$scope/$base'),
          ],
          negated: negated,
          dirOnly: dirOnly,
        ),
      );
    }

    return rules;
  }
}
