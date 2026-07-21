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

The owner-executable bit is carried through the archive, so a template's
scripts and hooks stay runnable. A file whose extension says text but whose
bytes are not valid UTF-8 is copied verbatim rather than failing the unpack.

A symlink pointing at a file **inside** the source dir is packed as its
content, so the unpacked project needs no symlink privileges (Windows requires
them) and substitution reaches the content. A symlink pointing outside, at a
directory, or at nothing is skipped with a `PROJECT_SYMLINK_SKIPPED` warning —
following one out of the project would let `pack` inline `~/.ssh/id_rsa` into a
template you then share.

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

## Interpolation in substitutions

`replaces` derives four casings — snake, kebab, SCREAMING and Pascal — and that
is deliberately all. A fifth would not generalise: for a single-word token
camelCase is indistinguishable from snake_case, so deriving it is ambiguous.

Forms outside those four are reached by naming them. Only the `to:` side of an
`extra_substitutions` entry is a template; `from:` is always literal, so a
template stays greppable against the real project.

```text
{{ variable }}                 the resolved value, unchanged
{{ variable | transform }}     the value through one transform
{{{{                           a literal "{{"
```

| transform       | `my_project` becomes |
| --------------- | -------------------- |
| `snakeCase`     | `my_project`         |
| `kebabCase`     | `my-project`         |
| `camelCase`     | `myProject`          |
| `pascalCase`    | `MyProject`          |
| `screamingCase` | `MY_PROJECT`         |
| `titleCase`     | `My Project`         |

Whitespace inside the braces is insignificant. Chaining (`{{ a | x | y }}`) is
refused rather than read as a transform named `x | y`. A variable declared
without `replaces` exists precisely to be interpolated.

Why this matters concretely: Flutter derives its Apple bundle identifier by
camelCasing the project name while Android keeps it snake, so one name yields
`com.example.myProject` **and** `com.example.my_project` in the same project.
The four casings cover the second; the first needs a named transform.

Templates are validated at pack time (and again at unpack), so a bad
placeholder or an undeclared variable fails when the template is built, not
when someone uses it. Rendering happens at unpack, and a rendered value is
never re-scanned — it cannot cascade into another substitution.

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

# Replacements that automatic renaming can't reach (applied to text content
# only, not paths). `from` is always literal; `to` may interpolate a variable
# through a case transform.
extra_substitutions:
  - from: https://api.super.dev
    to: https://api.example.com
  - from: com.example.superServer            # a casing `replaces` can't derive
    to: com.example.{{ project_name | camelCase }}

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

A variable that none of those can fill is **left out** of the resolved map
rather than raising on the spot, so `VariablesValidator` reports every gap at
once as `VARIABLE_MISSING`. Catch `ValidationException` — not `FormatException`
— to handle a missing variable.

`unbundleBytes` / `unbundleFile` / `unbundle` also take an `onWarning` callback,
which receives non-fatal problems that would otherwise be invisible, such as
failing to restore an executable bit. The CLI prints these to stderr.

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

| Phase  | Validator            | Checks                                                                                                        |
| ------ | -------------------- | ------------------------------------------------------------------------------------------------------------- |
| pack   | `ManifestValidator`  | required fields, no duplicate variables, valid globs, usable `replaces` tokens, well-formed `{{ }}` templates |
| pack   | `ProjectValidator`   | dir has files to pack; each `replaces` token occurs and is distinctive enough                                 |
| unpack | `ArchiveValidator`   | valid gzip+tar, contains `mold.yaml` and a `files/` tree, no entry escapes the target                         |
| unpack | `ManifestValidator`  | (as above, on the embedded manifest)                                                                          |
| unpack | `TargetValidator`    | parent exists, destination free, writable                                                                     |
| unpack | `VariablesValidator` | all required present; each `replaces` value is a well-formed name token                                       |

The CLI maps these to exit codes: `0` ok, `1` validation / IO / format
failure, `64` usage error. Warnings print to stderr and never block.

A `replaces` token is measured, not just located. `ProjectValidator` counts how
often each derived casing occurs and how much of that sits inside longer words:
at or above 30% it refuses to pack (`PROJECT_TOKEN_TOO_GENERIC`, naming the
worst offenders), at or above 5% it warns. `app` in a Flutter project measures
75% — `application`, `apple`, `AppIcon` — and is refused; a project named after
itself measures ~14% and only warns. When a token is too generic, the way
forward is explicit `extra_substitutions` rather than a blunter rename.

The manifest file itself is excluded from that search: a `replaces:` line is a
declaration, not evidence the project uses the token.

Order — pack: `Manifest → Project`; unpack:
`Archive → Manifest → Target → Variables`. The first failing phase aborts before
the next runs.

`ProjectValidator` checks the files the pack will actually capture — the
`include` / `exclude` globs apply to validation too, so a token that occurs only
in an excluded file is reported as missing.

Target is validated *before* variables because resolving them may prompt:
otherwise you would answer every prompt and only then learn the destination was
occupied. A variable that cannot be resolved is reported as `VARIABLE_MISSING`
along with all the others, rather than aborting on the first one.

## Out of scope

- Content-based binary detection (extensions only — no MIME sniffing; the
  UTF-8 fallback above is a decode failure, not classification).
- File modes beyond the executable bit (no ownership, no full mode round trip).
- Preserving symlinks as symlinks (they are dereferenced; see above).
- Templating the packed files. Project content is never evaluated — no
  conditionals, loops, partials or includes, and a `{{ }}` inside a packed file
  is just text. The one place `{{ }}` is interpreted is a manifest `to:` value.
- Compression other than gzip, encryption, or signing.
- Remote template registries / fetching over the network.
