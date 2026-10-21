import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../archive/archive_reader.dart';
import '../archive/archive_writer.dart';
import '../manifest/manifest.dart';
import '../manifest/manifest_validator.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import 'project_validator.dart';

/// Packs a source project into a template archive.
///
/// The source directory is read but never mutated. Files are captured
/// **verbatim** — no substitution happens at pack time, so one archive can be
/// unpacked under many names.
///
/// Problems with the inputs — the manifest, the project — throw a
/// [ValidationException] carrying stable codes; a failing filesystem throws an
/// [IOException].
class Bundler {
  const Bundler({
    this.compressionLevel = ArchiveWriter.defaultLevel,
    this.fastCompression = false,
  });

  /// The gzip level, 0 (store) to 9 (smallest). See [ArchiveWriter].
  final int compressionLevel;

  /// Compress with the VM's zlib: about 2.7x faster, but the bytes may differ
  /// across platforms and SDKs. See [ArchiveWriter].
  final bool fastCompression;

  /// Packs [projectDir] per [manifest] and returns the archive bytes.
  ///
  /// The result is always the gzipped-tar archive; choosing a `bytes` /
  /// `base64` embed source is an output-emission concern handled separately.
  ///
  /// [onWarning] receives non-fatal problems that would otherwise be silent,
  /// such as a symlink left out of the archive or a `replaces` token that will
  /// over-reach.
  Future<List<int>> bundle({
    required String projectDir,
    required Manifest manifest,
    WarningSink? onWarning,
  }) async {
    final collected = collectBundle(
      projectDir: projectDir,
      manifest: manifest,
      onWarning: onWarning,
    );

    return ArchiveWriter(
      compressionLevel: compressionLevel,
      fastCompression: fastCompression,
    ).write(
      manifestYaml: collected.manifestYaml,
      files: collected.files,
      executable: collected.executable,
    );
  }
}

/// What [Bundler.bundle] packs, validated and read but not yet compressed.
///
/// Not exported. `pack --check` compares this with the committed archive:
/// compressing an archive only to unpack it again for the comparison was most
/// of the check's time.
BundleArchive collectBundle({
  required String projectDir,
  required Manifest manifest,
  WarningSink? onWarning,
}) {
  // Warnings are reported before the throw, not after: ProjectValidator
  // builds its skipped-symlink warnings ahead of the empty-dir error because
  // they are the explanation for it. See ValidationResult.report.
  void report(ValidationResult result) => result.report(onWarning);

  // Phase order: manifest → project. The first failing phase aborts.
  report(const ManifestValidator().validate(manifest));

  // Scanned once and handed to the validator, which would otherwise walk the
  // same tree — re-reading and re-compiling every .gitignore — to check the
  // files this method then reads. Skipped for a missing directory: the walk
  // would throw a bare FileSystemException before the validator could report
  // the far more useful PROJECT_DIR_NOT_FOUND.
  final scanned = Directory(projectDir).existsSync()
      ? ProjectValidator.scanFor(projectDir, manifest)
      : null;
  // Read before validating, and handed over with the scan: the validator
  // searches every file's content, and reading each one a second time to
  // pack it held the corpus in memory twice. A file that cannot be read is
  // left out for now and read again below, so its error comes after the
  // project's warnings rather than in place of them.
  final files = <String, Uint8List>{
    for (final rel in scanned?.files ?? const <String>[])
      rel: ?_tryRead(p.join(projectDir, rel)),
  };
  report(
    const ProjectValidator().validate(
      ProjectInput(
        dir: projectDir,
        manifest: manifest,
        scan: scanned,
        contents: files,
      ),
    ),
  );

  // Normally non-null past the validator, which turns a missing directory
  // into an error `report` throws on. Falling back rather than asserting
  // covers the one case where it is not: a directory created between the
  // check above and the validator's own, where `!` would raise a TypeError
  // no layer catches.
  final scan = scanned ?? ProjectValidator.scanFor(projectDir, manifest);
  for (final rel in scan.files) {
    files[rel] ??= File(p.join(projectDir, rel)).readAsBytesSync();
  }

  // A manifest read from a file embeds byte-for-byte; one built in code is
  // rendered by the Manifest itself, which knows all of its fields.
  return BundleArchive(
    manifestYaml: manifest.source ?? manifest.toYaml(),
    files: files,
    executable: scan.executable,
  );
}

Uint8List? _tryRead(String path) {
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException {
    return null;
  }
}
