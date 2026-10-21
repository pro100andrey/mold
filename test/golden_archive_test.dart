import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/internals.dart';

/// Packing must give the same bytes on every OS and SDK, not only on the
/// machine that wrote the archive — a `-f bytes` source committed on macOS
/// and regenerated on Linux CI must not differ. These archives were written
/// once and committed; every platform in CI must reproduce them exactly.
///
/// After an intended change to the archive layout, regenerate with
/// `MOLD_UPDATE_GOLDEN=1 dart test test/golden_archive_test.dart`.
void main() {
  final update = Platform.environment['MOLD_UPDATE_GOLDEN'] == '1';
  final golden = p.join('test', 'golden');

  void matchesGolden(List<int> bytes, String name) {
    final file = File(p.join(golden, name));
    if (update) {
      file
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);
    }

    expect(
      bytes,
      file.readAsBytesSync(),
      reason:
          '$name differs from the committed archive. If the layout changed '
          'on purpose, regenerate with MOLD_UPDATE_GOLDEN=1.',
    );
  }

  // Fixed inputs written by the test, not checked-out files: line endings and
  // modes of a checkout vary by platform, and those are not what is tested.
  const manifest =
      'name: golden\n'
      'version: 1.0.0\n'
      'variables:\n'
      '  name:\n'
      '    replaces: golden\n';
  final files = <String, List<int>>{
    'lib/golden.dart': 'class Golden {}\n'.codeUnits,
    'README.md':
        '# golden\n\nA fixture for byte-for-byte reproducibility.\n'.codeUnits,
    'bin/run.sh': '#!/bin/sh\necho golden\n'.codeUnits,
    'assets/blob.bin': List<int>.generate(512, (i) => (i * 31) % 256),
  };

  for (final level in [0, 6, 9]) {
    test('the archive at level $level', () {
      final bytes = ArchiveWriter(compressionLevel: level).write(
        manifestYaml: manifest,
        files: files,
        executable: {'bin/run.sh'},
      );

      matchesGolden(bytes, 'level_$level.mold');
    });
  }

  test('every gzip header is the same fixed one', () {
    for (final fast in [false, true]) {
      final bytes = ArchiveWriter(fastCompression: fast).write(
        manifestYaml: manifest,
        files: files,
      );

      expect(bytes.sublist(0, 10), [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 255]);
    }
  });

  test('both compressors hold the same content', () {
    BundleArchive open(bool fast) => const ArchiveReader().read(
      ArchiveWriter(fastCompression: fast).write(
        manifestYaml: manifest,
        files: files,
        executable: {'bin/run.sh'},
      ),
    );

    expect(ArchiveDiff(open(false), open(true)).isEmpty, isTrue);
  });

  test('EmbedSource reads back the archive it rendered', () {
    final archive = const ArchiveWriter().write(
      manifestYaml: manifest,
      files: files,
    );
    const embed = EmbedSource();

    expect(
      embed.archiveOf(embed.bytesSource(archive: archive, name: 'golden')),
      archive,
    );
    expect(
      embed.archiveOf(embed.base64Source(archive: archive, name: 'golden')),
      archive,
    );
    expect(embed.archiveOf('void main() {}'), isNull);
  });
}
