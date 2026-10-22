import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../bundler/project_validator.dart';
import '../manifest/manifest.dart';
import '../manifest/substitution_template.dart';
import '../manifest/yaml_text.dart';
import '../prompt/variable_prompter.dart';
import '../unbundler/case_converter.dart';
import '../validation/validation_error.dart';
import 'command_base.dart';

/// `mold init [dir]` — write a starting `mold.yaml` for a project.
///
/// The manifest every template starts from is the same few lines: the
/// project's own name as the token, one variable replacing it, the manifest
/// kept out of what it packs. What takes the time is the spellings the four
/// derived casings miss — a camelCase bundle id, a Title Case label — so init
/// runs the pack's own check on the draft and offers the entries that cover
/// them.
class InitCommand extends MoldCommand {
  InitCommand(super.out, super.err, {LineReader? readLine})
    : _readLine = readLine ?? stdin.readLineSync {
    argParser
      ..addOption(
        'variable',
        defaultsTo: 'project_name',
        help: "The variable replacing the project's name.",
      )
      ..addOption(
        'token',
        help:
            "The name to replace (default: from the project's package "
            'manifest, else the directory name).',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Add the suggested extra_substitutions without asking.',
      )
      ..addFlag(
        'no-prompt',
        negatable: false,
        help: 'Never ask; leave the suggestions out (pack still warns).',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Overwrite an existing mold.yaml.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print the manifest on stdout instead of writing it.',
      );
  }

  final LineReader _readLine;

  @override
  String get name => 'init';

  @override
  String get description => 'Write a starting mold.yaml for a project.';

  @override
  String get invocation => 'mold init [dir] [options]';

  @override
  Future<int> execute(ArgResults results) async {
    final dir = results.rest.isEmpty ? '.' : results.rest.first;
    if (!Directory(dir).existsSync()) {
      throw CliException('Directory not found: $dir');
    }
    final path = p.join(dir, 'mold.yaml');
    final dryRun = results['dry-run'] as bool;
    if (!dryRun && !(results['force'] as bool) && File(path).existsSync()) {
      throw CliException('$path already exists; --force overwrites it.');
    }

    final variable = results['variable'] as String;
    // Checked here, not left to pack: a suggestion writes it into a
    // placeholder, and pack would refuse the manifest init reported written.
    if (!SubstitutionTemplate.isVariableName(variable)) {
      throw CliException(
        "--variable '$variable' cannot be a placeholder name: letters, "
        'digits and underscores, not starting with a digit.',
      );
    }
    final ({String name, String source}) detected;
    if (results['token'] case final String token) {
      detected = (name: token, source: '--token');
    } else {
      detected = detectProjectName(dir);
    }
    if (const CaseConverter().splitWords(detected.name).isEmpty) {
      throw CliException(
        "'${detected.name}' (${detected.source}) has no ASCII word "
        'characters to replace; pass --token.',
      );
    }

    final draft = _manifest(detected.name, variable, const []);
    final suggested = <UncoveredSpelling>[];
    final checked = ProjectValidator(onSuggestion: suggested.add).validate(
      ProjectInput(dir: dir, manifest: draft),
    );
    // Offered below rather than repeated: the warning says what the offer
    // does. Errors are reported as warnings — the draft is still the right
    // start, and pack says the same thing when it refuses.
    for (final issue in [...checked.errors, ...checked.warnings]) {
      if (issue.code != ProjectValidator.uncoveredCasing) {
        warn(
          ValidationError.warning(
            issue.code,
            issue.message,
            field: issue.field,
          ),
        );
      }
    }

    final add = suggested.isNotEmpty && _accept(results, suggested);
    final manifest = add
        ? _manifest(detected.name, variable, suggested)
        : draft;
    final yaml = manifest.toYaml();

    if (!dryRun) {
      File(path).writeAsStringSync(yaml);
    }

    if (wantsJson) {
      emitJson({
        'path': path,
        'written': !dryRun,
        'token': detected.name,
        'tokenSource': detected.source,
        'suggestions': [
          for (final s in suggested)
            {
              'from': s.suggestion.from,
              'to': s.suggestion.to,
              'files': s.files,
              'inContent': s.inContent,
              'inPaths': s.inPaths,
            },
        ],
        'suggestionsAdded': add,
        'manifestYaml': yaml,
      });
    } else if (dryRun) {
      out.write(yaml);
    } else {
      err
        ..writeln(
          "Wrote $path: '${detected.name}' (${detected.source}) is replaced "
          'by {{ $variable }}.',
        )
        ..writeln('Next: mold pack $dir --dry-run');
    }

    return 0;
  }

  /// Whether to add [suggested]: `--yes`, or a yes to the question. Never
  /// under `--no-prompt`, and not at end of input — no answer is not a yes.
  bool _accept(ArgResults results, List<UncoveredSpelling> suggested) {
    if (results['yes'] as bool) {
      return true;
    }
    if (results['no-prompt'] as bool) {
      return false;
    }

    err.writeln('Spellings of the name no derived casing covers:');
    for (final s in suggested) {
      err.writeln(
        "  '${s.spelling}' → ${s.suggestion.to}  "
        '(${s.files.length} ${s.files.length == 1 ? 'file' : 'files'})',
      );
    }
    final lists = [
      if (suggested.any((s) => s.inContent)) 'extra_substitutions',
      if (suggested.any((s) => s.inPaths)) 'path_renames',
    ];
    err.write('Add them to ${lists.join(' and ')}? [Y/n] ');
    final answer = _readLine();
    if (answer == null) {
      err.writeln();
      return false;
    }

    return const ['', 'y', 'yes'].contains(answer.trim().toLowerCase());
  }

