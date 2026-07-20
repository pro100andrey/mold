import 'dart:io';

import 'package:path/path.dart' as p;

import '../archive/archive_writer.dart';
import '../manifest/manifest.dart';
import '../manifest/manifest_validator.dart';
import 'file_scanner.dart';
import 'project_validator.dart';

/// The public packing contract: scan a project and return the archive bytes.
///
/// The result is always the gzipped-tar archive; choosing a `bytes` / `base64`
/// embed source is an output-emission concern handled separately.
abstract class BundlerBase {
  /// Packs [projectDir] per [manifest] and returns the archive bytes.
  Future<List<int>> bundle({
    required String projectDir,
    required Manifest manifest,
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
  }) async {
    // Phase order: manifest → project. The first failing phase aborts.
    const ManifestValidator().validate(manifest).throwIfInvalid();
    const ProjectValidator()
        .validate(ProjectInput(dir: projectDir, manifest: manifest))
        .throwIfInvalid();

    final scanner = FileScanner(
      include: manifest.include,
      exclude: manifest.exclude,
    );
    final relPaths = scanner.scan(projectDir).files;

    final files = <String, List<int>>{};
    final executable = <String>{};
    for (final rel in relPaths) {
      final file = File(p.join(projectDir, rel));
      files[rel] = file.readAsBytesSync();
      // 0o100 — owner-execute. Recorded so a template's scripts and hooks
      // do not unpack as non-executable.
      if (file.statSync().mode & 64 != 0) {
        executable.add(rel);
      }
    }

    // A manifest read from a file embeds byte-for-byte; one built in code is
    // rendered by the Manifest itself, which knows all of its fields.
    final manifestYaml = manifest.source ?? manifest.toYaml();

    return const ArchiveWriter().write(
      manifestYaml: manifestYaml,
      files: files,
      executable: executable,
    );
  }
}
