import 'dart:io';

import 'package:yaml/yaml.dart';

/// One declared rename variable.
///
/// At unpack time the resolved value substitutes every casing of [replaces]
/// throughout paths and text content (see `CaseConverter`). A variable without
/// a [replaces] token carries a value for `extra_substitutions` only.
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
  /// only feeds `extra_substitutions`.
  final String? replaces;
}

/// A literal text replacement applied to file contents at unpack time, for
/// strings automatic renaming cannot reach (e.g. a hard-coded URL).
class Substitution {
  const Substitution({required this.from, required this.to});

  /// The literal source string to find.
  final String from;

  /// The literal replacement.
  final String to;
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
    this.noSubstitute = const [],
    this.binaryExtensions = const [],
    this.source,
  });

  /// Parses a manifest from raw YAML [text]. [source] defaults to [text] so the
  /// original bytes can be embedded into the archive.
  factory Manifest.fromYaml(String text) {
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
      extraSubstitutions: _substitutions(doc['extra_substitutions']),
      noSubstitute: _stringList(doc['no_substitute']),
      binaryExtensions: _stringList(doc['binary_extensions']),
      source: text,
    );
  }

  /// Reads and parses the manifest at [path].
  factory Manifest.fromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw FormatException('Manifest not found: $path');
    }

    return .fromYaml(file.readAsStringSync());
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

  /// Glob patterns of text files copied verbatim (no content substitution).
  final List<String> noSubstitute;

  /// Extra extensions treated as binary, on top of the built-in set.
  final List<String> binaryExtensions;

  /// The verbatim YAML this manifest was parsed from, when available. Embedded
  /// into the archive as `mold.yaml`.
  final String? source;

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

    if (extraSubstitutions.isNotEmpty) {
      buffer.writeln('extra_substitutions:');
      for (final s in extraSubstitutions) {
        buffer
          ..writeln('  - from: ${_scalar(s.from)}')
          ..writeln('    to: ${_scalar(s.to)}');
      }
    }

    _writeList(buffer, 'no_substitute', noSubstitute);
    _writeList(buffer, 'binary_extensions', binaryExtensions);

    return buffer.toString();
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

  /// Renders [value] as a single-quoted YAML scalar.
  ///
  /// Quoting unconditionally rather than only when "needed": glob patterns
  /// (`**`, `*.g.dart`), values containing `:`, and version-like strings each
  /// have their own plain-scalar hazard, and a single-quoted scalar with `'`
  /// doubled is unambiguous for all of them.
  static String _scalar(String value) =>
      "'${value.replaceAll("'", "''")}'";

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

  static List<Substitution> _substitutions(Object? value) {
    if (value == null) {
      return const [];
    }

    if (value is! YamlList) {
      throw const FormatException("'extra_substitutions' must be a list.");
    }

    return [for (final item in value) _substitution(item)];
  }

  static Substitution _substitution(Object? item) {
    if (item is! YamlMap) {
      throw const FormatException(
        'Each extra_substitution must be a mapping with from/to.',
      );
    }

    final from = item['from'];
    final to = item['to'];
    if (from is! String || from.isEmpty) {
      throw const FormatException("extra_substitution 'from' is required.");
    }

    if (to is! String) {
      throw const FormatException("extra_substitution 'to' is required.");
    }
    
    return Substitution(from: from, to: to);
  }
}
