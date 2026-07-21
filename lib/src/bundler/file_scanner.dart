import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'gitignore.dart';

/// Why a symlink that matched the filters was not packed.
///
/// A code rather than a sentence, so callers can tell the cases apart and
/// wording can change without breaking them.
enum SkipReason {
  /// Its target lies outside the source directory.
  outsideProject('its target is outside the project'),

  /// Its target is inside the project but the include/exclude globs drop it.
  filteredOut('its target is excluded from the template'),

  /// Its target does not exist.
  dangling('its target does not exist'),

  /// The link chain loops.
  circular('it is a circular link'),

  /// Resolution failed for some other reason (permissions, I/O).
  unresolvable('its target could not be resolved'),

  /// Its target is a directory.
  directory('its target is a directory');

  const SkipReason(this.message);

  /// Human-facing explanation, used to build the validation warning.
  final String message;
}

/// What a scan found.
class ScanResult {
  const ScanResult({
    required this.files,
    required this.executable,
    required this.skippedLinks,
    this.gitignored = 0,
  });

  /// Relative paths to pack, sorted for deterministic archives.
  final List<String> files;

  /// The subset of [files] that is owner-executable. Collected here because
  /// the scan already has to stat each entry, so the Bundler does not stat
  /// a second time or need to know about modes at all.
  final Set<String> executable;

  /// Symlinks that matched the filters but were not packed, with the reason.
  /// Reported as warnings by `ProjectValidator` — a dropped file must never
  /// be silent.
  final Map<String, SkipReason> skippedLinks;

  /// How many entries the project's `.gitignore` rules excluded. Reported by
  /// `mold pack --dry-run` so an implicit default stays inspectable.
  ///
  /// An ignored **directory** counts once, not once per file beneath it: the
  /// scan does not enter it, exactly as git does not, so the files inside were
  /// never enumerated and there is nothing there to count.
  final int gitignored;
}

/// What a descending scan has found so far, threaded through the recursion.
///
/// A mutable carrier rather than merged return values: the walk is depth-first
/// over an arbitrary tree, and combining four collections at every level would
/// copy them once per directory.
class _Accumulator {
  final files = <String>[];
  final executable = <String>{};
  final skipped = <String, SkipReason>{};

  /// Private, so `type_annotate_public_apis` does not demand an annotation
  /// that `omit_obvious_property_types` would then reject.
  var _gitignored = 0;

  /// How many entries the `.gitignore` rules rejected. A pruned directory
  /// counts once, not once per file inside it — the walk never enters it, so
  /// there is nothing inside it to count.
  int get gitignored => _gitignored;

  void countIgnored() => _gitignored++;
}

/// Walks a source directory and applies `include` / `exclude` glob filters,
/// yielding file paths relative to the source root (POSIX-separated).
///
/// A symlink pointing at a file **inside** the source directory *and* passing
/// the same filters is packed as its content (dereferenced), so the unpacked
/// project works without symlink privileges — Windows requires them — and so
/// substitution reaches the content. Anything else is skipped and reported.
///
/// Both boundaries matter. Following a link out of the project would let
/// `mold pack` inline `~/.ssh/id_rsa` into a template that is then shared;
/// following one to an excluded file would let a link defeat the very
/// mechanism used to keep material out of the template.
class FileScanner {
  FileScanner({
    List<String> include = const [],
    List<String> exclude = const [],
    this.useGitignore = false,
  }) : _include = include.map(Glob.new).toList(growable: false),
       _exclude = exclude.map(Glob.new).toList(growable: false);

  final List<Glob> _include;
  final List<Glob> _exclude;

  /// Whether the project's `.gitignore` files also exclude files.
  ///
  /// Defaults to false here — a bare `FileScanner` filters by nothing but its
  /// globs. `Bundler` passes the manifest's `use_gitignore`, which defaults to
  /// true.
  final bool useGitignore;

  /// Scans [sourceDir]. An empty include set means "all files".
  ///
  /// Descends directory by directory rather than taking one recursive listing,
  /// so an ignored directory is never entered — the way git itself walks. A
  /// flat listing had to enumerate and path-normalize every file under
  /// `build/`, `.dart_tool/` and `.git/` before discarding them, which on a
  /// real project is most of the tree.
  ScanResult scan(String sourceDir) {
    final root = Directory(sourceDir);
    // Canonical, because the source dir may itself be reached through a link
    // (on macOS /tmp resolves to /private/tmp), which would make every
    // containment check below fail.
    final canonicalRoot = root.resolveSymbolicLinksSync();

    final out = _Accumulator();
    _descend(
      root,
      sourceDir,
      canonicalRoot,
      useGitignore ? GitignoreRules.base() : const GitignoreRules.empty(),
      out,
    );
    out.files.sort();

    return ScanResult(
      files: out.files,
      executable: out.executable,
      skippedLinks: out.skipped,
      gitignored: out.gitignored,
    );
  }

