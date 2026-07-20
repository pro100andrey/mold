import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// What a scan found: the files to pack, and the symlinks deliberately left
/// out of them.
class ScanResult {
  const ScanResult({required this.files, required this.skippedLinks});

  /// Relative paths to pack, sorted for deterministic archives.
  final List<String> files;

  /// Symlinks that matched the filters but were not packed, keyed by relative
  /// path with a human-facing reason. Reported as warnings by
  /// `ProjectValidator` — a dropped file must never be silent.
  final Map<String, String> skippedLinks;
}

/// Walks a source directory and applies `include` / `exclude` glob filters,
/// yielding file paths relative to the source root (POSIX-separated).
///
/// A symlink pointing at a file **inside** the source directory is packed as
/// its content (dereferenced), so the unpacked project works without needing
/// symlink privileges — Windows requires them — and so substitution reaches
/// the content. A symlink pointing outside, at a directory, or at nothing is
/// skipped and reported.
///
/// Refusing to follow a link out of the project is a boundary, not tidiness:
/// following one would let `mold pack` inline `~/.ssh/id_rsa` or `../../.env`
/// into a template that is then shared.
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
    final skipped = <String, String>{};
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      final rel = p.posix.joinAll(
        p.split(p.relative(entity.path, from: sourceDir)),
      );
      if (!_isIncluded(rel) || _isExcluded(rel)) {
        continue;
      }

      if (entity is File) {
        matches.add(rel);
      } else if (entity is Link) {
        final reason = _skipReason(entity, canonicalRoot);
        if (reason == null) {
          // Dereferenced: File operations on this path follow the link.
          matches.add(rel);
        } else {
          skipped[rel] = reason;
        }
      }
    }

    matches.sort();

    return ScanResult(files: matches, skippedLinks: skipped);
  }

  /// Why [link] cannot be packed, or null when it can be dereferenced.
  String? _skipReason(Link link, String canonicalRoot) {
    final String resolved;
    try {
      resolved = link.resolveSymbolicLinksSync();
    } on FileSystemException {
      return 'its target does not exist';
    }
    if (!p.isWithin(canonicalRoot, resolved)) {
      return 'its target is outside the project';
    }
    // Recursing into a directory link would have to handle cycles; a template
    // that needs the contents can include the real directory instead.
    if (FileSystemEntity.isDirectorySync(resolved)) {
      return 'its target is a directory';
    }
    return null;
  }

  bool _isIncluded(String rel) =>
      _include.isEmpty || _include.any((g) => g.matches(rel));

  bool _isExcluded(String rel) => _exclude.any((g) => g.matches(rel));
}
