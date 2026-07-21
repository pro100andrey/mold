import 'dart:io';

import 'package:path/path.dart' as p;

import '../archive/archive_writer.dart';
import '../manifest/manifest.dart';
import '../manifest/manifest_validator.dart';
import '../validation/validation_result.dart';
import 'project_validator.dart';

/// The public packing contract: scan a project and return the archive bytes.
///
/// The result is always the gzipped-tar archive; choosing a `bytes` / `base64`
/// embed source is an output-emission concern handled separately.
abstract class BundlerBase {
  /// Packs [projectDir] per [manifest] and returns the archive bytes.
  ///
  /// [onWarning] receives non-fatal problems that would otherwise be silent,
  /// such as a symlink left out of the archive or a `replaces` token that will
  /// over-reach.
  Future<List<int>> bundle({
    required String projectDir,
    required Manifest manifest,
    void Function(String message)? onWarning,
  });
}

/// Packs a source project into a template archive.
///
/// The source directory is read but never mutated. Files are captured
/// **verbatim** — no substitution happens at pack time, so one archive can be
/// unpacked under many names.
class Bundler implements BundlerBase {
  const Bundler();

  @override
  Future<List<int>> bundle({
    required String projectDir,
    required Manifest manifest,
    void Function(String message)? onWarning,
  }) async {
    // Warnings are reported BEFORE throwIfInvalid, not after. ProjectValidator
    // deliberately builds its skipped-symlink warnings ahead of the empty-dir
    // error because they are the explanation for it; reporting after the throw
    // would drop exactly the case they exist for.
    void report(ValidationResult result) {
      for (final warning in result.warnings) {
        onWarning?.call(warning.toString());
      }

      result.throwIfInvalid();
    }

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
    report(
      const ProjectValidator().validate(
        ProjectInput(dir: projectDir, manifest: manifest, scan: scanned),
      ),
    );

    // Normally non-null past the validator, which turns a missing directory
    // into an error `report` throws on. Falling back rather than asserting
    // covers the one case where it is not: a directory created between the
    // check above and the validator's own, where `!` would raise a TypeError
    // no layer catches.
    final scan = scanned ?? ProjectValidator.scanFor(projectDir, manifest);
    final files = <String, List<int>>{};
    for (final rel in scan.files) {
      files[rel] = File(p.join(projectDir, rel)).readAsBytesSync();
    }

    // A manifest read from a file embeds byte-for-byte; one built in code is
    // rendered by the Manifest itself, which knows all of its fields.
    final manifestYaml = manifest.source ?? manifest.toYaml();

    return const ArchiveWriter().write(
      manifestYaml: manifestYaml,
      files: files,
      executable: scan.executable,
    );
  }
}
