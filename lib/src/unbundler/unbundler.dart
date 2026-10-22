import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../archive/archive_path.dart';
import '../archive/archive_reader.dart';
import '../archive/archive_validator.dart';
import '../manifest/content_policy.dart';
import '../manifest/manifest.dart';
import '../manifest/manifest_validator.dart';
import '../manifest/substitution_template.dart';
import '../prompt/variable_resolver.dart';
import '../util/bytes.dart';
import '../util/sample.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import 'case_converter.dart';
import 'casing_needle.dart';
import 'rename_validator.dart';
import 'substitutor.dart';
import 'target_validator.dart';
import 'unpack_plan.dart';
import 'unpack_stamp.dart';
import 'variables_validator.dart';

/// Materializes a project from a template archive, applying manifest-driven
/// renaming at unpack time (the archive itself stays a verbatim snapshot).
///
/// For each declared variable with a `replaces` token, the resolved value
/// substitutes all four casings throughout file/dir paths and text-file
/// contents. Binary files are copied byte-for-byte.
///
/// An unpack is two steps, and both are public: [plan] decides everything —
/// validation, variables, where each file lands and what it holds — and
/// [apply] writes a plan. [unbundle] is the two in a row. A caller that wants
/// to show a preview and ask before writing plans once and applies that same
/// plan, instead of computing the unpack twice.
///
/// Problems with the inputs — the archive, its manifest, the variables, the
/// target — throw a [ValidationException] carrying stable codes. A failing
/// filesystem throws an [IOException].
class Unbundler {
  const Unbundler();

  /// A failed `chmod`: the files are written, but not executable.
  static const chmodFailed = 'UNPACK_CHMOD_FAILED';

  /// A failed write that could not be fully undone.
  static const undoIncomplete = 'UNPACK_UNDO_INCOMPLETE';

  /// Files the previous unpack wrote that the template no longer has.
  static const staleFiles = 'UNPACK_STALE_FILES';

  /// A `.mold.json` in the target that is not a readable stamp.
  static const stampInvalid = 'UNPACK_STAMP_INVALID';

  /// Overwrites that discard edits made since the stamped unpack.
  static const overwritesEdits = 'UNPACK_OVERWRITES_EDITS';

  /// The target's stamp is another template's: a warning, and an error when
  /// a stamp is to be written.
  static const stampForeign = 'UNPACK_STAMP_FOREIGN';

  /// Unpacks the archive [bytes] into [targetDir]: [plan], then [apply].
  ///
  /// [vars] holds explicit values; any variable absent from it is resolved by
  /// [resolver] (default/prompt per its configuration). Without a [resolver],
  /// unresolved variables fall back to the manifest `default`; one with no
  /// default is reported by `VariablesValidator`.
  ///
  /// Every key of [vars] must name a variable the template declares — a key
  /// that does not is `VARIABLE_UNKNOWN`, not a value quietly ignored. Passing
  /// one shared map across several templates therefore does **not** work; pass
  /// each template the subset it declares.
  ///
  /// [recorded] holds the values a previous unpack recorded — see [plan].
  ///
  /// With [overwrite], [targetDir] may already hold files — see [apply].
  /// With [stamp], the unpack records itself in the target — see [plan].
  ///
  /// [onWarning] receives non-fatal problems that would otherwise be silent,
  /// such as a token that over-reaches or failing to restore an executable
  /// bit.
  Future<void> unbundle({
    required List<int> bytes,
    required String targetDir,
    Map<String, String> vars = const {},
    Map<String, String> recorded = const {},
    VariableResolver? resolver,
    bool overwrite = false,
    bool stamp = false,
    WarningSink? onWarning,
  }) async {
    final planned = plan(
      bytes: bytes,
      targetDir: targetDir,
      vars: vars,
      recorded: recorded,
      resolver: resolver,
      overwrite: overwrite,
      stamp: stamp,
      withContent: false,
      onWarning: onWarning,
    );
    await apply(planned, onWarning: onWarning);
  }

  /// Reads the archive at the file [source] and unpacks it into [targetDir].
  ///
  /// A missing [source] is `ARCHIVE_NOT_FOUND`.
  Future<void> unbundleFile({
    required String source,
    required String targetDir,
    Map<String, String> vars = const {},
    Map<String, String> recorded = const {},
    VariableResolver? resolver,
    bool overwrite = false,
    bool stamp = false,
    WarningSink? onWarning,
  }) async {
    await unbundle(
      bytes: readArchive(source),
      targetDir: targetDir,
      vars: vars,
      recorded: recorded,
      resolver: resolver,
      overwrite: overwrite,
      stamp: stamp,
      onWarning: onWarning,
    );
  }

  /// The bytes of the archive file at [path]; `ARCHIVE_NOT_FOUND` when there
  /// is none.
  static Uint8List readArchive(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ValidationException([
        ValidationError(
          ArchiveValidator.notFound,
          'Archive not found: $path',
        ),
      ]);
    }

