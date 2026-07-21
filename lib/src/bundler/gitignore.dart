import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// One `.gitignore` line, translated to the globs that implement it.
///
/// A list of globs rather than one brace-alternation pattern: a legal filename
/// may contain `,` or `{`, which would have to be escaped inside `{a,b}` and is
/// easy to get subtly wrong.
class _Rule {
  const _Rule(this.globs, {required this.negated, required this.source});

  final List<Glob> globs;

  /// A `!` rule, which *un*-ignores a path that an earlier rule caught.
  final bool negated;

  /// The original line, for diagnostics.
  final String source;

  bool matches(String rel) => globs.any((g) => g.matches(rel));
}

/// The `.gitignore` rules of a project tree, as a single ordered matcher.
///
/// Implements the subset of the format that appears in practice: nested
/// `.gitignore` files scoped to their own directory, `!` negation, `/`
/// anchoring, trailing-`/` directory-only rules, and `#` comments. Evaluation
/// is **last match wins**, as in git.
///
/// Translation to `package:glob` has one trap worth naming: `**/` does not
/// match at depth zero, so `Glob('**/*.log')` misses a root-level `a.log`. An
/// unanchored rule therefore compiles to *two* globs, with and without the
/// `**/` prefix.
class GitignoreRules {
  const GitignoreRules._(this._rules);

  /// Rules that ignore nothing.
  const GitignoreRules.empty() : _rules = const [];

  /// Reads every `.gitignore` under [rootDir], shallowest first.
  ///
  /// Order matters: git lets a deeper file override a shallower one, and a
  /// later line override an earlier one. Sorting by depth and keeping line
  /// order reproduces that with a single last-match-wins pass.
  factory GitignoreRules.load(String rootDir) {
    final files = <String>[];
    final root = Directory(rootDir);
    if (!root.existsSync()) {
      return const GitignoreRules.empty();
    }

    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is File && p.basename(entity.path) == '.gitignore') {
        files.add(entity.path);
      }
    }
    files.sort((a, b) {
      final byDepth = p.split(a).length.compareTo(p.split(b).length);
      return byDepth != 0 ? byDepth : a.compareTo(b);
    });

    final rules = <_Rule>[
      // git never tracks its own directory and never lists it in .gitignore,
      // so nothing would exclude it otherwise.
      _Rule(
        [Glob('.git/**'), Glob('**/.git/**')],
        negated: false,
        source: '.git/',
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

  final List<_Rule> _rules;

  /// Whether any rule was loaded.
  bool get isEmpty => _rules.isEmpty;

  /// Whether [relPath] — POSIX-separated, relative to the project root — is
  /// ignored. The last rule to match decides, so a `!` rule can rescue a file
  /// an earlier rule caught.
  bool isIgnored(String relPath) {
    var ignored = false;
    for (final rule in _rules) {
      if (rule.matches(relPath)) {
        ignored = !rule.negated;
      }
    }
    return ignored;
  }

  /// Every reading of [pattern] where each `**/` segment matches zero or more
  /// directories.
  ///
  /// `package:glob` treats `**/` as *one or more*, so `a/**/b` misses `a/b`.
  /// gitignore means zero or more, and the gap is not only at the start of a
  /// pattern: macOS's stock `**/Flutter/ephemeral/` scoped to `macos/` becomes
  /// `macos/**/Flutter/ephemeral`, which silently skipped the very files it
  /// exists for. Each occurrence is therefore expanded both ways.
  static List<String> _expandDoubleStars(String pattern) {
    if (!pattern.contains('**/')) {
      return [pattern];
    }
    final index = pattern.indexOf('**/');
    final head = pattern.substring(0, index);
    final tail = pattern.substring(index + 3);

    return [
      for (final rest in _expandDoubleStars(tail)) ...[
        '$head**/$rest',
        '$head$rest',
      ],
    ];
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
      if (pattern.isEmpty) {
        continue;
      }

      final dirOnly = pattern.endsWith('/');
      if (dirOnly) {
        pattern = pattern.substring(0, pattern.length - 1);
      }
      // A leading slash anchors to this file's directory; so does any interior
      // slash, per the format. A trailing slash alone does not.
      final anchored =
          pattern.startsWith('/') ||
          pattern.substring(0, pattern.length - 1).contains('/');
      if (pattern.startsWith('/')) {
        pattern = pattern.substring(1);
      }
      if (pattern.isEmpty) {
        continue;
      }

      // Unanchored rules match at any depth — including zero, which `**/`
      // alone does not cover.
      final bases = anchored
          ? _expandDoubleStars(pattern)
          : [
              ..._expandDoubleStars(pattern),
              ..._expandDoubleStars('**/$pattern'),
            ];
      final globs = <Glob>[];
      for (final base in bases) {
        final scoped = scope.isEmpty ? base : '$scope/$base';
        // Always match the directory's contents; also match the path itself
        // unless the rule is directory-only.
        globs.add(Glob('$scoped/**'));
        if (!dirOnly) {
          globs.add(Glob(scoped));
        }
      }
      rules.add(_Rule(globs, negated: negated, source: line));
    }

    return rules;
  }
}
