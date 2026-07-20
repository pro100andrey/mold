import 'package:mold/mold.dart';
import 'package:test/test.dart';

void main() {
  group('FileClassifier', () {
    final classifier = FileClassifier();

    test('classifies known text extensions as text', () {
      for (final path in ['lib/main.dart', 'README.md', 'a/b.yaml', 'x.json']) {
        expect(classifier.classify(path), FileKind.text, reason: path);
      }
    });

    test('classifies extensionless files as text', () {
      for (final path in ['Makefile', 'LICENSE', 'bin/run']) {
        expect(classifier.isBinary(path), isFalse, reason: path);
      }
    });

    test('classifies known binary extensions as binary', () {
      for (final path in ['logo.png', 'f.woff2', 'data.sqlite', 'a/b.zip']) {
        expect(classifier.classify(path), FileKind.binary, reason: path);
      }
    });

    test('extension matching is case-insensitive', () {
      expect(classifier.isBinary('LOGO.PNG'), isTrue);
    });

    test('extraBinary augments the built-in set', () {
      final withProto = FileClassifier(extraBinary: {'proto', '.lockb'});
      expect(withProto.isBinary('schema.proto'), isTrue);
      expect(withProto.isBinary('bun.lockb'), isTrue);
      // Unaffected default classification still holds.
      expect(withProto.isBinary('main.dart'), isFalse);
    });
  });
}
