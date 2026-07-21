import '../unbundler/case_transform.dart';

/// One piece of a parsed substitution template.
sealed class TemplateSegment {
  const TemplateSegment();
}

/// Text emitted verbatim.
class LiteralSegment extends TemplateSegment {
  const LiteralSegment(this.text);

  /// The literal text.
  final String text;

  @override
  String toString() => 'Literal($text)';
}

/// A `{{ variable }}` or `{{ variable | transform }}` site.
class PlaceholderSegment extends TemplateSegment {
  const PlaceholderSegment(this.variable, [this.transform]);

  /// The variable name to interpolate.
  final String variable;

  /// The case transform to apply, or null to emit the value unchanged.
  final CaseTransform? transform;

  @override
  String toString() {
    final t = transform;
    return 'Placeholder($variable${t == null ? '' : ' | ${t.name}'})';
  }
}

/// Why a template could not be parsed.
enum TemplateErrorKind {
  /// A `{{` with no closing `}}`.
  unterminated,

  /// The text between the braces is not `name` or `name | transform`.
  malformed,

  /// The transform name is not one of [CaseTransform.values].
  unknownTransform,
}

/// A single parse failure, with the offending text.
class TemplateError {
  const TemplateError(this.kind, this.message);

  /// Which failure this is.
  final TemplateErrorKind kind;

  /// Human-facing explanation, naming the offending placeholder.
  final String message;

  @override
  String toString() => message;
}

/// A substitution's `to:` value, parsed into literals and placeholders.
///
/// Parsing **never throws**: a malformed template yields a value whose [errors]
/// are non-empty, so `ManifestValidator` can report every problem in a manifest
/// at once rather than aborting on the first — the same reason
/// `VariableResolver` omits unresolvable variables instead of raising.
///
/// Syntax:
/// ```
/// placeholder := "{{" name [ "|" transform ] "}}"
/// escape      := "{{{{"     -> a literal "{{"
/// ```
/// Whitespace inside the braces is insignificant. Chaining (`{{ a | x | y }}`)
/// is not supported and reports [TemplateErrorKind.malformed] rather than
/// being read as a transform named `x | y`.
class SubstitutionTemplate {
  const SubstitutionTemplate._(this.segments, this.errors);

  /// Parses [text]. Never throws.
  factory SubstitutionTemplate.parse(String text) {
    final segments = <TemplateSegment>[];
    final errors = <TemplateError>[];
    final literal = StringBuffer();

    var i = 0;
    while (i < text.length) {
      final open = text.indexOf('{{', i);
      if (open == -1) {
        literal.write(text.substring(i));
        break;
      }

      literal.write(text.substring(i, open));

      // Four braces escape a literal `{{`; checked before two, so the choice
      // is deterministic.
      if (text.startsWith('{{{{', open)) {
        literal.write('{{');
        i = open + 4;
        continue;
      }

      final close = text.indexOf('}}', open + 2);
      if (close == -1) {
        errors.add(
          TemplateError(
            .unterminated,
            "Unterminated placeholder in '$text': '{{' has no matching '}}'.",
          ),
        );
        // Keep the rest as literal so later entries still get parsed.
        literal.write(text.substring(open));
        break;
      }

      final body = text.substring(open + 2, close);
      final segment = _parseBody(body, text, errors);
      if (segment != null) {
        if (literal.isNotEmpty) {
          segments.add(LiteralSegment(literal.toString()));
          literal.clear();
        }
        segments.add(segment);
      }

      i = close + 2;
    }

    if (literal.isNotEmpty) {
      segments.add(LiteralSegment(literal.toString()));
    }

    return SubstitutionTemplate._(
      .unmodifiable(segments),
      .unmodifiable(errors),
    );
  }

  /// The parsed pieces, in order.
  final List<TemplateSegment> segments;

  /// Problems found while parsing; empty when the template is well-formed.
  final List<TemplateError> errors;

  /// Whether this template has no placeholders at all.
  bool get isLiteral => segments.every((s) => s is LiteralSegment);

  /// The variable names this template interpolates, in order of appearance.
  Iterable<String> get variableNames =>
      segments.whereType<PlaceholderSegment>().map((s) => s.variable);

  /// Renders against [values].
  ///
  /// Throws [FormatException] for a variable absent from [values]. Unreachable
  /// through the normal path: `ManifestValidator` rejects unknown names and
  /// `VariablesValidator` rejects missing values before this runs.
  String render(Map<String, String> values) {
    final buffer = StringBuffer();
    for (final segment in segments) {
      switch (segment) {
        case LiteralSegment(:final text):
          buffer.write(text);
        case PlaceholderSegment(:final variable, :final transform):
          final value = values[variable];
          if (value == null) {
            throw FormatException(
              "No value for variable '$variable' in a substitution.",
            );
          }
          buffer.write(transform == null ? value : transform.apply(value));
      }
    }

    return buffer.toString();
  }

  static final _name = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  static TemplateSegment? _parseBody(
    String body,
    String whole,
    List<TemplateError> errors,
  ) {
    final parts = body.split('|');
    if (parts.length > 2) {
      errors.add(
        TemplateError(
          TemplateErrorKind.malformed,
          "Malformed placeholder '{{$body}}' in '$whole': chaining transforms "
          'is not supported.',
        ),
      );
      return null;
    }

    final name = parts.first.trim();
    if (!_name.hasMatch(name)) {
      errors.add(
        TemplateError(
          .malformed,
          "Malformed placeholder '{{$body}}' in '$whole': "
          "'$name' is not a variable name.",
        ),
      );

      return null;
    }

    if (parts.length == 1) {
      return PlaceholderSegment(name);
    }

    final transformName = parts[1].trim();
    final transform = CaseTransform.byNameOrNull(transformName);
    if (transform == null) {
      errors.add(
        TemplateError(
          .unknownTransform,
          "Unknown transform '$transformName' in '{{$body}}'. "
          'Valid transforms: ${CaseTransform.names}.',
        ),
      );
      return null;
    }
    return PlaceholderSegment(name, transform);
  }
}