    return file.readAsBytesSync();
  }

  /// Builds a plan describing what an unpack would do, without doing it.
  ///
  /// Phase order: archive → manifest → target → variables → rename. The first
  /// failing phase aborts before the next runs. Target precedes variables
  /// because resolving them may prompt: validating it afterwards made the user
  /// answer every prompt only to be told the destination was occupied.
  ///
  /// [targetDir] is validated when given, so a plan also tells you the
  /// destination is usable. Pass null to preview the substitutions alone, with
  /// no destination in mind — what `mold pack --diff` does for a template that
  /// has not been distributed yet. Such a plan cannot be applied.
  ///
  /// With [overwrite] an occupied [targetDir] is planned rather than refused,
  /// and each file says whether it would replace one already there
  /// ([PlannedFile.overwrites]), whether that changes anything
  /// ([PlannedFile.identicalToExisting]), and — with [withContent] — what the
  /// file there holds now ([PlannedFile.existing]).
  ///
  /// With [stamp], the plan also writes an [UnpackStamp] — `.mold.json`, at
  /// the target's root — recording the template, the variable values and the
  /// files written. A target that already holds a stamp gets an updated one
  /// whether or not [stamp] is set, since a stamp that no longer describes
  /// the files would be worse than none; and the files its previous stamp
  /// lists that this template no longer has become [UnpackPlan.stale].
  ///
  /// [withContent] keeps the decoded text of each file, before and after
  /// substitution, for rendering a diff. A plan meant only to be applied does
  /// not need it, and holding both sides of every text file is two extra
  /// copies of the corpus.
  ///
  /// [recorded] holds values a previous unpack recorded — an
  /// [UnpackStamp]'s `vars`, for regenerating a project. They come after
  /// [vars] and before [resolver], and a name the template no longer declares
  /// is `VARIABLE_DROPPED`, a warning: a template that dropped a variable must
  /// not make its own stamp unusable.
  ///
  /// [onWarning] receives the same warnings a real unpack would report, so a
  /// preview is not quieter than the thing it previews.
  UnpackPlan plan({
    required List<int> bytes,
    String? targetDir,
    Map<String, String> vars = const {},
    Map<String, String> recorded = const {},
    VariableResolver? resolver,
    bool overwrite = false,
    bool stamp = false,
    bool withContent = true,
    WarningSink? onWarning,
  }) {
    final (archive, manifest) = _open(bytes, onWarning);

    return _plan(
      archive,
      manifest,
      targetDir: targetDir,
      vars: vars,
      recorded: recorded,
      resolver: resolver,
      overwrite: overwrite,
      stamp: stamp,
      withContent: withContent,
      onWarning: onWarning,
    );
  }

  /// [plan], from the target phase on, for an archive already opened and
  /// validated.
  UnpackPlan _plan(
    BundleArchive archive,
    Manifest manifest, {
    required String? targetDir,
    required Map<String, String> vars,
    required Map<String, String> recorded,
    required VariableResolver? resolver,
    required bool overwrite,
    required bool stamp,
    required bool withContent,
    required WarningSink? onWarning,
  }) {
    // A null target means "no destination in mind" — previewing the
    // substitutions of a template that has not been distributed yet. Every
    // other phase still runs.
    final target = TargetValidator(overwrite: overwrite);
    if (targetDir != null) {
      target.validate(targetDir).report(onWarning);
    }

    // Without overwrite the target was just validated empty, so nothing in it
    // can be replaced and there is nothing to look at. Read before the
    // variables, which may prompt: a stamp that refuses the unpack should do
    // so before the questions, not after them.
    final inspect = overwrite ? targetDir : null;
    final previous = inspect == null
        ? null
        : _ownStamp(inspect, manifest, stamp: stamp, onWarning: onWarning);

    final resolved = (resolver ?? const VariableResolver()).resolve(
      manifest.variables,
      {...recorded, ...vars},
    );
    const VariablesValidator()
        .validate(
          VariablesInput(
            variables: manifest.variables,
            values: resolved,
            explicit: vars,
            recorded: recorded,
          ),
        )
        .report(onWarning);

    // Only paths inside the target. A stamp is a file anyone can edit, and
    // one listing `../x` or `/etc/hosts` must not have mold look there, let
    // alone report it as a file of the project's.
    final previousFiles = <String, String>{
      for (final MapEntry(:key, :value)
          in previous?.files.entries ?? const <MapEntry<String, String>>[])
        if (isContainedArchivePath(key)) key: value,
    };
    final writeStamp = targetDir != null && (stamp || previous != null);

    final rules = _Rules(manifest, resolved);
    final presence = _Presence(manifest, resolved, rules);
    final renames = {
      for (final key in archive.files.keys) key: presence.rename(key),
      // In the mapping so a template file renamed onto the stamp's path is a
      // collision like any other, not a file the stamp silently replaces.
      if (writeStamp) _stampKey: UnpackStamp.fileName,
    };
    RenameValidator(
      windows: Platform.isWindows,
    ).validate(renames).report(onWarning);

    if (inspect != null) {
      target.validateDestinations(inspect, renames.values).report(onWarning);
    }
    File? existing(String to) =>
        inspect == null ? null : File(p.join(inspect, to));

    // Each destination → the stamp's entry for the file it lands on, when
    // the stamp has one.
    final tracked = previous == null
        ? const <String, String?>{}
        : _stampEntries(inspect!, previousFiles, archive.files.keys, renames);
    final files = [
      for (final MapEntry(key: from, value: content) in archive.files.entries)
        _planOne(
          rules,
          from,
          renames[from]!,
          content,
          executable: archive.executable.contains(from),
          withContent: withContent,
          existing: existing(renames[from]!),
          stamped: previous == null
              ? null
              : (previousFiles[tracked[renames[from]]] ?? _untracked),
          presence: presence,
        ),
    ];
    if (onWarning != null) {
      presence.warnings().forEach(onWarning);
    }
    final edited = [
      for (final f in files)
        if (f.editedSinceStamp && tracked[f.to] != null) f.to,
    ];
    final untracked = [
      for (final f in files)
        if (f.editedSinceStamp && tracked[f.to] == null) f.to,
    ];
    if (edited.isNotEmpty || untracked.isNotEmpty) {
      final editedReason =
          '${edited.length} file(s) were edited since the last unpack: '
          '${edited.join(', ')}';
      final untrackedReason =
          '${untracked.length} file(s) were never written by it — the '
          "template added them since, over the project's own: "
          '${untracked.join(', ')}';
      final reasons = [
        if (edited.isNotEmpty) editedReason,
        if (untracked.isNotEmpty) untrackedReason,
      ];
      onWarning?.call(
        ValidationError.warning(
          overwritesEdits,
          '${reasons.join('; and ')}. This unpack overwrites them.',
        ),
      );
    }
    // Stale files stay in the stamp, with the digest they were written with,
    // for as long as they are there: dropping them would report a leftover
    // once and then never again, while it is still in the project.
    final rewritten = tracked.values.nonNulls.toSet();
    final stale = [
      for (final path in previousFiles.keys)
        if (!rewritten.contains(path) &&
            File(p.join(inspect!, path)).existsSync())
          path,
    ];
    if (writeStamp) {
      final record = UnpackStamp(
        template: manifest.name,
        version: manifest.version,
        vars: resolved,
        files: Map.fromEntries(
          [
            for (final f in files) MapEntry(f.to, UnpackStamp.digest(f.bytes)),
            for (final path in stale) MapEntry(path, previousFiles[path]!),
          ]..sort((a, b) => a.key.compareTo(b.key)),
        ),
      );
      files.add(
        _planGenerated(
          UnpackStamp.fileName,
          utf8.encode(record.toJson()),
          withContent: withContent,
          existing: existing(UnpackStamp.fileName),
        ),
      );
    }

    return UnpackPlan(
      files: files,
      manifest: manifest,
      values: resolved,
      targetDir: targetDir,
      overwrite: overwrite,
      stale: stale,
    );
  }

  /// For each destination of [renames], the key of [previousFiles] naming
  /// the file it lands on — or null when the stamp has none.
  ///
  /// The same path, or on a case-insensitive filesystem (macOS, Windows) one
  /// spelled with other casing that is the same file on disk: a value whose
  /// casing changed rewrites `MyApp.swift` as `Myapp.swift`, which is the
  /// stamp's file, not the project's own — and its old name is not stale.
  static Map<String, String?> _stampEntries(
    String targetDir,
    Map<String, String> previousFiles,
    Iterable<String> archived,
    Map<String, String> renames,
  ) {
    Map<String, List<String>>? folded;
    String? entryFor(String to) {
      if (previousFiles.containsKey(to)) {
        return to;
      }
      folded ??= _byFoldedCase(previousFiles.keys);
      for (final key in folded![to.toLowerCase()] ?? const <String>[]) {
        if (_sameFile(p.join(targetDir, key), p.join(targetDir, to))) {
          return key;
        }
      }

      return null;
    }

    return {
      for (final from in archived) renames[from]!: entryFor(renames[from]!),
    };
  }

  static Map<String, List<String>> _byFoldedCase(Iterable<String> paths) {
    final out = <String, List<String>>{};
    for (final path in paths) {
      (out[path.toLowerCase()] ??= []).add(path);
    }

    return out;
  }

  /// Whether [a] and [b] are one file on disk; false when either is missing.
  static bool _sameFile(String a, String b) {
    try {
      return FileSystemEntity.identicalSync(a, b);
    } on FileSystemException {
      return false;
    }
  }

  /// What `stamped` is for a file a stamp exists but does not list: a digest
  /// no bytes have, so any file found there counts as not mold's.
  static const _untracked = '';

  /// The key the stamp takes in the rename mapping — not a legal archive
  /// path, so no entry can share it.
  static const _stampKey = '(mold stamp)';

  /// The stamp already in [targetDir], when it is one of [manifest]'s
  /// template.
  ///
  /// A stamp of another template is reported and not used. Unpacking an
  /// add-on template into a project made from another one is reasonable, and
  /// judging it by that project's stamp was not: every file the first
  /// template wrote looked stale, and the stamp was rewritten for the second,
  /// losing the first one's values and record. With [stamp] it is an error —
  /// one `.mold.json` describes one template, and replacing it is the loss
  /// described.
  static UnpackStamp? _ownStamp(
    String targetDir,
    Manifest manifest, {
    required bool stamp,
    required WarningSink? onWarning,
  }) {
    final found = _readStamp(targetDir, onWarning);
    if (found == null || found.template == manifest.name) {
      return found;
    }

    final what =
        '${p.join(targetDir, UnpackStamp.fileName)} is the stamp of template '
        "'${found.template}', not of '${manifest.name}'";
    ValidationResult([
      if (stamp)
        ValidationError(
          stampForeign,
          '$what, and one stamp describes one template. Unpack without '
          '--stamp (`stamp: false`) to leave it as it is.',
        )
      else
        ValidationError.warning(
          stampForeign,
          '$what. It is left as it is, and not used to tell stale or edited '
          'files.',
        ),
    ]).report(onWarning);

    return null;
  }

  /// The stamp already in [targetDir], when there is one.
  ///
  /// A `.mold.json` that is not a stamp is reported rather than ignored: it is
  /// about to be overwritten if a stamp is written, and stale files cannot be
  /// told without it.
  static UnpackStamp? _readStamp(String targetDir, WarningSink? onWarning) {
    final file = File(p.join(targetDir, UnpackStamp.fileName));
    if (!file.existsSync()) {
      return null;
    }
    UnpackStamp? stamp;
    try {
      stamp = UnpackStamp.tryParse(file.readAsStringSync());
    } on FileSystemException {
      // Unreadable, or not UTF-8 — not a stamp either way, and not a reason
      // to abandon the unpack.
    }
    if (stamp == null) {
      onWarning?.call(
        ValidationError.warning(
          stampInvalid,
          '${file.path} is not a mold stamp, so files the template has '
          'dropped cannot be told apart.',
        ),
      );
    }

    return stamp;
  }

  /// Validates the archive and its manifest, and opens both — the part of an
  /// unpack that needs no variables and no target.
  (BundleArchive, Manifest) _open(List<int> bytes, WarningSink? onWarning) {
    final inspected = const ArchiveValidator().inspect(bytes);
    inspected.result.report(onWarning);
    final archive = const ArchiveReader().fromTar(inspected.tar!);
    final manifest = Manifest.fromYaml(archive.manifestYaml);
    const ManifestValidator().validate(manifest).report(onWarning);

    return (archive, manifest);
  }

  /// Describes the template in archive [bytes] without unpacking it: its
  /// manifest and its files, unrenamed.
  ///
  /// Runs the archive and manifest phases of an unpack, so an archive that
  /// inspects cleanly fails an unpack only on variables or the target.
  TemplateInfo inspect(List<int> bytes, {WarningSink? onWarning}) {
    final (archive, manifest) = _open(bytes, onWarning);

    return TemplateInfo(
      manifest: manifest,
      manifestYaml: archive.manifestYaml,
      sizes: {
        for (final MapEntry(:key, :value) in archive.files.entries)
          key: value.length,
      },
      executable: archive.executable,
    );
  }

  PlannedFile _planGenerated(
    String path,
    Uint8List bytes, {
    required bool withContent,
    required File? existing,
  }) {
    final onDisk = existing != null && existing.existsSync()
        ? existing.readAsBytesSync()
        : null;

    return PlannedFile(
      from: path,
      to: path,
      verbatim: false,
      replacements: 0,
      bytes: bytes,
      generated: true,
      after: withContent ? utf8.decode(bytes) : null,
      overwrites: onDisk != null,
      identicalToExisting: onDisk != null && sameBytes(onDisk, bytes),
      existing: withContent && onDisk != null ? _tryDecode(onDisk) : null,
    );
  }

  PlannedFile _planOne(
    _Rules rules,
    String from,
    String to,
    Uint8List content, {
    required bool executable,
    required bool withContent,
    required File? existing,
    // The digest the target's stamp records for [to]: null with no stamp,
    // [_untracked] when the stamp does not list it.
    required String? stamped,
    required _Presence presence,
  }) {
    final before = rules.decode(from, content);
    var replacements = 0;
    String? after;
    var bytes = content;
    if (before != null) {
      (after, replacements) = presence.substitute(from, before);
      // Re-encoded only when something changed: decoding and re-encoding an
      // untouched file reproduces its bytes, so the archive's own buffer is
      // already the answer, with no copy.
      if (replacements > 0) {
        bytes = rules.encode(content, after);
      }
    }

    final onDisk = existing != null && existing.existsSync()
        ? existing.readAsBytesSync()
        : null;

    final identical = onDisk != null && sameBytes(onDisk, bytes);
    // A file copied verbatim is still shown as text when it is text — a
    // `no_substitute` lock file, say — so an overwrite of it diffs as one
    // rather than as "binary".
    final text = withContent ? before ?? _tryDecode(content) : null;

    return PlannedFile(
      from: from,
      to: to,
      verbatim: before == null,
      replacements: replacements,
      bytes: bytes,
      executable: executable,
      before: text,
      after: withContent ? after ?? text : null,
      overwrites: onDisk != null,
      identicalToExisting: identical,
      existing: withContent && onDisk != null ? _tryDecode(onDisk) : null,
      editedSinceStamp:
          stamped != null &&
          onDisk != null &&
          !identical &&
          UnpackStamp.digest(onDisk) != stamped,
    );
  }

  /// Writes [plan] into its target directory.
  ///
  /// The target is validated again first. Planning may have waited on
  /// interactive input for minutes, or a caller may have shown the plan and
  /// asked before applying it — neither makes the destination still free.
  ///
  /// With the plan's `overwrite`, the target may already hold files: each file
  /// the template has is written over the file at the same path, and every
  /// other file is left as it is — the way a tool regenerates a project in
  /// place. Without it, a non-empty target is `TARGET_OCCUPIED`. Either way a
  /// target that is a file is refused, and so is a template file that would
  /// land on a directory, under a file, or through a symlink
  /// (`TARGET_PATH_CONFLICT`), before anything is written.
  ///
  /// Writes in place, keeping what it needs to undo them: the files it
  /// created, the directories it created, and the previous bytes of each file
  /// it overwrote. Staging into a scratch directory and moving the result in
  /// was the alternative, and it buys less than it seems — moving a tree of
  /// files into an occupied directory is one rename per file, so it is no
  /// more atomic than writing them, and a scratch directory beside the target
  /// can sit on another filesystem, where a rename is a copy. The predictable
  /// failure — a path conflict — is caught before the first write; what is
  /// left (a read-only file, a full disk, the tree changing underneath) this
  /// undoes, and anything it cannot undo is reported as
  /// `UNPACK_UNDO_INCOMPLETE` before the error is rethrown.
  ///
  /// Overwritten files keep their mode: the content is replaced in place, and
  /// the executable bit is added where the template has it, never removed.
  ///
  /// Throws an [ArgumentError] for a plan made without a `targetDir`: it can
  /// be shown, but there is nowhere to write it.
  Future<void> apply(UnpackPlan plan, {WarningSink? onWarning}) async {
    final targetDir = plan.targetDir;
    if (targetDir == null) {
      throw ArgumentError.value(
        plan,
        'plan',
        'was made without a target directory, so there is nowhere to write it',
      );
    }

    final target = TargetValidator(overwrite: plan.overwrite);
    target.validate(targetDir).report(onWarning);
    if (plan.overwrite) {
      target
          .validateDestinations(targetDir, plan.files.map((f) => f.to))
          .report(onWarning);
    }

    // Whether the destination is ours to remove if this goes wrong. An unpack
    // into an existing directory must not delete that directory; one that
    // created it must not leave the debris behind.
    final preexisting = Directory(targetDir).existsSync();
    final root = Directory(targetDir)..createSync(recursive: true);
    final undo = _Undo(root.path, preexisting: preexisting);
    final restoreExecutable = <String>[];
    try {
      for (final file in plan.files) {
        // Absolute, so `chmod` cannot mistake a path for an option: GNU getopt
        // permutes arguments, so a target directory named `-out` would make
        // `chmod +x -out/x.sh` parse as flags and fail for the whole batch.
        final out = File(p.absolute(p.join(root.path, file.to)));
        if (file.executable) {
          restoreExecutable.add(out.path);
        }

        // A file the plan found identical is compared, not rewritten:
        // rewriting it changes nothing but its mtime, and on a regeneration
        // that is most of the project — every build cache invalidated, every
        // file watcher woken. Compared again here because the plan may be
        // old; what was read doubles as the undo's copy.
        List<int>? current;
        if (file.identicalToExisting && out.existsSync()) {
          current = out.readAsBytesSync();
          if (sameBytes(current, file.bytes)) {
            continue;
          }
        }

        // Recorded before the write, so a write that fails halfway — a
        // truncated file — is undone too.
        undo
          ..createParents(out.parent)
          ..recordWrite(out, current: current);
        out.writeAsBytesSync(file.bytes);
      }
    } on Object {
      // A half-written project is worse than none: it is not runnable, and it
      // makes the obvious retry fail with TARGET_OCCUPIED, so the user has to
      // work out what to delete before they can try again. Into an occupied
      // target it is worse still: a mix of their files and the template's.
      final leftover = undo.run();
      if (leftover.isNotEmpty) {
        onWarning?.call(
          ValidationError.warning(
            undoIncomplete,
            'The unpack failed and could not undo all of it; check these '
            'paths: ${leftover.join(', ')}',
          ),
        );
      }
      rethrow;
    }
    _makeExecutable(restoreExecutable, onWarning);

    if (plan.stale.isNotEmpty) {
      onWarning?.call(
        ValidationError.warning(
          staleFiles,
          '${plan.stale.length} file(s) from the previous unpack are no '
          'longer in the template and were left in place: '
          '${plan.stale.join(', ')}',
        ),
      );
    }
  }

  /// Restores the owner-executable bit on [paths].
  ///
  /// `dart:io` exposes no chmod, so this shells out. A no-op on Windows, which
  /// has no such bit; best-effort elsewhere, since failing to chmod must not
  /// discard an otherwise valid unpack — but the failure is reported through
  /// [warn] rather than swallowed, or the user meets it later as "permission
  /// denied" in the scaffolded project.
  ///
  /// Batched, but in chunks: one exec with a few thousand paths would exceed
  /// ARG_MAX and fail with E2BIG — a non-zero exit code, not an exception, so
  /// an unchecked call would leave every file non-executable in silence.
  void _makeExecutable(List<String> paths, WarningSink? warn) {
    if (paths.isEmpty || Platform.isWindows) {
      return;
    }

    const chunkSize = 500;
    for (var i = 0; i < paths.length; i += chunkSize) {
      final chunk = paths.sublist(i, min(i + chunkSize, paths.length));
      String? failure;
      try {
        final result = Process.runSync('chmod', ['+x', ...chunk]);
        if (result.exitCode != 0) {
          failure =
              'Could not make ${chunk.length} file(s) executable: '
              '${result.stderr}';
        }
      } on ProcessException catch (e) {
        failure = 'Could not run chmod: ${e.message}';
      }
      if (failure != null) {
        warn?.call(ValidationError.warning(chmodFailed, failure));
      }
    }
  }

  static String? _tryDecode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }
}

