import 'dart:typed_data';

import '../manifest/manifest.dart';
import '../manifest/substitution_template.dart';

/// What an unpack would do to one archive entry.
class PlannedFile {
  const PlannedFile({
    required this.from,
    required this.to,
    required this.verbatim,
    required this.replacements,
    required this.bytes,
    this.executable = false,
    this.before,
    this.after,
    this.overwrites = false,
    this.identicalToExisting = false,
    this.existing,
    this.generated = false,
    this.editedSinceStamp = false,
  });

  /// The entry's path inside the archive, before renaming. For a [generated]
  /// file, the same as [to].
  final String from;

  /// Where it would land under the target, after renaming.
  final String to;

  /// Whether it would be copied byte-for-byte — a binary extension, a
  /// `no_substitute` match, or content that is not valid UTF-8.
  final bool verbatim;

  /// How many substitutions the content would receive. Zero for [verbatim].
  final int replacements;

  /// Exactly the bytes that would be written.
  ///
  /// For a file nothing is substituted in, this is the archive's own buffer,
  /// not a copy of it.
  final Uint8List bytes;

  /// Whether the file would be made owner-executable.
  final bool executable;

  /// The decoded content before substitution; null when the content is not
  /// valid UTF-8 or the plan was built without content.
  ///
  /// A [verbatim] file that is text has it too, equal to [after].
  final String? before;

  /// The decoded content after substitution; null when the content is not
  /// valid UTF-8 or the plan was built without content.
  final String? after;

  /// Whether a file is already at [to] in the target, so writing this one
  /// replaces it. Only an overwrite unpack can plan one.
  final bool overwrites;

  /// Whether the file already at [to] holds exactly [bytes] — an overwrite
  /// that changes nothing. False when nothing is there.
  final bool identicalToExisting;

  /// The decoded text of the file already at [to]; null when nothing is
  /// there, it is not valid UTF-8, or the plan was built without content.
  final String? existing;

  /// Whether the file is written by mold rather than taken from the archive —
  /// the unpack stamp.
  final bool generated;

  /// Whether overwriting the file in the target discards content the
  /// stamped unpack did not write: it was edited since, or the stamp does not
  /// list it at all — a file of the project's own, at a path the template has
  /// added since.
  ///
  /// False when the target has no stamp, or the overwrite would change
  /// nothing.
  final bool editedSinceStamp;

  /// Whether the path itself changes.
  bool get renamed => from != to;

  /// Whether anything about this file changes.
  bool get changed => renamed || replacements > 0;
}

/// Everything an unpack would do, without doing any of it.
///
/// Produced by `Unbundler.plan`, and written by `Unbundler.apply` — which is
/// also how `Unbundler.unbundle` writes. A preview cannot drift from the real
/// thing because there is no separate real thing: an unpack is a plan, then
/// its application.
class UnpackPlan {
  const UnpackPlan({
    required this.files,
    required this.manifest,
    required this.values,
    this.targetDir,
    this.overwrite = false,
    this.stale = const [],
  });

  /// One entry per archive file, in archive order.
  final List<PlannedFile> files;

  /// The template's manifest, as embedded in the archive.
  final Manifest manifest;

  /// The resolved value of every declared variable.
  final Map<String, String> values;

  /// Where the plan writes; null for a plan made with no destination in mind,
  /// which can be inspected but not applied.
  final String? targetDir;

  /// Whether the plan writes into an occupied target.
  final bool overwrite;

  /// Files the previous unpack into this target wrote, per its stamp, that
  /// the template no longer has and that are still there.
  ///
  /// Left in place, never deleted — they may have been edited since — but
  /// worth knowing about when regenerating: they are what a fresh unpack of
  /// the same template would not contain.
  final List<String> stale;

  /// The manifest's `message`, rendered with [values]; null when it has none.
  String? get message => switch (manifest.message) {
    final text? => SubstitutionTemplate.parse(text).render(values),
    null => null,
  };

  /// Files whose path changes.
  Iterable<PlannedFile> get renamed => files.where((f) => f.renamed);

  /// Files whose content changes.
  Iterable<PlannedFile> get rewritten => files.where((f) => f.replacements > 0);

  /// The template's own files: [files] without the [PlannedFile.generated]
  /// stamp.
  Iterable<PlannedFile> get templateFiles => files.where((f) => !f.generated);

  /// Template files nothing happens to.
  Iterable<PlannedFile> get untouched => templateFiles.where((f) => !f.changed);

  /// Files whose path is free in the target.
  Iterable<PlannedFile> get created => files.where((f) => !f.overwrites);

  /// Overwrites that discard content the last stamped unpack did not write.
  Iterable<PlannedFile> get edited => files.where((f) => f.editedSinceStamp);

  /// Files that replace one already in the target.
  Iterable<PlannedFile> get overwritten => files.where((f) => f.overwrites);

  /// Total substitutions across every file.
  int get totalReplacements => files.fold(0, (sum, f) => sum + f.replacements);
}
