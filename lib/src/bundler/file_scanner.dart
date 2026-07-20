import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Walks a source directory and applies `include` / `exclude` glob filters,
/// yielding file paths relative to the source root (POSIX-separated).
class FileScanner {
  FileScanner({
    List<String> include = const [],
    List<String> exclude = const [],
  }) : _include = include.map(Glob.new).toList(growable: false),
       _exclude = exclude.map(Glob.new).toList(growable: false);

  final List<Glob> _include;
  final List<Glob> _exclude;

  /// Returns the relative paths of all files under [sourceDir] that match the
  /// include set and survive the exclude set. An empty include set means "all
  /// files". Results are sorted for deterministic archives.
  List<String> scan(String sourceDir) {
    final root = Directory(sourceDir);
    final matches = <String>[];
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }

      final rel = p.posix.joinAll(
        p.split(p.relative(entity.path, from: sourceDir)),
      );
      if (_isIncluded(rel) && !_isExcluded(rel)) {
        matches.add(rel);
      }
    }

    matches.sort();
    
    return matches;
  }

  bool _isIncluded(String rel) =>
      _include.isEmpty || _include.any((g) => g.matches(rel));

  bool _isExcluded(String rel) => _exclude.any((g) => g.matches(rel));
}