/// `Unbundler.plan` for a template `collectBundle` has just read and checked,
/// with no destination: what `pack --diff` previews.
///
/// Not exported. It starts at the variables phase — the archive and manifest
/// phases are the pack's own checks, already run — so a preview reports each
/// warning once and compresses nothing.
UnpackPlan planCollected(
  BundleArchive archive,
  Manifest manifest, {
  Map<String, String> vars = const {},
  Map<String, String> recorded = const {},
  VariableResolver? resolver,
  WarningSink? onWarning,
}) => const Unbundler()._plan(
  archive,
  manifest,
  targetDir: null,
  vars: vars,
  recorded: recorded,
  resolver: resolver,
  overwrite: false,
  stamp: false,
  withContent: true,
  onWarning: onWarning,
);

/// What a failed `Unbundler.apply` has to put back, recorded as it goes.
///
/// Best-effort by design: a failure while undoing is collected rather than
/// thrown, because the write error that triggered the undo is the one worth
/// reporting, and masking it with a cleanup error would hide the cause.
class _Undo {
  _Undo(this._root, {required this._preexisting});

  final String _root;

  /// Whether [_root] existed before the unpack — deleting a directory the
  /// user already had would turn a failed unpack into data loss.
  final bool _preexisting;

  /// Files that did not exist before.
  final List<File> _created = [];

