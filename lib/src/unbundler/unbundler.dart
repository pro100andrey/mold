import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../archive/archive_reader.dart';
import '../archive/archive_validator.dart';
import '../manifest/content_policy.dart';
import '../manifest/manifest.dart';
import '../manifest/manifest_validator.dart';
import '../manifest/substitution_template.dart';
import '../prompt/variable_resolver.dart';
import '../util/bytes.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import 'case_converter.dart';
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
    VariableResolver? resolver,
    bool overwrite = false,
    bool stamp = false,
    WarningSink? onWarning,
  }) async {
    final planned = plan(
      bytes: bytes,
      targetDir: targetDir,
      vars: vars,
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
    VariableResolver? resolver,
    bool overwrite = false,
    bool stamp = false,
    WarningSink? onWarning,
  }) async {
    await unbundle(
      bytes: readArchive(source),
      targetDir: targetDir,
      vars: vars,
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
  /// [onWarning] receives the same warnings a real unpack would report, so a
  /// preview is not quieter than the thing it previews.
  UnpackPlan plan({
    required List<int> bytes,
    String? targetDir,
    Map<String, String> vars = const {},
    VariableResolver? resolver,
    bool overwrite = false,
    bool stamp = false,
    bool withContent = true,
    WarningSink? onWarning,
  }) {
    final (archive, manifest) = _open(bytes, onWarning);
    // A null target means "no destination in mind" — previewing the
    // substitutions of a template that has not been distributed yet. Every
    // other phase still runs.
    final target = TargetValidator(overwrite: overwrite);
    if (targetDir != null) {
      target.validate(targetDir).report(onWarning);
    }

    final resolved = (resolver ?? const VariableResolver()).resolve(
      manifest.variables,
      vars,
    );
    const VariablesValidator()
        .validate(
          VariablesInput(
            variables: manifest.variables,
            values: resolved,
            explicit: vars,
          ),
        )
        .report(onWarning);

    // Without overwrite the target was just validated empty, so nothing in it
    // can be replaced and there is nothing to look at.
    final inspect = overwrite ? targetDir : null;
    final previous = inspect == null ? null : _readStamp(inspect, onWarning);
    final writeStamp = targetDir != null && (stamp || previous != null);

    final rules = _Rules(manifest, resolved);
    final renames = {
      for (final key in archive.files.keys) key: rules.rename(key),
      // In the mapping so a template file renamed onto the stamp's path is a
      // collision like any other, not a file the stamp silently replaces.
      if (writeStamp) _stampKey: UnpackStamp.fileName,
    };
    const RenameValidator().validate(renames).report(onWarning);

    if (inspect != null) {
      target.validateDestinations(inspect, renames.values).report(onWarning);
    }
    File? existing(String to) =>
        inspect == null ? null : File(p.join(inspect, to));

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
        ),
    ];
    final written = {for (final f in files) f.to};
    if (writeStamp) {
      final record = UnpackStamp(
        template: manifest.name,
        version: manifest.version,
        vars: resolved,
        files: written.toList()..sort(),
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
      stale: [
        for (final path in previous?.files ?? const <String>[])
          if (!written.contains(path) &&
              File(p.join(inspect!, path)).existsSync())
            path,
      ],
    );
  }

  /// The key the stamp takes in the rename mapping — not a legal archive
  /// path, so no entry can share it.
  static const _stampKey = '(mold stamp)';

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
    final stamp = UnpackStamp.tryParse(file.readAsStringSync());
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
  }) {
    final before = rules.decode(from, content);
    var replacements = 0;
    String? after;
    var bytes = content;
    if (before != null) {
      (after, replacements) = rules.substitute(before);
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

    return PlannedFile(
      from: from,
      to: to,
      verbatim: before == null,
      replacements: replacements,
      bytes: bytes,
      executable: executable,
      before: withContent ? before : null,
      after: withContent ? after : null,
      overwrites: onDisk != null,
      identicalToExisting: onDisk != null && sameBytes(onDisk, bytes),
      existing: withContent && onDisk != null ? _tryDecode(onDisk) : null,
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
        // Recorded before the write, so a write that fails halfway — a
        // truncated file — is undone too.
        undo
          ..createParents(out.parent)
          ..recordWrite(out);
        out.writeAsBytesSync(file.bytes);

        if (file.executable) {
          restoreExecutable.add(out.path);
        }
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
  void recordWrite(File file) {
    // Into a directory this unpack created, nothing can be there yet.
    if (_preexisting && file.existsSync()) {
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

  /// Where the archive entry [key] lands, after path substitution.
  ///
  /// Containment of the result is `RenameValidator`'s to check, over the
  /// whole mapping — substitution can produce a path no archive entry had.
  String rename(String key) => pathSubstitutor.apply(key);

  /// The decoded text of [bytes], or null when the entry is copied verbatim.
  String? decode(String key, List<int> bytes) => policy.decode(key, bytes);

  /// Applies the content substitutions to [text], counting them.
  (String, int) substitute(String text) =>
      contentSubstitutor.applyCounted(text);

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
    required this.sizes,
    this.executable = const {},
  });

  /// The embedded manifest.
  final Manifest manifest;

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