  /// The draft manifest, with each of [suggested] where it renames: content
  /// spellings in `extra_substitutions`, path spellings in `path_renames`.
  static Manifest _manifest(
    String token,
    String variable,
    List<UncoveredSpelling> suggested,
  ) => Manifest(
    name: token,
    version: '0.1.0',
    // The template's own manifest is not part of the project it scaffolds:
    // unpacked, it would describe a template that is not there.
    exclude: const ['mold.yaml'],
    variables: [
      TemplateVariable(
        name: variable,
        description: 'The new project name.',
        replaces: token,
      ),
    ],
    extraSubstitutions: [
      for (final s in suggested)
        if (s.inContent) s.suggestion,
    ],
    pathRenames: [
      for (final s in suggested)
        if (s.inPaths) s.suggestion,
    ],
  );
}

/// The name the project in [dir] calls itself, and where it says so: the
/// first package manifest found — Dart, Node, PHP, Rust, Go, Python, Gradle,
/// Maven, Swift, .NET — else the directory's own name.
({String name, String source}) detectProjectName(String dir) {
  for (final (file, nameIn) in _manifests) {
    final f = File(p.join(dir, file));
    try {
      if (!f.existsSync()) {
        continue;
      }
      if (nameIn(f.readAsStringSync()) case final name? when name.isNotEmpty) {
        return (name: name, source: file);
      }
    } on FileSystemException {
      // Unreadable: the next source may say.
    } on FormatException {
      // Not what its name says it is (YamlException is one): likewise.
    }
  }

  // A .NET project is named by its project file, whatever it holds.
  try {
    final projects = [
      for (final entity in Directory(dir).listSync())
        if (entity is File && _dotnetProject.hasMatch(entity.path))
          p.basename(entity.path),
    ];
    if (projects.length == 1) {
      return (
        name: p.basenameWithoutExtension(projects.single),
        source: projects.single,
      );
    }
  } on FileSystemException {
    // Unlistable: fall back to the directory name.
  }

  return (name: p.basename(p.canonicalize(dir)), source: 'directory name');
}

final _dotnetProject = RegExp(r'\.(cs|fs|vb)proj$');

/// Each package manifest [detectProjectName] reads, with how to find the
/// name in it. Text patterns rather than parsers for the formats this
/// package has no parser for: the name sits in one predictable place.
final List<(String, String? Function(String))> _manifests = [
  (
    'pubspec.yaml',
    (text) => switch (loadYaml(text)) {
      final YamlMap doc => textAt(doc, 'name'),
      _ => null,
    },
  ),
  // `@scope/name` and `vendor/name`: the prefix is the publisher.
  ('package.json', (text) => _jsonName(text)?.split('/').last),
  ('composer.json', (text) => _jsonName(text)?.split('/').last),
  ('Cargo.toml', (text) => _tomlName(text, 'package')),
  (
    'go.mod',
    (text) {
      final module = RegExp(
        // A path may be quoted, with "…" or `…`; a comment may follow.
        r'^module\s+(?:"([^"]+)"|`([^`]+)`|([^\s"`]+))',
        multiLine: true,
      ).firstMatch(text);
      if (module == null) {
        return null;
      }
      // `example.com/acme/tool/v2`: the major-version suffix is not a name.
      final path = module[1] ?? module[2] ?? module[3]!;
      final segments = path.split('/');
      return segments.length > 1 && RegExp(r'^v\d+$').hasMatch(segments.last)
          ? segments[segments.length - 2]
          : segments.last;
    },
  ),
  (
    'pyproject.toml',
    (text) => _tomlName(text, 'project') ?? _tomlName(text, 'tool.poetry'),
  ),
  ('settings.gradle.kts', _gradleName),
  ('settings.gradle', _gradleName),
  (
    'pom.xml',
    (text) {
      // The project's own artifactId, not its parent's.
      final own = text.replaceAll(RegExp(r'<parent>[\s\S]*?</parent>'), '');
      return RegExp(r'<artifactId>\s*([^<\s]+)\s*</artifactId>')
          .firstMatch(own)?[1];
    },
  ),
  (
    'Package.swift',
    (text) => RegExp(
      r'Package\s*\(\s*name\s*:\s*"([^"]+)"',
    ).firstMatch(text)?[1],
  ),
];

String? _jsonName(String text) => switch (jsonDecode(text)) {
  {'name': final String name} => name,
  _ => null,
};

/// A quoted string, single or double, captured without its quotes.
const _quoted = '''["']([^"']+)["']''';

/// `name = "…"` in the TOML table [table], before the next table opens — a
/// line starting with `[`, not any `[`: an array value (`authors = ["me"]`)
/// may come first.
String? _tomlName(String text, String table) => RegExp(
  '^\\[${RegExp.escape(table)}\\](?:(?!^\\[)[\\s\\S])*?'
  '^\\s*name\\s*=\\s*$_quoted',
  multiLine: true,
).firstMatch(text)?[1];

String? _gradleName(String text) =>
    RegExp('rootProject\\.name\\s*=\\s*$_quoted').firstMatch(text)?[1];
