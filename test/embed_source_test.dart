import 'dart:convert';

import 'package:mold/mold.dart';
import 'package:test/test.dart';

/// Extracts the `<int>[ ... ]` payload from a `bytes` source back into a list.
List<int> parseBytesSource(String src) {
  final start = src.indexOf('<int>[') + '<int>['.length;
  final end = src.indexOf('];', start);
  return src
      .substring(start, end)
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map(int.parse)
      .toList();
}

/// Extracts and decodes the base64 literal from a `base64` source.
List<int> parseBase64Source(String src) {
  final match = RegExp("'([A-Za-z0-9+/=]+)'").firstMatch(src)!;
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
  });
}