  /// Files that did, with the bytes they held.
  final Map<String, List<int>> _replaced = {};

  /// Directories that did not exist before, outermost first.
  final List<Directory> _dirs = [];

  /// Directories known to exist, so a parent shared by many files is checked
  /// once rather than once per file.
  final Set<String> _present = {};

  /// Creates [dir] and its missing parents, remembering which were missing.
  void createParents(Directory dir) {
    if (_present.contains(dir.path)) {
      return;
    }
    final missing = <Directory>[];
    for (
      var d = dir;
      !_present.contains(d.path) && !d.existsSync() && d.path != d.parent.path;
      d = d.parent
    ) {
      missing.add(d);
    }
    dir.createSync(recursive: true);
    _dirs.addAll(missing.reversed);
    _present.add(dir.path);
  }

  /// Records [file] as about to be written: as created when it is not there,
  /// or with its current bytes when it is.
  ///
  /// The bytes are held in memory. They are at most one file per archive
  /// entry, and the archive itself is already held in memory whole.
  ///
  /// [current] is the file's content when the caller has just read it.
  void recordWrite(File file, {List<int>? current}) {
    // Into a directory this unpack created, nothing can be there yet.
    if (current != null) {
      _replaced.putIfAbsent(file.path, () => current);
    } else if (_preexisting && file.existsSync()) {
      _replaced.putIfAbsent(file.path, file.readAsBytesSync);
    } else {
      _created.add(file);
    }
  }

