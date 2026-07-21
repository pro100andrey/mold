import 'dart:io';

import 'package:yaml/yaml.dart';

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

  @override
  bool operator ==(Object other) =>
      other is TemplateVariable &&
      other.name == name &&
      other.description == description &&
      other.defaultValue == defaultValue &&
      other.replaces == replaces;

  @override
  int get hashCode => Object.hash(name, description, defaultValue, replaces);

  @override
  String toString() =>
      'TemplateVariable($name, description: $description, '
      'default: $defaultValue, replaces: $replaces)';
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
    this.source,
    this.path,
  });

  /// Parses a manifest from raw YAML [text]. [source] defaults to [text] so the
  /// original bytes can be embedded into the archive; [path] records where the
  /// text came from, when it came from a file.
  factory Manifest.fromYaml(String text, {String? path}) {
    final doc = loadYaml(text);
    if (doc is! YamlMap) {
      throw const FormatException('Manifest must be a YAML mapping.');
    }

    return Manifest(
      name: _optionalString(doc['name']),
      version: _optionalString(doc['version']),
      include: _stringList(doc['include']),
      exclude: _stringList(doc['exclude']),
      variables: _variables(doc['variables']),
      extraSubstitutions: _substitutions(
        doc['extra_substitutions'],
        'extra_substitutions',
      ),
      pathRenames: _substitutions(doc['path_renames'], 'path_renames'),
      noSubstitute: _stringList(doc['no_substitute']),
      binaryExtensions: _stringList(doc['binary_extensions']),
      useGitignore: doc['use_gitignore'] as bool? ?? true,
      source: text,
      path: path,
    );
  }

  /// Reads and parses the manifest at [path].
  factory Manifest.fromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw FormatException('Manifest not found: $path');
    }

    return .fromYaml(file.readAsStringSync(), path: path);
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

  /// Every glob pattern this manifest declares, in one place.
  ///
  /// The single point of truth for `ManifestValidator`'s glob check. A new
  /// glob-bearing field is added **here**, next to its declaration, rather than
  /// to a list buried in a validator that nothing points at.
  List<String> get globPatterns => [...include, ...exclude, ...noSubstitute];

  /// Every string in this manifest that is interpreted as a substitution
  /// template, keyed by the entry it belongs to so errors can name it.
  ///
  /// Same single-point-of-truth role as [globPatterns]: a new template-bearing
  /// field is added here, beside its declaration.
  Map<String, String> get replacementTemplates => {
    for (final s in extraSubstitutions) s.from: s.to,
    for (final s in pathRenames) s.from: s.to,
  };

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
      other.useGitignore == useGitignore;

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
      'useGitignore: $useGitignore)';

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
        // A variable with no sub-fields still needs an explicit empty mapping:
        // a bare `name:` parses back as null, not as a mapping.
        if (v.description.isEmpty && defaultValue == null && replaces == null) {
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
      }
    }

    _writeSubstitutions(buffer, 'extra_substitutions', extraSubstitutions);
    _writeSubstitutions(buffer, 'path_renames', pathRenames);

    if (!useGitignore) {
      buffer.writeln('use_gitignore: false');
    }
    _writeList(buffer, 'no_substitute', noSubstitute);
    _writeList(buffer, 'binary_extensions', binaryExtensions);

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
        .replaceAll('\t', r'\t');
    return '"$escaped"';
  }

  /// Reads an optional scalar as a string; missing → empty. Required-field
  /// enforcement is the `ManifestValidator`'s job, so parsing stays lenient.
  static String _optionalString(Object? value) =>
      value == null ? '' : value.toString();

  static List<String> _stringList(Object? value) {
    if (value == null) {
      return const [];
    }

    if (value is! YamlList) {
      throw FormatException('Expected a list but got: $value');
    }

    return value.map((e) => e.toString()).toList(growable: false);
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
      description: (spec['description'] as Object?)?.toString() ?? '',
      defaultValue: (spec['default'] as Object?)?.toString(),
      replaces: (spec['replaces'] as Object?)?.toString(),
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

    final from = item['from'];
    final to = item['to'];
    if (from is! String || from.isEmpty) {
      throw FormatException("A $key entry needs a non-empty 'from'.");
    }

    if (to is! String) {
      throw FormatException("A $key entry needs a 'to'.");
    }

    return Substitution(from: from, to: to);
  }
}
