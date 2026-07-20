import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

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
  }) : _include = include.map(Glob.new).toList(growable: false),
       _exclude = exclude.map(Glob.new).toList(growable: false);

  final List<Glob> _include;
  final List<Glob> _exclude;

  /// Scans [sourceDir]. An empty include set means "all files".
  ScanResult scan(String sourceDir) {
    final root = Directory(sourceDir);
    // Canonical, because the source dir may itself be reached through a link
    // (on macOS /tmp resolves to /private/tmp), which would make every
    // containment check below fail.
    final canonicalRoot = root.resolveSymbolicLinksSync();

    final matches = <String>[];
    final executable = <String>{};
    final skipped = <String, SkipReason>{};
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      // Type first: directories are neither packed nor reported, so matching
      // them against every glob is pure waste.
      final isFile = entity is File;
      if (!isFile && entity is! Link) {
        continue;
      }

      final rel = _relative(entity.path, sourceDir);
      if (!_isIncluded(rel) || _isExcluded(rel)) {
        continue;
      }

      if (!isFile) {
        final reason = _skipReason(entity as Link, canonicalRoot);
        if (reason != null) {
          skipped[rel] = reason;
          continue;
        }
      }
      // Dereferenced: File operations on a link path follow it, so one stat
      // covers both cases and reports the target's mode.
      matches.add(rel);
      if (_isExecutable(entity.path)) {
        executable.add(rel);
      }
    }

    matches.sort();

    return ScanResult(
      files: matches,
      executable: executable,
      skippedLinks: skipped,
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
      return SkipReason.outsideProject;
    }
    // The link's own path passed the filters; its target must too, or a link
    // would smuggle an excluded file into the archive.
    final relTarget = _relative(resolved, canonicalRoot);
    if (!_isIncluded(relTarget) || _isExcluded(relTarget)) {
      return SkipReason.filteredOut;
    }
    // Recursing into a directory link would have to handle cycles; a template
    // that needs the contents can include the real directory instead.
    if (FileSystemEntity.isDirectorySync(resolved)) {
      return SkipReason.directory;
    }
    return null;
  }

  /// Classifies a failed link resolution. ENOENT is 2 everywhere; ELOOP is 40
  /// on Linux and 62 on macOS.
  SkipReason _resolutionFailure(FileSystemException e) => switch (e
      .osError
      ?.errorCode) {
    2 => SkipReason.dangling,
    40 || 62 => SkipReason.circular,
    _ => SkipReason.unresolvable,
  };

  /// Whether [path] is owner-executable. Follows links, so a dereferenced
  /// link reports its target's mode.
  bool _isExecutable(String path) {
    try {
      // 0o100 — owner-execute.
      return FileStat.statSync(path).mode & 64 != 0;
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