  /// Undoes everything recorded; returns the paths it could not restore.
  List<String> run() {
    if (!_preexisting) {
      // Everything under it is ours, so there is nothing to restore.
      return _attempt(() => Directory(_root).deleteSync(recursive: true))
          ? const []
          : [_root];
    }

    final failed = <String>[
      for (final file in _created)
        if (!_attempt(() {
          if (file.existsSync()) {
            file.deleteSync();
          }
        }))
          file.path,
      for (final MapEntry(key: path, value: bytes) in _replaced.entries)
        if (!_attempt(() => File(path).writeAsBytesSync(bytes))) path,
    ];
    // Innermost first, and only while empty: a directory the unpack created
    // can since have gained a file of someone else's.
    for (final dir in _dirs.reversed) {
      _attempt(dir.deleteSync);
    }

    return failed;
  }

  static bool _attempt(void Function() action) {
    try {
      action();
      return true;
    } on FileSystemException {
      return false;
    }
  }
}

/// Finds where a variable's **value** already occurs in the template.
///
/// Unpacking `super_server` as `my_app` into a template that already has a
/// `MyApp` class gives two classes called `MyApp`: the renamed one and the one
/// that was there. Paths that converge are a `RENAME_COLLISION`; this is the
/// same loss in content, where nothing else would notice — the two sites are
/// spelled alike from then on and cannot be told apart.
///
/// Searched in the content substitution's own scan (see `Watching`), so an
/// occurrence a substitution consumes — the value inside a longer token — is
/// not reported, and finding them costs no second pass; a match must also be
/// a whole word by the casing's rule.
class _Presence {
  factory _Presence(
    Manifest manifest,
    Map<String, String> resolved,
    _Rules rules,
  ) {
    const converter = CaseConverter();
    final needles = <String, (CasingNeedle, String, String)>{};
    for (final variable in manifest.variables) {
      final replaces = variable.replaces;
      final value = resolved[variable.name];
      if (replaces == null || value == null) {
        continue;
      }
      // Value casing → the token casing that becomes it.
      final becomes = {
        for (final MapEntry(:key, :value)
            in converter.replacements(replaces, value).entries)
          value: key,
      };
      for (final needle in CasingNeedle.casingsOf(value)) {
        final from = becomes[needle.text];
        if (from == null || from == needle.text) {
          continue; // An identity rename makes nothing ambiguous.
        }
        needles.putIfAbsent(needle.text, () => (needle, variable.name, from));
      }
    }

    return _Presence._(
      needles,
      rules.contentSubstitutor.watching(needles.keys),
      rules.pathSubstitutor.watching(needles.keys),
    );
  }

