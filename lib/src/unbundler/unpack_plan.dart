/// What an unpack would do to one archive entry.
class PlannedFile {
  const PlannedFile({
    required this.from,
    required this.to,
    required this.verbatim,
    required this.replacements,
    this.before,
    this.after,
  });

  /// The entry's path inside the archive, before renaming.
  final String from;

  /// Where it would land under the target, after renaming.
  final String to;

  /// Whether it would be copied byte-for-byte — a binary extension, a
  /// `no_substitute` match, or content that is not valid UTF-8.
  final bool verbatim;

  /// How many substitutions the content would receive. Zero for [verbatim].
  final int replacements;

  /// The decoded content before substitution; null when [verbatim].
  final String? before;

  /// The decoded content after substitution; null when [verbatim].
  final String? after;

  /// Whether the path itself changes.
  bool get renamed => from != to;

  /// Whether anything about this file changes.
  bool get changed => renamed || replacements > 0;
}

/// Everything an unpack would do, without doing any of it.
///
/// Produced by `Unbundler.plan` from the same rules `_write` uses, so a preview
/// cannot drift from the real thing — it is the same computation minus the
/// writes.
class UnpackPlan {
  const UnpackPlan(this.files);

  /// One entry per archive file, in archive order.
  final List<PlannedFile> files;

  /// Files whose path changes.
  Iterable<PlannedFile> get renamed => files.where((f) => f.renamed);

  /// Files whose content changes.
  Iterable<PlannedFile> get rewritten =>
      files.where((f) => f.replacements > 0);

  /// Files nothing happens to.
  Iterable<PlannedFile> get untouched => files.where((f) => !f.changed);

  /// Total substitutions across every file.
  int get totalReplacements =>
      files.fold(0, (sum, f) => sum + f.replacements);
}
