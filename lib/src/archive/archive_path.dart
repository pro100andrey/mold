import 'package:path/path.dart' as p;

/// Whether [relPath] — an archive entry path, relative to the `files/` root —
/// stays inside the tree it is relative to.
///
/// Archive paths are POSIX-separated by construction (`ArchiveWriter` joins
/// with `/`), so a backslash can only come from a hand-crafted archive and is
/// rejected outright: on Windows it would act as a separator and slip past a
/// POSIX-only normalization.
///
/// Rejects absolute paths, Windows drive-qualified paths, and any path that
/// normalizes to a `..` prefix — the traversal shapes that let an archive write
/// outside its target directory.
bool isContainedArchivePath(String relPath) {
  if (relPath.isEmpty || relPath.contains(r'\')) {
    return false;
  }
  // A leading `/`, or a drive root like `C:/`, makes p.join discard the target
  // root entirely (`join(r'C:\target', 'C:/Windows')` is `C:/Windows`). A
  // drive-*relative* name such as `C:notes.txt` has no separator after the
  // colon, so join keeps it under the target and it stays allowed.
  if (p.posix.isAbsolute(relPath) || p.windows.isAbsolute(relPath)) {
    return false;
  }

  final normalized = p.posix.normalize(relPath);

  return normalized != '..' && !normalized.startsWith('../');
}