  _Presence._(this._needles, this._content, this._paths);

  /// Value casing → its rule, its variable, and the token casing that turns
  /// into it.
  final Map<String, (CasingNeedle, String, String)> _needles;

  /// The content substitution, watching for the value casings — so finding
  /// them rides on the substitution's own scan instead of a second one.
  final Watching _content;

  /// The same for paths, so a path a rename rewrites is not reported — the
  /// content and path checks decide alike.
  final Watching _paths;

  /// Value casing → the files holding it, once per occurrence.
  final Map<String, List<String>> _found = {};

  /// Where the archive entry [from] lands, after path substitution — noting
  /// the value casings its path holds in the same pass.
  ///
  /// Containment of the result is `RenameValidator`'s to check, over the
  /// whole mapping — substitution can produce a path no archive entry had.
  String rename(String from) => _paths
      .applyCounted(from, (found, start) => _hit(from, found, start, from))
      .$1;

  /// Substitutes [text], the content of [file], noting the value casings it
  /// meets.
  (String, int) substitute(String file, String text) =>
      _content.applyCounted(text, (found, start) {
        _hit(text, found, start, file);
      });

  void _hit(String hay, String found, int start, String file) {
    final needle = _needles[found];
    if (needle != null && needle.$1.isWholeAt(hay, start)) {
      (_found[found] ??= []).add(file);
    }
  }

