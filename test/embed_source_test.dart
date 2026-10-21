import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/internals.dart';

/// Extracts the `<int>[ ... ]` payload from a `bytes` source back into a list.
List<int> parseBytesSource(String src) {
  final start = src.indexOf('<int>[') + '<int>['.length;
  final end = src.indexOf('];', start);
  return src
      .substring(start, end)
      .split('\n')
      .where((line) => !line.trim().startsWith('//'))
      .join()
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map(int.parse)
      .toList();
}

/// Extracts and decodes the base64 literal from a `base64` source.
List<int> parseBase64Source(String src) {
  final match = RegExp("'([A-Za-z0-9+/=]*)'").firstMatch(src)!;
  return base64.decode(match.group(1)!);
}

void main() {
  group('EmbedSource', () {
    const embed = EmbedSource();
    final archive = List<int>.generate(40, (i) => (i * 7) % 256);

    test('derives a k<Pascal>Template const name', () {
      expect(embed.constName('super_server'), 'kSuperServerTemplate');
    });

    test('bytes source carries the no-edit header and const declaration', () {
      final src = embed.bytesSource(archive: archive, name: 'super_server');
      expect(src, contains('AUTO-GENERATED — DO NOT EDIT'));
      expect(src, contains('const List<int> kSuperServerTemplate = <int>['));
    });

    test('bytes source round-trips back to the exact archive bytes', () {
      final src = embed.bytesSource(archive: archive, name: 'super_server');
      expect(parseBytesSource(src), archive);
    });

    test('base64 source carries the no-edit header and const declaration', () {
      final src = embed.base64Source(archive: archive, name: 'super_server');
      expect(src, contains('AUTO-GENERATED — DO NOT EDIT'));
      expect(src, contains('const String kSuperServerTemplateBase64 ='));
    });

    test('base64 source round-trips back to the exact archive bytes', () {
      final src = embed.base64Source(archive: archive, name: 'super_server');
      expect(parseBase64Source(src), archive);
    });

    test('both formats tell analyzers to skip lints', () {
      for (final src in [
        embed.bytesSource(archive: archive, name: 'super_server'),
        embed.base64Source(archive: archive, name: 'super_server'),
      ]) {
        expect(src, startsWith('// AUTO-GENERATED — DO NOT EDIT.\n'));
        expect(src, contains('\n// ignore_for_file: type=lint\n'));
      }
    });
  });

  group('EmbedSource output under consumer tooling', () {
    const embed = EmbedSource();
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_embed_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// Writes [source] as `<stem>.dart`, and again pinned to a pre-3.7
    /// language version: the formatter picks its style per language version,
    /// and a consumer may be on either.
    void writeBothStyles(String stem, String source) {
      File(p.join(tmp.path, '$stem.dart')).writeAsStringSync(source);
      File(
        p.join(tmp.path, '${stem}_short.dart'),
      ).writeAsStringSync('// @dart=3.6\n$source');
    }

    Future<ProcessResult> dart(List<String> args) =>
        Process.run(Platform.resolvedExecutable, args);

    test('dart format leaves the generated sources unchanged', () async {
      // Sizes around a row of 15 and around the 80-column base64 line; rows
      // of 255 are the widest a row gets.
      for (final length in [0, 1, 14, 15, 16, 29, 30, 31, 100]) {
        for (final fill in [0, 255]) {
          writeBothStyles(
            'bytes_${length}_$fill',
            embed.bytesSource(
              archive: List.filled(length, fill),
              name: 'super_server',
            ),
          );
        }
      }
      for (var length = 0; length <= 40; length++) {
        writeBothStyles(
          'base64_$length',
          embed.base64Source(
            archive: List.generate(length, (i) => i),
            name: 'super_server',
          ),
        );
      }

      final result = await dart([
        'format',
        '--output=none',
        '--show=changed',
        '--set-exit-if-changed',
        tmp.path,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}');
    });

    test('opposing strict lint sets both report nothing', () async {
      // Each set takes one side of every disagreement the declarations could
      // trip, so no spelling of them satisfies both — only skipping lints
      // does. Two packages, because one analysis_options.yaml refuses
      // incompatible rules.
      const shared = [
        'public_member_api_docs',
        'lines_longer_than_80_chars',
        'require_trailing_commas',
        'eol_at_end_of_file',
      ];
      final sets = {
        'omit': [
          'omit_obvious_property_types',
          'omit_local_variable_types',
          'prefer_single_quotes',
          ...shared,
        ],
        'specify': [
          'always_specify_types',
          'type_annotate_public_apis',
          'prefer_double_quotes',
          ...shared,
        ],
      };
      for (final MapEntry(key: name, value: rules) in sets.entries) {
        final dir = Directory(p.join(tmp.path, name))..createSync();
        File(p.join(dir.path, 'analysis_options.yaml')).writeAsStringSync(
          [
            'analyzer:',
            '  language:',
            '    strict-casts: true',
            '    strict-inference: true',
            '    strict-raw-types: true',
            'linter:',
            '  rules:',
            for (final rule in rules) '    - $rule',
          ].join('\n'),
        );
        File(p.join(dir.path, 'template.dart')).writeAsStringSync(
          embed.bytesSource(
            archive: List.generate(100, (i) => i * 3 % 256),
            name: 'super_server',
          ),
        );
        File(p.join(dir.path, 'template_base64.dart')).writeAsStringSync(
          embed.base64Source(
            archive: List.generate(100, (i) => i),
            name: 'super_server',
          ),
        );
      }

      final result = await dart(['analyze', '--fatal-infos', tmp.path]);

      expect(result.exitCode, 0, reason: '${result.stdout}');
    });
  });
}
