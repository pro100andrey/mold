import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The record an unpack can leave in its target: which template, which
/// variable values, and which files it wrote.
///
/// Written as `.mold.json` when asked for (`stamp: true`, `mold unpack
/// --stamp`), and kept up to date by every later overwrite into the same
/// target. It is what makes regenerating a project cheap and honest:
///
/// - its [vars] can be fed back (`--vars-file .mold.json`), so a regeneration
///   does not depend on remembering what was typed the first time;
/// - its [files] say what the previous unpack owned, so a regeneration can
///   report the files the template has since dropped — left in place, never
///   deleted, since they may have been edited;
/// - and what each held, so a regeneration can tell which of the files it is
///   about to overwrite were edited since — the one loss `--force` would
///   otherwise inflict without a word.
class UnpackStamp {
  const UnpackStamp({
    required this.template,
    required this.version,
    required this.vars,
    required this.files,
  });

  /// Parses a stamp; null when [text] is not one.
  ///
  /// Recognized by its `mold_stamp` key, so an ordinary `.mold.json` of
  /// someone else's is not mistaken for one.
  static UnpackStamp? tryParse(String text) {
    final Object? doc;
    try {
      doc = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (doc is! Map<String, Object?> || doc['mold_stamp'] != formatVersion) {
      return null;
    }

    final vars = doc['vars'];
    final files = doc['files'];
    final template = doc['template'];
    final version = doc['version'];
    if (vars is! Map<String, Object?> ||
        files is! Map<String, Object?> ||
        template is! String ||
        version is! String) {
      return null;
    }

    return UnpackStamp(
      template: template,
      version: version,
      vars: {for (final e in vars.entries) e.key: '${e.value}'},
      files: {for (final e in files.entries) e.key: '${e.value}'},
    );
  }

  /// The file name, at the root of the target.
  static const fileName = '.mold.json';

  /// Bumped when the shape changes incompatibly.
  static const formatVersion = 1;

  /// The template's manifest `name`.
  final String template;

  /// The template's manifest `version`.
  final String version;

  /// The resolved value of every declared variable.
  final Map<String, String> vars;

  /// Every path the unpack wrote, relative to the target, sorted — the stamp
  /// itself excluded — with the [digest] of the bytes it wrote there.
  final Map<String, String> files;

  /// The digest a stamp records for [bytes]: SHA-256, in hex.
  ///
  /// Cryptographic not for security — nothing here is adversarial — but
  /// because a change detector that can miss a change is not one.
  static String digest(List<int> bytes) => sha256.convert(bytes).toString();

  /// The stamp as `.mold.json` holds it: indented and with a trailing newline,
  /// so it diffs well when committed.
  String toJson() =>
      '${const JsonEncoder.withIndent('  ').convert({
        'mold_stamp': formatVersion,
        'template': template,
        'version': version,
        'vars': vars,
        'files': files,
      })}\n';
}
