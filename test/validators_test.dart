import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mold/mold.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Matches a result carrying an error-severity issue with the given code.
Matcher rejectsWith(String code) => predicate<ValidationResult>(
  (r) => !r.isValid && r.errors.any((e) => e.code == code),
  'rejected with error code $code',
);

/// Matches a result that is valid but carries a warning with the given code.
Matcher warnsWith(String code) => predicate<ValidationResult>(
  (r) => r.isValid && r.warnings.any((e) => e.code == code),
  'warned with code $code',
);

void main() {
  group('ValidationResult', () {
    test('throwIfInvalid throws on an error', () {
      final r = ValidationResult([
        const ValidationError('X', 'boom'),
      ]);
      expect(r.isValid, isFalse);
      expect(r.throwIfInvalid, throwsA(isA<ValidationException>()));
    });

    test('throwIfInvalid does not throw on warnings alone', () {
      final r = ValidationResult([
        const ValidationError.warning('W', 'heads up'),
      ]);
      expect(r.isValid, isTrue);
      expect(r.warnings, hasLength(1));
      r.throwIfInvalid(); // no throw
    });
  });

  group('ManifestValidator', () {
    const validator = ManifestValidator();

    group('accepts', () {
      test('a complete manifest', () {
        final m = Manifest.fromYaml('name: super_server\nversion: 1.0.0\n');
        expect(validator.validate(m).isValid, isTrue);
      });
    });

    group('rejects', () {
      test('MANIFEST_MISSING_NAME', () {
        final m = Manifest.fromYaml('version: 1.0.0\n');
        expect(
          validator.validate(m),
          rejectsWith(ManifestValidator.missingName),
        );
      });

      test('MANIFEST_MISSING_VERSION', () {
        final m = Manifest.fromYaml('name: super_server\n');
        expect(
          validator.validate(m),
          rejectsWith(ManifestValidator.missingVersion),
        );
      });

      test('MANIFEST_UNSUPPORTED_REPLACES', () {
        // Splits into zero ASCII words, so it would substitute nothing.
        final m = Manifest.fromYaml(
          'name: x\nversion: 1\n'
          'variables:\n  a:\n    replaces: приложение\n',
        );
        expect(
          validator.validate(m),
          rejectsWith(ManifestValidator.unsupportedReplaces),
        );
      });

      test('MANIFEST_DUPLICATE_VARIABLE', () {
        // YAML map keys can't duplicate, so build the manifest directly.
        const m = Manifest(
          name: 'x',
          version: '1',
          variables: [
            TemplateVariable(name: 'a', replaces: 'foo'),
            TemplateVariable(name: 'a', replaces: 'bar'),
          ],
        );
        expect(
          validator.validate(m),
          rejectsWith(ManifestValidator.duplicateVariable),
        );
      });

      test('MANIFEST_INVALID_GLOB', () {
        final m = Manifest.fromYaml('''
name: x
version: 1
include:
  - "a["
''');
        expect(
          validator.validate(m),
          rejectsWith(ManifestValidator.invalidGlob),
        );
      });

      test('MANIFEST_EMPTY_REPLACES', () {
        final m = Manifest.fromYaml('''
name: x
version: 1
variables:
  p:
    replaces: ""
''');
        expect(
          validator.validate(m),
          rejectsWith(ManifestValidator.emptyReplaces),
        );
      });
    });
  });

  group('ProjectValidator', () {
    const validator = ProjectValidator();
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_pv_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Manifest withVar(String replaces) => Manifest(
      name: 'x',
      version: '1',
      variables: [TemplateVariable(name: 'p', replaces: replaces)],
    );

    void writeFile(String rel, String content) {
      File(p.join(tmp.path, rel))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    group('accepts', () {
      test('a non-empty dir where the token occurs standalone', () {
        writeFile('a.txt', 'const x = "super_server";');
        final r = validator.validate(
          ProjectInput(dir: tmp.path, manifest: withVar('super_server')),
        );
        expect(r.isValid, isTrue);
        expect(r.warnings, isEmpty);
      });
    });

    group('rejects', () {
      test('PROJECT_DIR_NOT_FOUND', () {
        final r = validator.validate(
          ProjectInput(
            dir: p.join(tmp.path, 'nope'),
            manifest: withVar('super_server'),
          ),
        );
        expect(r, rejectsWith(ProjectValidator.dirNotFound));
      });

      test('PROJECT_DIR_EMPTY', () {
        final r = validator.validate(
          ProjectInput(dir: tmp.path, manifest: withVar('super_server')),
        );
        expect(r, rejectsWith(ProjectValidator.dirEmpty));
      });

      test('PROJECT_REPLACES_NOT_FOUND', () {
        writeFile('a.txt', 'nothing relevant here');
        final r = validator.validate(
          ProjectInput(dir: tmp.path, manifest: withVar('super_server')),
        );
        expect(r, rejectsWith(ProjectValidator.replacesNotFound));
      });
    });

    group('warns', () {
      test('PROJECT_PARTIAL_OVERLAP on partial-name overlap', () {
        // 'server' only ever appears inside 'observer' — overlap, not absent.
        writeFile('a.txt', 'class observer {}');
        final r = validator.validate(
          ProjectInput(dir: tmp.path, manifest: withVar('server')),
        );
        expect(r, warnsWith(ProjectValidator.partialOverlap));
      });
    });
  });

  group('ArchiveValidator', () {
    const validator = ArchiveValidator();

    List<int> gz(Archive a) =>
        const GZipEncoder().encode(TarEncoder().encode(a));

    group('accepts', () {
      test('a well-formed archive', () {
        final bytes = const ArchiveWriter().write(
          manifestYaml: 'name: x\nversion: 1\n',
          files: {
            'a.txt': [1, 2, 3],
          },
        );
        expect(validator.validate(bytes).isValid, isTrue);
      });
    });

    group('rejects', () {
      test('ARCHIVE_INVALID', () {
        expect(
          validator.validate([1, 2, 3, 4]),
          rejectsWith(ArchiveValidator.invalid),
        );
      });

      test('ARCHIVE_MISSING_MANIFEST', () {
        final a = Archive()..addFile(ArchiveFile('files/a.txt', 3, [1, 2, 3]));
        expect(
          validator.validate(gz(a)),
          rejectsWith(ArchiveValidator.missingManifest),
        );
      });

      test('ARCHIVE_MISSING_FILES', () {
        final bytes = const ArchiveWriter().write(
          manifestYaml: 'name: x\nversion: 1\n',
          files: const {},
        );
        expect(
          validator.validate(bytes),
          rejectsWith(ArchiveValidator.missingFiles),
        );
      });
    });
  });

  group('VariablesValidator', () {
    const validator = VariablesValidator();
    const projectName = TemplateVariable(name: 'p', replaces: 'super_server');

    group('accepts', () {
      test('all required present and well-formed', () {
        final r = validator.validate(
          const VariablesInput(
            variables: [projectName],
            values: {'p': 'my_project'},
          ),
        );
        expect(r.isValid, isTrue);
      });
    });

    group('rejects', () {
      test('VARIABLE_MISSING', () {
        final r = validator.validate(
          const VariablesInput(variables: [projectName], values: {}),
        );
        expect(r, rejectsWith(VariablesValidator.missing));
      });

      test('a variable with a default is not missing when absent', () {
        // The validator is public: a caller may pass a map covering only the
        // variables it wants to override, leaving defaults to fill the rest.
        const withDefault = TemplateVariable(
          name: 'p',
          defaultValue: 'my_project',
          replaces: 'super_server',
        );
        final r = validator.validate(
          const VariablesInput(variables: [withDefault], values: {}),
        );
        expect(r.isValid, isTrue);
      });

      test('VARIABLE_INVALID_FORMAT', () {
        final r = validator.validate(
          const VariablesInput(
            variables: [projectName],
            values: {'p': '1-bad start'},
          ),
        );
        expect(r, rejectsWith(VariablesValidator.invalidFormat));
      });
    });
  });

  group('TargetValidator', () {
    const validator = TargetValidator();
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('mold_tv_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    group('accepts', () {
      test('a fresh target under an existing parent', () {
        final r = validator.validate(p.join(tmp.path, 'fresh'));
        expect(r.isValid, isTrue);
      });
    });

    group('rejects', () {
      test('TARGET_PARENT_NOT_FOUND', () {
        final r = validator.validate(p.join(tmp.path, 'no', 'child'));
        expect(r, rejectsWith(TargetValidator.parentNotFound));
      });

      test('TARGET_OCCUPIED', () {
        final occupied = Directory(p.join(tmp.path, 'taken'))..createSync();
        File(p.join(occupied.path, 'f')).writeAsStringSync('x');
        final r = validator.validate(occupied.path);
        expect(r, rejectsWith(TargetValidator.occupied));
      });

      test(
        'TARGET_NOT_WRITABLE',
        () {
          final ro = Directory(p.join(tmp.path, 'ro'))..createSync();
          Process.runSync('chmod', ['500', ro.path]);
          addTearDown(() => Process.runSync('chmod', ['700', ro.path]));
          final r = validator.validate(p.join(ro.path, 'child'));
          expect(r, rejectsWith(TargetValidator.notWritable));
        },
        skip: Platform.isWindows ? 'POSIX permissions only' : null,
      );
    });
  });
}
