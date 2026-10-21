import 'package:args/args.dart';

import '../manifest/manifest.dart';
import '../unbundler/unbundler.dart';
import 'command_base.dart';

/// `mold inspect <archive>` — describe a template without unpacking it.
///
/// What a person receiving a `.mold` file wants to know before running it:
/// what it is, which variables it asks for, and what it holds. Runs the same
/// archive and manifest checks an unpack would, so a template that inspects
/// cleanly can fail an unpack only on its variables or its target.
class InspectCommand extends MoldCommand {
  InspectCommand(super.out, super.err) {
    argParser.addFlag(
      'files',
      negatable: false,
      help: 'Also list every file, with its size.',
    );
  }

  @override
  String get name => 'inspect';

  @override
  String get description =>
      'Describe a template archive: its manifest, variables and files.';

  @override
  String get invocation => 'mold inspect <archive> [options]';

  @override
  Future<int> execute(ArgResults results) async {
    if (results.rest.isEmpty) {
      throw const CliException('Missing <archive>.');
    }

    final info = const Unbundler().inspect(
      Unbundler.readArchive(results.rest.first),
      onWarning: warn,
    );

    if (wantsJson) {
      emitJson(_json(info));
    } else {
      _print(info, withFiles: results['files'] as bool);
    }

    return 0;
  }

  void _print(TemplateInfo info, {required bool withFiles}) {
    final m = info.manifest;
    err.writeln(
      '${m.name} ${m.version} — ${info.sizes.length} files, '
      '${info.totalBytes} bytes, ${info.executable.length} executable.',
    );

    if (m.variables.isNotEmpty) {
      err.writeln('\nVariables:');
      for (final v in m.variables) {
        final facts = [
          if (v.replaces case final r?) 'replaces $r',
          if (v.defaultValue case final d?) 'default "$d"',
          if (v.pattern case final pattern?) 'pattern $pattern',
          if (v.choices.isNotEmpty) 'one of ${v.choices.join(', ')}',
          if (v.defaultValue == null) 'required',
        ];
        err.writeln('  ${v.name}  ${facts.join(' · ')}');
        if (v.description.isNotEmpty) {
          err.writeln('      ${v.description}');
        }
      }
    }

    void rules(String title, List<Substitution> items) {
      if (items.isEmpty) {
        return;
      }
      err.writeln('\n$title:');
      for (final s in items) {
        err.writeln('  ${s.from}  ->  ${s.to}');
      }
    }

    rules('Extra substitutions', m.extraSubstitutions);
    rules('Path renames', m.pathRenames);

    if (withFiles) {
      err.writeln('\nFiles:');
      for (final MapEntry(key: path, value: size) in info.sizes.entries) {
        final mark = info.executable.contains(path) ? '  (executable)' : '';
        err.writeln('  $path  $size$mark');
      }
    }
  }

  static Map<String, Object?> _json(TemplateInfo info) {
    final m = info.manifest;
    List<Map<String, String>> rules(List<Substitution> items) => [
      for (final s in items) {'from': s.from, 'to': s.to},
    ];

    return {
      'name': m.name,
      'version': m.version,
      'variables': [
        for (final v in m.variables)
          {
            'name': v.name,
            'description': v.description,
            'default': v.defaultValue,
            'replaces': v.replaces,
            'pattern': v.pattern,
            'choices': v.choices,
          },
      ],
      'extraSubstitutions': rules(m.extraSubstitutions),
      'pathRenames': rules(m.pathRenames),
      'files': [
        for (final MapEntry(key: path, value: size) in info.sizes.entries)
          {
            'path': path,
            'size': size,
            'executable': info.executable.contains(path),
          },
      ],
    };
  }
}
