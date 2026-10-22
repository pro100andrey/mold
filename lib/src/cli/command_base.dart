import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:yaml/yaml.dart';

import '../manifest/yaml_text.dart';
import '../unbundler/unbundler.dart';
import '../unbundler/unpack_stamp.dart';
import '../validation/validation_error.dart';
import '../validation/validation_result.dart';

/// Thrown for user-facing CLI errors (bad args, missing files). The runner
/// turns it into a clean stderr message + exit code 64.
class CliException implements Exception {
  const CliException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What every `mold` subcommand shares: the two output sinks, `--json`, and
/// one way of turning failures into exit codes.
///
/// Human-facing text goes to [err] — it is commentary on the work, not its
/// product, and keeping it off stdout is what lets `--json` own stdout
/// entirely. The only other stdout is a manifest printed to be redirected:
/// `init --dry-run`, `inspect --manifest`. Under `--json`, warnings are
/// collected into the document instead of printed, and a validation failure
/// is a document too (`errors`), so a tool reading stdout always gets JSON
/// and an exit code.
abstract class MoldCommand extends Command<int> {
  MoldCommand(this.out, this.err, {this._input}) {
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Print the result as JSON on stdout, warnings included.',
    );
  }

  /// The product of the command under `--json`.
  final StringSink out;

  /// Everything meant for a person.
  final StringSink err;

  /// What `-` reads in place of an archive file; stdin when not injected.
  final Stream<List<int>>? _input;

  /// Whether [source] names stdin rather than a file.
  static bool isStdin(String source) => source == '-';

  /// The archive bytes [source] names: the file at that path, or with `-`
  /// everything on stdin, so `curl … | mold unpack - -t app` needs no
  /// intermediate file.
  Future<Uint8List> readArchiveSource(String source) async {
    if (!isStdin(source)) {
      return Unbundler.readArchive(source);
    }
    final builder = BytesBuilder(copy: false);
    await (_input ?? stdin).forEach(builder.add);

    return builder.takeBytes();
  }

  final List<ValidationError> _warnings = [];

  /// Whether `--json` was given.
  bool get wantsJson => argResults!['json'] as bool;

  /// Reports a warning: printed, or kept for the JSON document.
  void warn(ValidationError warning) {
    if (wantsJson) {
      _warnings.add(warning);
    } else {
      err.writeln('Warning: $warning');
    }
  }

  /// Writes [doc] to [out] as the command's JSON result, with the warnings.
  void emitJson(Map<String, Object?> doc) {
    out.writeln(
      const JsonEncoder.withIndent('  ').convert({
        ...doc,
        'warnings': [for (final w in _warnings) issueJson(w)],
      }),
    );
  }

  /// The command body; [run] maps what it throws to exit codes.
  Future<int> execute(ArgResults results);

  /// The code of a usage error in a `--json` document — bad arguments, a
  /// missing vars file — which carries no library code of its own.
  static const usageCode = 'CLI_USAGE';

  /// The code of a filesystem failure in a `--json` document.
  static const ioCode = 'IO_FAILURE';

  @override
  Future<int> run() async {
    try {
      return await execute(argResults!);
    } on CliException catch (e) {
      return _fail(usageCode, e.message, 64);
    } on ValidationException catch (e) {
      if (wantsJson) {
        emitJson({
          'errors': [for (final error in e.errors) issueJson(error)],
        });
      } else {
        err.writeln(e.toString());
      }
      return 1;
    } on FormatException catch (e) {
      return _fail(usageCode, e.message, 1);
    } on IOException catch (e) {
      // Here as well as in the runner, so a --json run reports it as JSON.
      return _fail(ioCode, e.toString(), 1);
    }
  }

  /// Reports a failure that is not a [ValidationException]: as text, or under
  /// `--json` as an `errors` document, so stdout is JSON whatever went wrong.
  int _fail(String code, String message, int exitCode) {
    if (wantsJson) {
      emitJson({
        'errors': [
          {'code': code, 'severity': 'error', 'message': message},
        ],
      });
    } else {
      err.writeln(message);
    }

    return exitCode;
  }

