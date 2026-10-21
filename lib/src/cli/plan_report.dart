import '../output/unified_diff.dart';
import '../unbundler/unpack_plan.dart';

/// The unified diff of what writing [f] changes, or null when there is
/// nothing to show.
///
/// Into an occupied target the change is against the file already there —
/// that is what the write does to it. Anywhere else it is the template's own
/// text before and after substitution. Needs a plan built with content.
String? diffOf(PlannedFile f) {
  const differ = UnifiedDiff();
  if (f.overwrites) {
    if (f.identicalToExisting) {
      return null;
    }
    final existing = f.existing;
    final after = f.after;
    if (existing == null || after == null) {
      return 'Binary file ${f.to} differs from the one in the target.\n';
    }

    return _orNull(
      differ.render(
        before: existing,
        after: after,
        fromLabel: '${f.to} (in target)',
        toLabel: f.to,
      ),
    );
  }

  final before = f.before;
  final after = f.after;
  if (f.replacements == 0 || before == null || after == null) {
    return null;
  }

  return _orNull(
    differ.render(
      before: before,
      after: after,
      fromLabel: f.from,
      toLabel: f.to,
    ),
  );
}

String? _orNull(String s) => s.isEmpty ? null : s;

/// Prints what an unpack would do: a summary, the renames, the per-file
/// replacement counts, and optionally a unified diff of each change.
///
/// Files nothing happens to are counted but not listed — a template is
/// mostly unchanged files, and listing them buries the ones that matter.
///
/// Into an occupied target (`--force`), it also says which files would be
/// created and which overwritten. Overwrites that change nothing are counted,
/// not listed.
void printPlan(
  StringSink err,
  UnpackPlan plan, {
  required bool showDiff,
  required bool applied,
}) {
  final renamed = plan.renamed.toList();
  final rewritten = plan.rewritten.toList();
  final overwritten = plan.overwritten.toList();
  final replacing = overwritten.where((f) => !f.identicalToExisting).toList();

  final target = plan.targetDir;
  if (target != null && !applied) {
    err.writeln('Dry run — nothing written to $target.');
  }
  err.writeln(
    '  ${plan.files.length} files: ${renamed.length} renamed, '
    '${rewritten.length} rewritten (${plan.totalReplacements} '
    'replacements), ${plan.untouched.length} unchanged.',
  );
  if (overwritten.isNotEmpty) {
    final identical = overwritten.length - replacing.length;
    err.writeln(
      '  Target is not empty: ${plan.created.length} to create, '
      '${overwritten.length} to overwrite ($identical identical).',
    );
  }

  void section(String title, Iterable<String> lines) {
    if (lines.isEmpty) {
      return;
    }
    err.writeln('\n$title:');
    for (final line in lines) {
      err.writeln('  $line');
    }
  }

  String count(PlannedFile f) =>
      f.replacements > 0 ? '  (${f.replacements})' : '';
  section('Renamed', [
    for (final f in renamed) '${f.from}  ->  ${f.to}${count(f)}',
  ]);
  section('Rewritten', [
    for (final f in rewritten)
      if (!f.renamed) '${f.to}  (${f.replacements})',
  ]);
  if (overwritten.isNotEmpty) {
    section('Created', [for (final f in plan.created) f.to]);
    section('Overwritten', [for (final f in replacing) f.to]);
  }
  section('Edited since the last unpack — overwriting discards the edits', [
    for (final f in plan.edited) f.to,
  ]);
  section('No longer in the template (left in place)', plan.stale);

  if (!showDiff) {
    if (!applied && (rewritten.isNotEmpty || replacing.isNotEmpty)) {
      err.writeln('\nRe-run with --diff to see the content changes.');
    }
    return;
  }

  for (final f in plan.files) {
    if (diffOf(f) case final rendered?) {
      err
        ..writeln()
        ..write(rendered);
    }
  }
}

/// [plan] as a JSON object, for `--json`.
Map<String, Object?> planJson(
  UnpackPlan plan, {
  required bool showDiff,
  required bool applied,
}) {
  final overwritten = plan.overwritten.toList();

  return {
    'template': {
      'name': plan.manifest.name,
      'version': plan.manifest.version,
    },
    'target': plan.targetDir,
    'overwrite': plan.overwrite,
    'applied': applied,
    'values': plan.values,
    'summary': {
      'files': plan.files.length,
      'renamed': plan.renamed.length,
      'rewritten': plan.rewritten.length,
      'replacements': plan.totalReplacements,
      'unchanged': plan.untouched.length,
      'created': plan.created.length,
      'overwritten': overwritten.length,
      'identical': overwritten.where((f) => f.identicalToExisting).length,
    },
    'files': [
      for (final f in plan.files)
        {
          'from': f.from,
          'to': f.to,
          'verbatim': f.verbatim,
          'replacements': f.replacements,
          'executable': f.executable,
          'overwrites': f.overwrites,
          'identicalToExisting': f.identicalToExisting,
          'generated': f.generated,
          'editedSinceStamp': f.editedSinceStamp,
          if (showDiff) 'diff': diffOf(f),
        },
    ],
    'stale': plan.stale,
  };
}
