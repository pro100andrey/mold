import 'package:path/path.dart' as p;

// Checks on what a template would carry to the people who unpack it, rather
// than on how it renames: secrets that should not leave the author's
// machine, and paths that cannot exist on theirs.
//
// Advisory throughout. Each finding may be deliberate — a placeholder key, a
// Linux-only template — so they warn, and the warning says what to do if it
// is not.

/// Why the file at [rel] looks like a secret by its name alone, or null.
///
/// Matched on the base name, case-insensitively. `.env` variants meant to
/// be committed (`.env.example`, `.env.sample`, …) are not flagged.
String? secretByName(String rel) {
  final base = p.posix.basename(rel).toLowerCase();
  if (base == '.env' ||
      (base.startsWith('.env.') && !_envTemplates.hasMatch(base))) {
    return 'an environment file';
  }
  if (_keyNames.contains(base)) {
    return 'an SSH private key';
  }
  if (_namedSecrets[base] case final what?) {
    return what;
  }
  final ext = p.posix.extension(base);
  if (_secretExtensions[ext] case final what?) {
    return what;
  }

  return null;
}

/// Why [text] looks like it holds a secret, or null.
///
/// The shapes are the well-known, high-confidence ones — a PEM private key
/// block, an AWS access key id, a Google API key (what a FlutterFire
/// `firebase_options.dart` holds), a GitHub token — so a hit is worth
/// reading, not noise to scroll past.
///
/// Two patterns, not one. Each alternative opens on a distinct literal, and
/// the regex engine scans fast for one literal but not for a mix: the six
/// shapes in a single alternation cost 600 ms over a 48 MB corpus, these two
/// about 80.
String? secretInContent(String text) {
  for (final (pattern, kinds) in _contentSecrets) {
    final m = pattern.firstMatch(text);
    if (m == null) {
      continue;
    }
    for (final (index, what) in kinds.indexed) {
      if (m.group(index + 1) != null) {
        return what;
      }
    }
  }

  return null;
}

/// Groups of [paths] that differ only in letter case.
///
/// On a case-insensitive filesystem — macOS and Windows by default — each
/// group is one file, and unpacking writes its members over each other.
List<List<String>> caseCollisions(Iterable<String> paths) {
  final byFolded = <String, List<String>>{};
  for (final path in paths) {
    (byFolded[path.toLowerCase()] ??= []).add(path);
  }

  return [
    for (final group in byFolded.values)
      if (group.length > 1) group,
  ];
}

/// Why [rel] cannot be created on Windows, or null.
String? windowsProblem(String rel) {
  for (final segment in rel.split('/')) {
    final stem = segment.split('.').first.toUpperCase();
    if (_reserved.hasMatch(stem)) {
      return "'$segment' is a reserved device name";
    }
    final bad = _invalidChars.firstMatch(segment);
    if (bad != null) {
      final char = bad[0]!;
      final shown = char.codeUnitAt(0) < 0x20
          ? 'a control character'
          : "'$char'";
      return "'$segment' contains $shown";
    }
    if (segment.endsWith('.') || segment.endsWith(' ')) {
      return "'$segment' ends with a dot or a space";
    }
  }

  return null;
}

final _envTemplates = RegExp(
  r'\.(example|sample|template|dist|defaults?|tpl)$',
);

const _keyNames = {'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519'};

const _namedSecrets = {
  'key.properties': 'an Android signing configuration',
  'google-services.json': 'a Firebase project configuration',
  'googleservice-info.plist': 'a Firebase project configuration',
  'credentials.json': 'a credentials file',
  '.netrc': 'a credentials file',
};

const _secretExtensions = {
  '.pem': 'a PEM certificate or key',
  '.key': 'a private key',
  '.p8': 'a private key',
  '.p12': 'a certificate bundle',
  '.pfx': 'a certificate bundle',
  '.jks': 'a Java keystore',
  '.keystore': 'a keystore',
  '.mobileprovision': 'an Apple provisioning profile',
};

final _contentSecrets = [
  (
    RegExp(
      '(-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----)'
      '|(AKIA[0-9A-Z]{16})'
      '|(AIza[0-9A-Za-z_-]{35})',
    ),
    ['a private key block', 'an AWS access key id', 'a Google API key'],
  ),
  (RegExp('(ghp_[A-Za-z0-9]{36})'), ['a GitHub token']),
];

final _reserved = RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$');

final _invalidChars = RegExp(r'[<>:"|?*\x00-\x1F]');