  /// Walks one directory, carrying the `.gitignore` rules in force for it.
  void _descend(
    Directory dir,
    String sourceDir,
    String canonicalRoot,
    GitignoreRules inherited,
    _Accumulator out,
  ) {
    final rules = _rulesFor(dir, sourceDir, inherited);
    for (final entity in dir.listSync(followLinks: false)) {
      final rel = _relative(entity.path, sourceDir);

      // A directory link comes back as a Link, never a Directory, so this
      // cannot follow one — which is also why the walk cannot cycle.
      if (entity is Directory) {
        if (rules.isIgnoredEntry(rel, isDirectory: true)) {
          out.countIgnored();
          continue;
        }
        _descend(entity, sourceDir, canonicalRoot, rules, out);
        continue;
      }

      final isFile = entity is File;
      if (!isFile && entity is! Link) {
        continue;
      }

      // Asked first, so a file caught by both filters is still reported as
      // gitignored — the tally is what someone auditing "why is this file
      // missing" reads, and attributing it to `exclude` alone understates it.
      if (rules.isIgnoredEntry(rel, isDirectory: false)) {
        out.countIgnored();
        continue;
      }

      if (!_isIncluded(rel) || _isExcluded(rel)) {
        continue;
      }

      if (!isFile) {
        final reason = _skipReason(entity as Link, canonicalRoot);
        if (reason != null) {
          out.skipped[rel] = reason;
          continue;
        }
      }
      // Dereferenced: File operations on a link path follow it, so one stat
      // covers both cases and reports the target's mode.
      out.files.add(rel);
      if (_isExecutable(entity)) {
        out.executable.add(rel);
      }
    }
  }

  /// The rules for [dir]: those [inherited] from its ancestors, plus its own
  /// `.gitignore` if it has one.
  GitignoreRules _rulesFor(
    Directory dir,
    String sourceDir,
    GitignoreRules inherited,
  ) {
    if (!useGitignore) {
      return inherited;
    }
    final file = File(p.join(dir.path, '.gitignore'));
    if (!file.existsSync()) {
      return inherited;
    }
    final scope = _relative(dir.path, sourceDir);

    return inherited.extend(
      scope == '.' ? '' : scope,
      file.readAsLinesSync(),
    );
  }

  /// Why [link] cannot be packed, or null when it can be dereferenced.
  SkipReason? _skipReason(Link link, String canonicalRoot) {
    final String resolved;
    try {
      resolved = link.resolveSymbolicLinksSync();
    } on FileSystemException catch (e) {
      return _resolutionFailure(e);
    }

    if (!p.isWithin(canonicalRoot, resolved)) {
      return .outsideProject;
    }
    // The link's own path passed the filters; its target must too, or a link
    // would smuggle an excluded file into the archive.
    final relTarget = _relative(resolved, canonicalRoot);
    if (!_isIncluded(relTarget) || _isExcluded(relTarget)) {
      return .filteredOut;
    }
    // Recursing into a directory link would have to handle cycles; a template
    // that needs the contents can include the real directory instead.
    if (FileSystemEntity.isDirectorySync(resolved)) {
      return .directory;
    }

    return null;
  }

  /// Classifies a failed link resolution. ENOENT is 2 everywhere; ELOOP is 40
  /// on Linux and 62 on macOS.
  SkipReason _resolutionFailure(FileSystemException e) =>
      switch (e.osError?.errorCode) {
        2 => .dangling,
        40 || 62 => .circular,
        _ => .unresolvable,
      };

  /// Whether [entity] is owner-executable.
  ///
  /// Uses the entity's own `statSync`, which follows links, so a dereferenced
  /// link reports its target's mode. A `FileStat.statSync(path)` on top of the
  /// walk's own stat was a second syscall per candidate file for a bit the
  /// first one already carried.
  bool _isExecutable(FileSystemEntity entity) {
    try {
      // 0o100 — owner-execute.
      return entity.statSync().mode & 64 != 0;
    } on FileSystemException {
      return false;
    }
  }

  String _relative(String path, String from) =>
      p.posix.joinAll(p.split(p.relative(path, from: from)));

  bool _isIncluded(String rel) =>
      _include.isEmpty || _include.any((g) => g.matches(rel));

  bool _isExcluded(String rel) => _exclude.any((g) => g.matches(rel));
}