  /// One warning per variable whose value was found.
  List<ValidationError> warnings() {
    final byVariable = <String, List<String>>{};
    for (final MapEntry(key: spelling, value: files) in _found.entries) {
      final (_, variable, from) = _needles[spelling]!;
      (byVariable[variable] ??= []).add(
        "'$spelling' ${files.length} time(s), in ${sample(files.toSet())} — "
        "where '$from' also becomes it",
      );
    }

    return [
      for (final MapEntry(key: variable, value: sites) in byVariable.entries)
        ValidationError.warning(
          VariablesValidator.valuePresent,
          "Variable '$variable': its value already occurs in the template: "
          '${sites.join('; ')}. After unpacking, those sites and the renamed '
          'ones are spelled alike and can no longer be told apart.',
          field: variable,
        ),
    ];
  }
}

/// The substitution rules for one unpack, derived once from the manifest and
/// the resolved variables.
///
/// Everything `Unbundler.plan` decides about a file goes through this, and
/// `Unbundler.apply` only writes what the plan holds, so a preview and a real
/// unpack cannot decide differently about any file.
class _Rules {
  factory _Rules(Manifest manifest, Map<String, String> resolved) {
    // Built once and shared: an initializer list cannot hold a local, so the
    // two substitutors used to derive every variable's casings separately.
    final renames = _buildTable(manifest, resolved);

    return _Rules._(
      pathSubstitutor: Substitutor({
        ...renames,
        ..._render(manifest.pathRenames, resolved),
      }),
      // Templates are rendered *before* the table is built, so the result
      // enters the same single-pass longest-first match as the renames. That
      // ordering is required, not incidental: `from: super_server.dev` (16
      // chars) must beat the rename key `super_server` (12) at the same
      // position, which a sequential renames-then-substitutions pass would
      // break.
      //
      // A rendered value is emitted verbatim and never re-scanned, and an
      // explicit substitution whose `from` equals a derived rename key wins,
      // because the spread puts it last.
      contentSubstitutor: Substitutor({
        ...renames,
        ..._render(manifest.extraSubstitutions, resolved),
      }),
      policy: ContentPolicy(manifest),
    );
  }

