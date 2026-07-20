# mold

Pack an existing project into a portable template archive, then unpack it under
a new name with manifest-driven renaming. Ships its own `mold` CLI (with
`pack` / `unpack` subcommands) and is consumable as a library.

The archive is a **verbatim** snapshot — substitution happens only at unpack
time, so one archive can be materialized under many names.

## How it works

```tree
mold pack   ./super_server  ->  super_server.mold  (gzipped tar)
                                 ├── mold.yaml     (the manifest, embedded)
                                 └── files/        (the project, verbatim)

mold unpack ./super_server.mold --var project_name=my_project
                              ->  ./super_server/  (renamed: paths + text,
                                                    binaries copied as-is)
```

`pack` reads the source but never mutates it. `unpack` resolves each variable,
generates all four casings of every `replaces` token, rewrites paths and text
file contents, and copies binary / `no_substitute` files byte-for-byte. The
archive is materialized in memory — no scratch directory is written to disk.

## Commands

```shell
mold pack <source_dir> [options]
  --manifest, -m   Path to the manifest      (default: <source_dir>/mold.yaml;
                                              error if absent and -m not given)
  --output,   -o   Output path               (default: ./<name>.mold, or
                                              ./<name>.dart for embed formats)
  --name,     -n   Output file name stem      (overrides the manifest name)
  --format,   -f   tar.gz | bytes | base64    (default: tar.gz)

mold unpack <source> [options]
  --target,   -t   Destination dir            (default: ./<source-stem>)
  --var,      -v   key=value                  (repeatable)
  --no-prompt      Use only --var + manifest defaults; never prompt
```

Run `mold help pack` / `mold help unpack` for the full option list.

## The manifest (`mold.yaml`)

```yaml
name: super_server
version: 1.0.0

# Which files to capture (globs, relative to the source dir).
# Empty `include` means "everything".
include:
  - "**"
exclude:
  - build/**
  - .dart_tool/**

# Rename rules. Each variable derives all four casings from one `replaces`
# token: snake_case, PascalCase, kebab-case, SCREAMING_SNAKE.
variables:
  project_name:
    description: The new project name
    default: my_project
    replaces: super_server   # super_server / SuperServer / super-server / SUPER_SERVER

# Literal replacements that automatic renaming can't reach (applied to text
# content only, not paths).
extra_substitutions:
  - from: https://api.super.dev
    to: https://api.example.com

# Text files copied verbatim (no substitution), even though their extension
# is text. Globs.
no_substitute:
  - pubspec.lock
  - "**/*.g.dart"

# Extra extensions treated as binary (copied untouched), on top of the
# built-in set (png, jpg, ttf, zip, sqlite, …).
binary_extensions:
  - myblob
```

## CLI usage

```sh
# Pack a project (default manifest: ./super_server/mold.yaml)
mold pack ./super_server -o super_server.mold

# Pack with an explicit manifest path
mold pack ./super_server -m ./templates/server.yaml -o server.mold

# Unpack under a new name, interactively (prompts for each unresolved variable,
# showing its description and default)
mold unpack ./super_server.mold -t ./my_project

# Unpack non-interactively (CI): explicit values + manifest defaults, no prompt
mold unpack ./super_server.mold -t ./my_project \
  --var project_name=my_project --no-prompt
```

During development, run it through `dart run`:

```sh
dart run mold:mold pack ./super_server -o super_server.mold
dart run mold:mold unpack ./super_server.mold -t ./my_project -v project_name=my_project
```

### Embedding a template in a binary

`-f bytes` / `-f base64` emit a Dart source file (with an
`AUTO-GENERATED — DO NOT EDIT` header) so a template can ship inside a compiled
executable and scaffold offline.

```sh
mold pack ./super_server -f bytes  -o lib/template.dart
mold pack ./super_server -f base64 -o lib/template.dart
```

```dart
// lib/template.dart (generated)
const List<int> kSuperServerTemplate = <int>[31, 139, 8, 0, /* ... */];
```

```dart
import 'package:mold/mold.dart';
import 'template.dart';

await const Unbundler().unbundleBytes(
  source: kSuperServerTemplate,
  targetDir: './my_project',
  vars: {'project_name': 'my_project'},
);
```

## Library usage

```dart
import 'package:mold/mold.dart';

// Pack — always returns the gzipped-tar archive bytes.
final archive = await const Bundler().bundle(
  projectDir: './super_server',
  manifest: Manifest.fromFile('./super_server/mold.yaml'),
);
await File('super_server.mold').writeAsBytes(archive);

// Unpack from a file…
await const Unbundler().unbundleFile(
  source: 'super_server.mold',
  targetDir: './my_project',
  vars: {'project_name': 'my_project'},
);

// …or straight from in-memory bytes (e.g. an embedded template).
await const Unbundler().unbundleBytes(
  source: archive,
  targetDir: './my_project',
  vars: {'project_name': 'my_project'},
);
```

### Variable resolution

An unresolved variable falls back to its manifest `default`. To prompt
interactively (or force non-interactive defaults), pass a `VariableResolver`:

```dart
import 'dart:io';

final resolver = VariableResolver(
  noPrompt: false, // true → defaults only, never prompt
  prompter: VariablePrompter(stdout, stdin.readLineSync),
);

await const Unbundler().unbundleBytes(
  source: archive,
  targetDir: './my_project',
  vars: const {},        // nothing explicit → resolver prompts / uses defaults
  resolver: resolver,
);
```

Precedence: explicit `vars` › `--no-prompt` (manifest defaults) › interactive
prompt.

### Rendering embed sources programmatically

```dart
final dartSource = const EmbedSource()
    .bytesSource(archive: archive, name: 'super_server');
await File('lib/template.dart').writeAsString(dartSource);
```

## Validation

Every phase is validated with structured, coded errors. A
`ValidationResult.throwIfInvalid()` throws a `ValidationException` when any
error-severity issue is present; warnings never block.

| Phase  | Validator            | Checks                                                                              |
| ------ | -------------------- | ----------------------------------------------------------------------------------- |
| pack   | `ManifestValidator`  | required fields, no duplicate variables, valid globs, non-empty `replaces`          |
| pack   | `ProjectValidator`   | dir exists, non-empty, each `replaces` token occurs (warns on partial-name overlap) |
| unpack | `ArchiveValidator`   | valid gzip+tar, contains `mold.yaml` and a `files/` tree                            |
| unpack | `ManifestValidator`  | (as above, on the embedded manifest)                                                |
| unpack | `VariablesValidator` | all required present; each `replaces` value is a well-formed name token             |
| unpack | `TargetValidator`    | parent exists, destination free, writable                                           |

Order — pack: `Manifest → Project`; unpack:
`Archive → Manifest → Variables → Target`. The first failing phase aborts before
the next runs. The CLI maps a `ValidationException` to exit code `1`.

## Out of scope

- Content-based binary detection (extensions only — no MIME sniffing).
- Templating beyond literal substitution (no conditionals/loops/partials).
- Compression other than gzip, encryption, or signing.
- Remote template registries / fetching over the network.
