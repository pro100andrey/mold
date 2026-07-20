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
    final relPaths = scanner.scan(projectDir);

    final files = <String, List<int>>{};
    for (final rel in relPaths) {
      files[rel] = File(p.join(projectDir, rel)).readAsBytesSync();
    }

    final manifestYaml = manifest.source ?? _serialize(manifest);

    return const ArchiveWriter().write(
      manifestYaml: manifestYaml,
      files: files,
    );
  }

  /// Minimal YAML rendering for manifests built in code (no [Manifest.source]).
  String _serialize(Manifest manifest) {
    final buffer = StringBuffer()
      ..writeln('name: ${manifest.name}')
      ..writeln('version: ${manifest.version}');
    if (manifest.include.isNotEmpty) {
      buffer.writeln('include:');
      for (final g in manifest.include) {
        buffer.writeln('  - $g');
      }
    }

    if (manifest.exclude.isNotEmpty) {
      buffer.writeln('exclude:');
      for (final g in manifest.exclude) {
        buffer.writeln('  - $g');
      }
    }
    
    return buffer.toString();
  }
}
