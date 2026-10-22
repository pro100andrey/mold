import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../validation/validation_error.dart';
import '../validation/validation_result.dart';
import 'manifest_validator.dart';
import 'yaml_text.dart';

/// One declared rename variable.
///
/// At unpack time the resolved value substitutes every casing of [replaces]
/// throughout paths and text content (see `CaseConverter`). A variable without
/// a [replaces] token contributes no renames; its value is available to
/// `extra_substitutions` through a `{{ name }}` placeholder.
class TemplateVariable {
  const TemplateVariable({
    required this.name,
    this.description = '',
    this.defaultValue,
    this.replaces,
    this.pattern,
    this.choices = const [],
  });

  /// The variable key (e.g. `project_name`), used by `--var key=value`.
  final String name;

  /// Human-facing description shown when prompting.
  final String description;

  /// Default value used when the variable is not supplied.
  final String? defaultValue;

  /// The source token to replace (in all four casings). Null when the variable
  /// exists only to be interpolated into `extra_substitutions`.
  final String? replaces;

  /// A regular expression the whole value must match, or null for any value.
  ///
  /// Anchored by the check itself — `pattern: '[a-z]+'` accepts `abc`, not
  /// `abc1` — so an author does not have to remember `^…$`.
  final String? pattern;

  /// The only values allowed, or empty for any value.
  final List<String> choices;

  /// Whether [value] satisfies [pattern] and [choices].
  ///
  /// A [pattern] that does not compile accepts nothing; `ManifestValidator`
  /// reports it before any value is checked.
  bool accepts(String value) {
    if (choices.isNotEmpty && !choices.contains(value)) {
      return false;
    }
    final source = pattern;
    if (source == null) {
      return true;
    }
    try {
      return RegExp('^(?:$source)\$').hasMatch(value);
    } on FormatException {
      return false;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TemplateVariable &&
      other.name == name &&
      other.description == description &&
      other.defaultValue == defaultValue &&
      other.replaces == replaces &&
      other.pattern == pattern &&
      _listEquals(other.choices, choices);

  @override
  int get hashCode => Object.hash(
    name,
    description,
    defaultValue,
    replaces,
    pattern,
    Object.hashAll(choices),
  );

  @override
  String toString() =>
      'TemplateVariable($name, description: $description, '
      'default: $defaultValue, replaces: $replaces, pattern: $pattern, '
      'choices: $choices)';
}

/// A literal text replacement applied to file contents at unpack time, for
/// strings automatic renaming cannot reach (e.g. a hard-coded URL).
class Substitution {
  const Substitution({required this.from, required this.to});

  /// The literal source string to find.
  final String from;

  /// The literal replacement.
  final String to;

  @override
  bool operator ==(Object other) =>
      other is Substitution && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'Substitution($from -> $to)';
}

/// Whether [a] and [b] hold equal elements in the same order.
///
/// Local rather than `package:collection`'s `ListEquality`, to keep the
/// dependency list at five for one function.
bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) {
    return false;
  }

  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }

  return true;
}

/// The template manifest (`mold.yaml`).
///
/// Describes a template: its [name]/[version], which files of the source
/// project to capture ([include]/[exclude]), and the rename [variables].
///
/// A manifest read with [Manifest.fromFile] retains the verbatim [source] text
/// so it can be embedded into the archive byte-for-byte rather than
/// re-serialized.
class Manifest {
  const Manifest({
    required this.name,
    required this.version,
    this.include = const [],
    this.exclude = const [],
    this.variables = const [],
    this.extraSubstitutions = const [],
    this.pathRenames = const [],
    this.noSubstitute = const [],
    this.binaryExtensions = const [],
    this.useGitignore = true,
    this.message,
    this.source,
    this.path,
    this.unknownKeys = const {},
  });

  /// Parses a manifest from raw YAML [text]. [source] defaults to [text] so the
  /// original bytes can be embedded into the archive; [path] records where the
  /// text came from, when it came from a file.
  ///
  /// Text that is not YAML, or not shaped like a manifest, is
  /// `MANIFEST_INVALID` — a [ValidationException] like every other problem
  /// with the inputs, so a caller handles one exception type. What is
  /// well-formed but wrong (a missing name, a bad glob) is reported by
  /// `ManifestValidator`.
  factory Manifest.fromYaml(String text, {String? path}) {
    try {
      return Manifest._parse(text, path);
    } on FormatException catch (e) {
      final where = path == null ? '' : '$path: ';
      throw ValidationException([
        ValidationError(
          ManifestValidator.invalid,
          '$where${e is YamlException ? e.toString() : e.message}',
        ),
      ]);
    }
  }