  const _Rules._({
    required this.pathSubstitutor,
    required this.contentSubstitutor,
    required this.policy,
  });

  /// Applied to file and directory paths.
  final Substitutor pathSubstitutor;

  /// Applied to text content.
  final Substitutor contentSubstitutor;

  /// Decides which files are substituted.
  final ContentPolicy policy;

  /// The UTF-8 byte-order mark.
  static const _utf8Bom = [0xEF, 0xBB, 0xBF];

  /// The decoded text of [bytes], or null when the entry is copied verbatim.
  String? decode(String key, List<int> bytes) => policy.decode(key, bytes);

  /// Encodes [text] back to bytes, restoring a BOM that [original] carried.
  ///
  /// `utf8.decode` silently drops a leading BOM and `utf8.encode` does not put
  /// it back, so a substituted file would lose three bytes on every unpack —
  /// even under an identity rename. Common in Windows-authored .bat, .ps1 and
  /// .csproj files.
  Uint8List encode(List<int> original, String text) {
    final encoded = utf8.encode(text);
    if (!_startsWithBom(original)) {
      return encoded;
    }

    return Uint8List(_utf8Bom.length + encoded.length)
      ..setAll(0, _utf8Bom)
      ..setAll(_utf8Bom.length, encoded);
  }

  static bool _startsWithBom(List<int> bytes) =>
      bytes.length >= 3 &&
      bytes[0] == _utf8Bom[0] &&
      bytes[1] == _utf8Bom[1] &&
      bytes[2] == _utf8Bom[2];

  /// Renders each substitution's `to` template against [resolved].
  ///
  /// Rendering is late by necessity: the archive embeds `mold.yaml` verbatim
  /// and variable values are known only at unpack. Everything statically
  /// decidable — syntax, unknown variable, unknown transform — was already
  /// rejected by `ManifestValidator`, which runs at both pack and unpack.
  static Map<String, String> _render(
    List<Substitution> substitutions,
    Map<String, String> resolved,
  ) => {
    for (final s in substitutions)
      s.from: SubstitutionTemplate.parse(s.to).render(resolved),
  };

  /// Builds the case-variant replacement table from each variable's `replaces`
  /// token and its already-resolved value.
  ///
  /// Every declared variable has a value by now — `VariablesValidator` reports
  /// any that does not — so a missing one is a bug, not an input problem.
  static Map<String, String> _buildTable(
    Manifest manifest,
    Map<String, String> resolved,
  ) {
    const converter = CaseConverter();
    final table = <String, String>{};
    for (final variable in manifest.variables) {
      final replaces = variable.replaces;
      if (replaces == null) {
        continue;
      }

      final value = resolved[variable.name];
      if (value == null) {
        throw StateError(
          "No value was resolved for variable '${variable.name}'.",
        );
      }
      table.addAll(converter.replacements(replaces, value));
    }

    return table;
  }
}

/// What `Unbundler.inspect` reports about a template archive.
class TemplateInfo {
  const TemplateInfo({
    required this.manifest,
    required this.manifestYaml,
    required this.sizes,
    this.executable = const {},
  });

  /// The embedded manifest.
  final Manifest manifest;

  /// The embedded `mold.yaml`, as written.
  final String manifestYaml;

  /// Each file's path inside the archive — before renaming — and its size in
  /// bytes, in archive order.
  final Map<String, int> sizes;

  /// The paths recorded as owner-executable.
  final Set<String> executable;

  /// The paths, in archive order.
  Iterable<String> get files => sizes.keys;

  /// Total bytes across every file.
  int get totalBytes => sizes.values.fold(0, (sum, n) => sum + n);
}