  /// The `--var` and `--vars-file` values of [results].
  ///
  /// The file is read first and `--var` applied over it: a file of shared
  /// values with one overridden on the command line is the common case, and
  /// the override is as explicit as anything typed can be. A key repeated
  /// within `--var` itself is still an error — that one is ambiguous.
  ///
  /// A stamp's values are `recorded`, not `vars`: they say what a project was
  /// made with, and a template that has since dropped a variable is a reason
  /// to warn, not to refuse — see `Unbundler.plan`.
  ({Map<String, String> vars, Map<String, String> recorded}) varsOf(
    ArgResults results,
  ) {
    final file = switch (results['vars-file']) {
      final String path => readVarsFile(path),
      _ => null,
    };
    final given = parseVars(results['var'] as List<String>);
    if (file == null) {
      return (vars: given, recorded: const {});
    }

    return file.recorded
        ? (vars: given, recorded: file.values)
        : (vars: {...file.values, ...given}, recorded: const {});
  }

  /// Declares `--var` and `--vars-file`, with [purpose] in the help.
  void addVarOptions(String purpose) {
    argParser
      ..addMultiOption(
        'var',
        abbr: 'v',
        help: 'Variable value as key=value (repeatable)$purpose.',
      )
      ..addOption(
        'vars-file',
        help:
            'YAML or JSON map of variable values, or a .mold.json stamp; '
            '--var overrides it.',
      );
  }
}

/// [issue] as a JSON object.
Map<String, Object?> issueJson(ValidationError issue) => {
  'code': issue.code,
  'severity': issue.severity.name,
  'message': issue.message,
  'field': ?issue.field,
};

/// Parses repeated `key=value` pairs into a map. Splits on the first `=`.
Map<String, String> parseVars(List<String> raw) {
  final out = <String, String>{};
  for (final entry in raw) {
    final eq = entry.indexOf('=');
    if (eq <= 0) {
      throw CliException("Invalid --var '$entry'; expected key=value.");
    }
    final key = entry.substring(0, eq);
    // Keeping the last silently discarded the first, which is the same class
    // of quiet drop VARIABLE_UNKNOWN exists to prevent.
    if (out.containsKey(key)) {
      throw CliException(
        "Repeated --var '$key'; it was given more than once. Pass it once.",
      );
    }
    out[key] = entry.substring(eq + 1);
  }

  return out;
}

/// Reads variable values from the file at [path]: a YAML (or JSON) map of
/// scalars, or an [UnpackStamp], whose `vars` it takes — so a project
/// regenerated from its own stamp gets the values it was made with.
///
/// `recorded` says which it was. A map's keys are checked against the
/// template like `--var` keys are, so a mistyped one is `VARIABLE_UNKNOWN`
/// rather than ignored; a stamp's may name variables the template has dropped
/// since, which is `VARIABLE_DROPPED`, a warning.
({Map<String, String> values, bool recorded}) readVarsFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw CliException('Vars file not found: $path');
  }
  final text = file.readAsStringSync();

  final Object? doc;
  try {
    doc = loadYaml(text);
  } on YamlException catch (e) {
    throw CliException('Vars file $path is not YAML or JSON: ${e.message}');
  }
  if (doc is! YamlMap) {
    throw CliException('Vars file $path must hold a map of values.');
  }
  if (doc.containsKey('mold_stamp')) {
    final stamp = UnpackStamp.tryParse(text);
    if (stamp == null) {
      throw CliException('Vars file $path looks like a stamp but is not one.');
    }
    return (values: stamp.vars, recorded: true);
  }

  final values = {
    for (final MapEntry(:key, value: node) in doc.nodes.entries)
      '${nodeText(key as YamlNode)}': node is YamlScalar && node.value != null
          // As written: `1.10` stays `1.10`, `007` stays `007`.
          ? nodeText(node)!
          : throw CliException(
              "Vars file $path: '${nodeText(key)}' must be a single value, "
              'not ${node.value}.',
            ),
  };

  return (values: values, recorded: false);
}