  factory Manifest._parse(String text, String? path) {
    final doc = loadYaml(text);
    if (doc is! YamlMap) {
      throw const FormatException('Manifest must be a YAML mapping.');
    }

    final unknown = <String, String?>{};
    _collectUnknown(doc, unknown);

    return Manifest(
      name: textAt(doc, 'name') ?? '',
      version: textAt(doc, 'version') ?? '',
      include: _stringList(doc.nodes['include']),
      exclude: _stringList(doc.nodes['exclude']),
      variables: _variables(doc['variables']),
      extraSubstitutions: _substitutions(
        doc['extra_substitutions'],
        'extra_substitutions',
      ),
      pathRenames: _substitutions(doc['path_renames'], 'path_renames'),
      noSubstitute: _stringList(doc.nodes['no_substitute']),
      binaryExtensions: _stringList(doc.nodes['binary_extensions']),
      useGitignore: _bool(doc['use_gitignore'], 'use_gitignore', true),
      message: _text(doc, 'message'),
      source: text,
      path: path,
      unknownKeys: unknown,
    );
  }

  /// Reads and parses the manifest at [path].
  factory Manifest.fromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ValidationException([
        ValidationError(
          ManifestValidator.notFound,
          'Manifest not found: $path',
        ),
      ]);
    }

    return .fromYaml(
      decodeManifestText(file.readAsBytesSync(), path),
      path: path,
    );
  }

  /// The keys a manifest may hold, at its top level.
  static const topLevelKeys = [
    'name',
    'version',
    'include',
    'exclude',
    'use_gitignore',
    'variables',
    'extra_substitutions',
    'path_renames',
    'no_substitute',
    'binary_extensions',
    'message',
  ];

  /// The keys a variable's mapping may hold.
  static const variableKeys = [
    'description',
    'default',
    'replaces',
    'pattern',
    'choices',
  ];

  /// The keys an `extra_substitutions` / `path_renames` entry may hold.
  static const substitutionKeys = ['from', 'to'];

  /// Records every key of [doc] the format does not define, with the known
  /// key it is probably a misspelling of.
  ///
  /// Shape errors are left to the parsers, which report them with context;
  /// this only looks where the shape is already right.
  static void _collectUnknown(YamlMap doc, Map<String, String?> into) {
    void check(YamlMap map, List<String> known, String prefix) {
      for (final key in map.keys) {
        final name = '$key';
        if (!known.contains(name)) {
          into['$prefix$name'] = _closest(name, known);
        }
      }
    }

    check(doc, topLevelKeys, '');
    if (doc['variables'] case final YamlMap variables) {
      for (final MapEntry(:key, :value) in variables.entries) {
        if (value is YamlMap) {
          check(value, variableKeys, 'variables.$key.');
        }
      }
    }
    for (final section in ['extra_substitutions', 'path_renames']) {
      if (doc[section] case final YamlList entries) {
        for (var i = 0; i < entries.length; i++) {
          if (entries[i] case final YamlMap entry) {
            check(entry, substitutionKeys, '$section[$i].');
          }
        }
      }
    }
  }

  /// The entry of [known] within two edits of [key], if there is one —
  /// `excludes` → `exclude`, `replace` → `replaces`.
  static String? _closest(String key, List<String> known) {
    String? best;
    var bestDistance = 3;
    for (final candidate in known) {
      final d = _distance(key, candidate);
      if (d < bestDistance) {
        best = candidate;
        bestDistance = d;
      }
    }

    return best;
  }

  /// Levenshtein distance; keys are short, so the plain table is plenty.
  static int _distance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        current[j] = [
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      previous = current;
    }

    return previous[b.length];
  }

  /// Template name; also the default output file stem.
  final String name;

  /// Template version string.
  final String version;

  /// Glob patterns (relative to the source dir) to include. Empty means "all".
  final List<String> include;

  /// Glob patterns (relative to the source dir) to exclude.
  final List<String> exclude;

  /// Declared rename variables, in manifest order.
  final List<TemplateVariable> variables;

  /// Literal `from`/`to` replacements applied to text content at unpack time.
  final List<Substitution> extraSubstitutions;

  /// `from`/`to` replacements applied to file and directory **paths** only.
  ///
  /// The mirror of [extraSubstitutions], for when a token must be renamed in
  /// some paths but preserved in others: a Flutter project's `android/app/` is
  /// a fixed Gradle module path while `kotlin/com/example/app/` is the package
  /// and must move. One literal, opposite treatment — which a `replaces` token
  /// cannot express, because it rewrites both.
  ///
  /// Matching is longest-first, so an entry mapping a path to itself pins it
  /// against a shorter rename key.
  final List<Substitution> pathRenames;

  /// Glob patterns of text files copied verbatim (no content substitution).
  final List<String> noSubstitute;

  /// Extra extensions treated as binary, on top of the built-in set.
  final List<String> binaryExtensions;

  /// Whether the project's own `.gitignore` files also exclude files from the
  /// template. Defaults to true.
  ///
  /// A project already declares what is derived rather than authored, and
  /// repeating `.dart_tool/**`, `build/**` and friends in every manifest is
  /// duplication that goes stale. `exclude` still applies on top, for the
  /// decisions git has no opinion about — a lockfile you do not want
  /// scaffolded, the manifest itself.
  ///
  /// The two are ANDed: a file is packed only if it passes `include`, passes
  /// `exclude`, and is not gitignored. Set this to false to pack a project
  /// exactly as it sits on disk.
  final bool useGitignore;

  /// What to tell the person once the project is unpacked — next steps, a
  /// command to run — or null for nothing.
  ///
  /// A template like a substitution's `to:`: `{{ name }}` and
  /// `{{ name | transform }}` render with the resolved values.
  final String? message;

  /// The verbatim YAML this manifest was parsed from, when available. Embedded
  /// into the archive as `mold.yaml`.
  final String? source;

  /// The file this manifest was read from, when available.
  ///
  /// Provenance, like [source] — not a manifest field, so it is neither
  /// emitted by [toYaml] nor part of equality. `ProjectValidator` uses it to
  /// exclude the manifest from its own token search: a `replaces:` line is not
  /// evidence that the project uses the token.
  final String? path;

  /// Keys in the parsed YAML that the format does not define, by where they
  /// sit (`excludes`, `variables.name.replace`, `path_renames[0].form`), each
  /// with the known key it is probably a misspelling of, or null.
  ///
  /// Provenance like [path]: not a manifest field, not part of equality.
  /// Parsing stays lenient — an unknown key is reported, not rejected — but it
  /// is never silent: `excludes:` for `exclude:` would otherwise pack exactly
  /// the files it was written to keep out.
  final Map<String, String?> unknownKeys;

  /// Every glob pattern this manifest declares, in one place.
  ///
  /// The single point of truth for `ManifestValidator`'s glob check. A new
  /// glob-bearing field is added **here**, next to its declaration, rather than
  /// to a list buried in a validator that nothing points at.
  List<String> get globPatterns => [...include, ...exclude, ...noSubstitute];

  /// Every substitution in this manifest whose `to` is interpreted as a
  /// template, in one place.
  ///
  /// Same single-point-of-truth role as [globPatterns]: a new template-bearing
  /// field is added here, beside its declaration.
  ///
  /// A **list**, not a map keyed by `from`. Keying by `from` silently collapsed
  /// two entries sharing one — an `extra_substitutions` entry and a
  /// `path_renames` entry naming the same literal — so only one of the two `to`
  /// templates was ever validated, while unpack rendered both. A malformed
  /// placeholder in the unchecked one renders to the empty string, deleting the
  /// text it was meant to replace.
  List<Substitution> get replacementTemplates => [
    ...extraSubstitutions,
    ...pathRenames,
  ];

  /// Equality over the declared content, so a round trip through [toYaml] can
  /// be asserted in one expression and a field forgotten there fails loudly.
  ///
  /// [source] is deliberately excluded: it records where the manifest came
  /// from, not what it means, and including it would make
  /// `Manifest.fromYaml(m.toYaml()) == m` impossible — `fromYaml` always sets
  /// it, a manifest built in code never has one.
  @override
  bool operator ==(Object other) =>
      other is Manifest &&
      other.name == name &&
      other.version == version &&
      _listEquals(other.include, include) &&
      _listEquals(other.exclude, exclude) &&
      _listEquals(other.variables, variables) &&
      _listEquals(other.extraSubstitutions, extraSubstitutions) &&
      _listEquals(other.pathRenames, pathRenames) &&
      _listEquals(other.noSubstitute, noSubstitute) &&
      _listEquals(other.binaryExtensions, binaryExtensions) &&
      other.useGitignore == useGitignore &&
      other.message == message;

  @override
  int get hashCode => Object.hash(
    name,
    version,
    Object.hashAll(include),
    Object.hashAll(exclude),
    Object.hashAll(variables),
    Object.hashAll(extraSubstitutions),
    Object.hashAll(pathRenames),
    Object.hashAll(noSubstitute),
    Object.hashAll(binaryExtensions),
    useGitignore,
    message,
  );

  /// Field-by-field, so a failed round-trip assertion names the field that
  /// differs instead of printing two opaque instances.
  @override
  String toString() =>
      'Manifest(name: $name, version: $version, include: $include, '
      'exclude: $exclude, variables: $variables, '
      'extraSubstitutions: $extraSubstitutions, '
      'pathRenames: $pathRenames, '
      'noSubstitute: $noSubstitute, binaryExtensions: $binaryExtensions, '
      'useGitignore: $useGitignore, message: $message)';

  /// Renders this manifest back to YAML, for embedding a manifest that was
  /// built in code rather than read from a file (where [source] is null).
  ///
  /// Round-trips every field, so a code-built manifest produces a template that
  /// renames exactly like a file-built one. Emitting only name/version would
  /// yield an archive that unpacks with no substitution at all.
  String toYaml() {
    final buffer = StringBuffer()
      ..writeln('name: ${_scalar(name)}')
      ..writeln('version: ${_scalar(version)}');

    _writeList(buffer, 'include', include);
    _writeList(buffer, 'exclude', exclude);

    if (variables.isNotEmpty) {
      buffer.writeln('variables:');
      for (final v in variables) {
        final defaultValue = v.defaultValue;
        final replaces = v.replaces;
        final pattern = v.pattern;
        // A variable with no sub-fields still needs an explicit empty mapping:
        // a bare `name:` parses back as null, not as a mapping.
        if (v.description.isEmpty &&
            defaultValue == null &&
            replaces == null &&
            pattern == null &&
            v.choices.isEmpty) {
          buffer.writeln('  ${_scalar(v.name)}: {}');
          continue;
        }

        buffer.writeln('  ${_scalar(v.name)}:');

        if (v.description.isNotEmpty) {
          buffer.writeln('    description: ${_scalar(v.description)}');
        }

        if (defaultValue != null) {
          buffer.writeln('    default: ${_scalar(defaultValue)}');
        }

        if (replaces != null) {
          buffer.writeln('    replaces: ${_scalar(replaces)}');
        }

        if (pattern != null) {
          buffer.writeln('    pattern: ${_scalar(pattern)}');
        }

        if (v.choices.isNotEmpty) {
          buffer.writeln('    choices:');
          for (final choice in v.choices) {
            buffer.writeln('      - ${_scalar(choice)}');
          }
        }
      }
    }

    _writeSubstitutions(buffer, 'extra_substitutions', extraSubstitutions);
    _writeSubstitutions(buffer, 'path_renames', pathRenames);

    if (!useGitignore) {
      buffer.writeln('use_gitignore: false');
    }

    _writeList(buffer, 'no_substitute', noSubstitute);
    _writeList(buffer, 'binary_extensions', binaryExtensions);

    if (message case final text?) {
      buffer.writeln('message: ${_scalar(text)}');
    }

    return buffer.toString();
  }

  /// Emits a `from`/`to` section. Shared so the two cannot drift apart.
  static void _writeSubstitutions(
    StringBuffer buffer,
    String key,
    List<Substitution> items,
  ) {
    if (items.isEmpty) {
      return;
    }

    buffer.writeln('$key:');
    for (final s in items) {
      buffer
        ..writeln('  - from: ${_scalar(s.from)}')
        ..writeln('    to: ${_scalar(s.to)}');
    }
  }

  static void _writeList(StringBuffer buffer, String key, List<String> items) {
    if (items.isEmpty) {
      return;
    }

    buffer.writeln('$key:');
    for (final item in items) {
      buffer.writeln('  - ${_scalar(item)}');
    }
  }

  /// Renders [value] as a double-quoted YAML scalar.
  ///
  /// Quoting unconditionally rather than only when "needed": glob patterns
  /// (`**`, `*.g.dart`), values containing `:`, and version-like strings each
  /// have their own plain-scalar hazard.
  ///
  /// Double-quoted rather than single-quoted, because a single-quoted scalar
  /// has no escape for a line break — it may only span lines, and YAML then
  /// *folds* each break into a space. A multi-line `extra_substitutions.from`
  /// would come back with its newlines silently replaced. Double quotes are
  /// the only YAML flow style with a real `\n` escape.
  static String _scalar(String value) {
    final escaped = value
        .replaceAll(r'\', r'\\') // First: later escapes add backslashes.
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t')
        // YAML allows only printable characters in a scalar: every other
        // control character must be an escape to read back.
        .replaceAllMapped(_nonPrintable, (m) {
          final hex = m[0]!.codeUnitAt(0).toRadixString(16).padLeft(2, '0');
          return '\\x$hex';
        });
    return '"$escaped"';
  }

  /// The C0 and C1 controls and DEL that YAML's printable set leaves out;
  /// tab, line feed, carriage return and NEL are printable.
  static final _nonPrintable = RegExp(
    r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x84\x86-\x9F]',
  );

  /// Reads an optional text field: a scalar, as written. A list or a mapping
  /// is refused rather than printed as its `toString`.
  static String? _text(YamlMap doc, String key) {
    final node = doc.nodes[key];
    if (node != null && node is! YamlScalar) {
      throw FormatException("'$key' must be text, but got: ${node.value}.");
    }

    return textAt(doc, key);
  }

  /// Reads an optional boolean field, falling back to [fallback] when absent.
  ///
  /// A cast (`as bool?`) threw `TypeError` for anything else, which no caller
  /// catches: a `FormatException` becomes `MANIFEST_INVALID`, but a `TypeError`
  /// escaped as an exit-255 crash with a stack trace. `use_gitignore: yes` is
  /// enough to trigger it — YAML 1.1 spelled booleans that way, and
  /// `package:yaml` is 1.2, where `yes` is the string "yes".
  static bool _bool(Object? value, String key, bool fallback) {
    if (value == null) {
      return fallback;
    }
    if (value is! bool) {
      throw FormatException(
        "'$key' must be true or false, but got: $value. Note that YAML 1.2 "
        'reads yes/no/on/off as strings, not booleans.',
      );
    }

    return value;
  }

  static List<String> _stringList(YamlNode? node) {
    if (node == null || node.value == null) {
      return const [];
    }

    if (node is! YamlList) {
      throw FormatException('Expected a list but got: ${node.value}');
    }

    return [
      for (final item in node.nodes) nodeText(item) ?? '',
    ].toList(growable: false);
  }

  static List<TemplateVariable> _variables(Object? value) {
    if (value == null) {
      return const [];
    }

    if (value is! YamlMap) {
      throw const FormatException("'variables' must be a mapping.");
    }

    return [
      for (final entry in value.entries)
        _variable(entry.key.toString(), entry.value),
    ];
  }

  static TemplateVariable _variable(String name, Object? spec) {
    if (spec is! YamlMap) {
      throw FormatException("Variable '$name' must be a mapping.");
    }

    return TemplateVariable(
      name: name,
      description: textAt(spec, 'description') ?? '',
      defaultValue: textAt(spec, 'default'),
      replaces: textAt(spec, 'replaces'),
      pattern: textAt(spec, 'pattern'),
      choices: _stringList(spec.nodes['choices']),
    );
  }

  /// Parses a `from`/`to` list. [key] names the section in error messages.
  static List<Substitution> _substitutions(Object? value, String key) {
    if (value == null) {
      return const [];
    }

    if (value is! YamlList) {
      throw FormatException("'$key' must be a list.");
    }

    return [for (final item in value) _substitution(item, key)];
  }

  static Substitution _substitution(Object? item, String key) {
    if (item is! YamlMap) {
      throw FormatException('Each $key entry must be a mapping with from/to.');
    }

    final from = textAt(item, 'from');
    final to = textAt(item, 'to');
    if (from is! String || from.isEmpty) {
      throw FormatException("A $key entry needs a non-empty 'from'.");
    }

    if (to is! String) {
      throw FormatException("A $key entry needs a 'to'.");
    }

    return Substitution(from: from, to: to);
  }
}

/// The text of a manifest's bytes, read from [where].
///
/// Bytes that are not UTF-8 are `MANIFEST_INVALID`, like text that is not
/// YAML, rather than the bare [FormatException] `utf8.decode` throws — which
/// no caller handling [ValidationException] would catch.
String decodeManifestText(List<int> bytes, String where) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw ValidationException([
      ValidationError(
        ManifestValidator.invalid,
        '$where: not UTF-8 text.',
      ),
    ]);
  }
}
