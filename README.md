# mold

Pack an existing project into a portable template archive, then unpack it under
a new name. Ships a `mold` CLI and is consumable as a library.

The template **is a real project** — one that builds, runs and has tests. There
are no placeholders in the source: renaming rules live in a manifest beside it,
so the template stays lintable, reviewable and current by being the thing you
actually use. The archive is a verbatim snapshot; substitution happens only at
unpack, so one archive materializes under many names.

```tree
mold pack   ./super_server  ->  super_server.mold  (gzipped tar)
                                 ├── mold.yaml     (the manifest, embedded)
                                 └── files/        (the project, verbatim)

mold unpack ./super_server.mold --var project_name=my_project
                              ->  ./my_project/    (renamed: paths + text,
                                                    binaries copied as-is)
```

---

## Install

### As a CLI

```sh
dart install mold
```

That puts `mold` on your `PATH`. To pin a version, or to install before the
package is on pub.dev:

```sh
dart install mold@^0.1.0

# straight from git
dart install 'mold@{git: {url: https://github.com/pro100andrey/mold}}'

# from a local checkout
dart install 'mold@{path: /path/to/mold}'
```

On Dart SDKs older than the `dart install` command, use the classic form:

```sh
dart pub global activate mold
```

Check it: `mold --help`. If the command is not found, add pub's bin directory
to your `PATH` — `~/.pub-cache/bin` on macOS and Linux,
`%LOCALAPPDATA%\Pub\Cache\bin` on Windows.

### As a library

```sh
dart pub add mold
```

```dart
import 'package:mold/mold.dart';
```

### Requirements

Dart SDK **3.13.5 or newer**. No other runtime dependencies — `mold` shells out
to `chmod` on POSIX to restore executable bits, and does nothing at all if that
is unavailable.

---

## Contents

- [Install](#install) · [Quick start](#quick-start) · [Commands](#commands)
- [The manifest](#the-manifest-moldyaml) — [file selection](#file-selection) · [variables](#variables) · [substitutions](#substitutions) · [path renames](#path-renames) · [verbatim files](#verbatim-files)
- [Interpolation and transforms](#interpolation-and-transforms)
- [Choosing a `replaces` token](#choosing-a-replaces-token)
- [Previewing](#previewing-a-rename)
- [Validation](#validation) · [exit codes](#exit-codes)
- [Library usage](#library-usage) · [embedding](#embedding-a-template-in-a-binary)
- [What is preserved](#what-is-preserved) · [out of scope](#out-of-scope)

---

## Quick start

```sh
# 1. Describe the rename beside the project you already have.
cat > ./super_server/mold.yaml <<'YAML'
name: super_server
version: 1.0.0
variables:
  project_name:
    description: The new project name
    default: my_project
    replaces: super_server
YAML

# 2. See what it would do before it does it.
mold pack ./super_server --dry-run

# 3. Pack, then scaffold under any name.
mold pack ./super_server -o super_server.mold
mold unpack super_server.mold -t ./my_project --var project_name=my_project
```

## Commands

```shell
mold pack <source_dir> [options]
  --manifest, -m   Path to the manifest      (default: <source_dir>/mold.yaml;
                                              error if absent and -m not given)
  --output,   -o   Output path               (default: ./<name>.mold, or
                                              ./<name>.dart for embed formats)
  --name,     -n   Output file name stem      (also names the embedded const)
  --format,   -f   tar.gz | bytes | base64    (default: tar.gz)
  --var,      -v   key=value                  (repeatable, for --diff)
  --dry-run        Validate and list what would be captured, without writing
  --diff           Preview the renames this manifest would make

mold unpack <source> [options]
  --target,   -t   Destination dir            (default: ./<source-stem>)
  --var,      -v   key=value                  (repeatable)
  --no-prompt      Use only --var + manifest defaults; never prompt
  --force          Unpack into a non-empty target (see below)
  --dry-run        Show what would be written, without writing it
  --diff           Also show a unified diff (implies --dry-run)
```

### Unpacking into a non-empty directory

By default the target must not exist, or be an empty directory; anything else
is `TARGET_OCCUPIED`. `--force` writes into a directory that already holds
files — the way a tool regenerates a project in place:

- each file the template has is written over the file at the same path;
- every file the template does not have is left as it is;
- a target that is a file, not a directory, is still refused;
- a template file that would land on a directory, under a file, or through a
  symlink is `TARGET_PATH_CONFLICT`, reported before anything is written.

`--force` is not a merge: an overwritten file holds the template's version,
whatever was edited in it. Preview first — `--force --dry-run` lists what
would be created and what overwritten, and `--force --diff` diffs each
overwritten file against the one already there.

If a write still fails partway (a read-only file, a full disk), the
unpack is undone: created files are removed, overwritten files get their
previous content back, and directories it created are removed once empty.
Anything it could not undo is named in a warning. Writes go straight into the
target rather than through a scratch directory: moving a tree into an occupied
directory is one rename per file, so it would be no more atomic, and a scratch
directory can sit on another filesystem, where a rename is a copy.

`mold help pack` / `mold help unpack` for the full option list. During
development: `dart run mold:mold pack ./super_server`.

---

## The manifest (`mold.yaml`)

Every key, with its default:

```yaml
# ─── required ───────────────────────────────────────────────
name: super_server          # template name; default output file stem
version: 1.0.0              # free-form string

# ─── file selection ─────────────────────────────────────────
use_gitignore: true         # honour the project's own .gitignore files
include: []                 # globs; empty means "everything"
exclude: []                 # globs, applied on top of .gitignore

# ─── renaming ───────────────────────────────────────────────
variables:                  # {} — declared rename variables
  project_name:
    description: ''         # shown when prompting
    default: null           # absent → the variable is required
    replaces: null          # the source token; absent → interpolation only

extra_substitutions: []     # from/to, applied to CONTENT only
path_renames: []            # from/to, applied to PATHS only

# ─── copied verbatim ────────────────────────────────────────
no_substitute: []           # globs; content untouched, path still renamed
binary_extensions: []       # extra extensions treated as binary
```

Unknown keys are ignored silently, so check spelling — `excludes:` is not
`exclude:`.

### File selection

A file is packed only if it **passes `include`**, **passes `exclude`**, and is
**not gitignored**. Three independent filters, all must pass.

`use_gitignore` (default `true`) reads the project's own `.gitignore` files —
all of them, including nested per-platform ones — so a manifest never restates
`.dart_tool/**`, `build/**` and friends. The supported syntax is the real
thing: `!` negation, `/` anchoring, trailing-slash directory rules, `#`
comments, and last-match-wins ordering. `.git/` is always excluded. Set
`use_gitignore: false` to pack the tree exactly as it sits on disk.

`exclude` therefore carries only what git has no opinion about:

```yaml
exclude:
  - pubspec.lock            # committed, but a scaffold resolves its own
  - mold.yaml               # the template's own manifest
```

Symlinks: one pointing at a file **inside** the project *and* passing the same
filters is packed as its content. One pointing outside, at a directory, at
nothing, or at a filtered-out file is skipped with a `PROJECT_SYMLINK_SKIPPED`
warning. Following a link out of the project would let `pack` inline
`~/.ssh/id_rsa` into a template you then share.

### Variables

```yaml
variables:
  project_name:
    description: The new project name
    default: my_project
    replaces: super_server
```

`replaces` names a token in the source. At unpack, the resolved value replaces
**four derived casings** of it, in both paths and content:

| casing          | `super_server` → |
| --------------- | ---------------- |
| snake_case      | `super_server`   |
| kebab-case      | `super-server`   |
| SCREAMING_SNAKE | `SUPER_SERVER`   |
| PascalCase      | `SuperServer`    |

The source spelling does not matter: `super_server`, `superServer`,
`SuperServer` and `SUPER_SERVER` all declare the same rename.

**camelCase is deliberately not derived.** For a single-word token it is
indistinguishable from snake_case, so deriving it would be ambiguous — reach it
with an explicit transform instead (below).

A variable **without** `replaces` contributes no renames; it exists to be
interpolated. One that is neither used as a token nor referenced by any
substitution warns as `MANIFEST_UNUSED_VARIABLE`.

Resolution precedence: explicit `--var` › manifest `default` › interactive
prompt. End of input is not an answer — with stdin closed, a variable with no
default stays unresolved and is reported as `VARIABLE_MISSING`, rather than
silently becoming an empty string.

### Substitutions

For strings the four casings cannot reach. `from` is always a **literal**, so a
rule stays greppable against the real project; `to` is a template.

```yaml
extra_substitutions:
  - from: https://api.super.dev
    to: https://api.example.com
  - from: com.example.superServer
    to: com.example.{{ project_name | camelCase }}
```

**Content only** — these never touch paths.

### Path renames

The mirror image: **paths only**, never content.

```yaml
path_renames:
  - from: kotlin/com/example/super_server
    to: kotlin/com/example/{{ project_name }}
```

This exists for the case a `replaces` token structurally cannot express: when
one literal needs *opposite* treatment in different places. In a Flutter
project `android/app/` is a hard-coded Gradle module path that must survive,
while `kotlin/com/example/app/` is the package and must move.

Matching is longest-first, so an entry mapping a path to itself **pins** it
against a shorter rename:

```yaml
path_renames:
  - from: android/app/          # 12 chars — beats the "app" rename key
    to: android/app/            # pinned to itself
  - from: kotlin/com/example/app
    to: kotlin/com/example/{{ project_name }}
```

### Verbatim files

```yaml
no_substitute:                # text files copied byte-for-byte…
  - pubspec.lock              # …though their PATH is still renamed
  - "**/*.g.dart"

binary_extensions:            # on top of the built-in set
  - myblob                    # (png, jpg, ttf, zip, sqlite, …)
```

A file whose extension says text but whose bytes are not valid UTF-8 is also
copied verbatim rather than failing the unpack.

---

## Interpolation and transforms

Only the `to:` side of a substitution or path rename is a template.

```text
{{ variable }}                 the resolved value, unchanged
{{ variable | transform }}     the value through one transform
{{{{                           a literal "{{"
```

| transform       | value        | becomes      |
| --------------- | ------------ | ------------ |
| `snakeCase`     | `my_project` | `my_project` |
| `kebabCase`     | `my_project` | `my-project` |
| `camelCase`     | `my_project` | `myProject`  |
| `pascalCase`    | `my_project` | `MyProject`  |
| `screamingCase` | `my_project` | `MY_PROJECT` |
| `titleCase`     | `my_project` | `My Project` |
| `pathCase`      | `com.acme`   | `com/acme`   |

Whitespace inside the braces is insignificant. Chaining (`{{ a | x | y }}`) is
refused rather than read as a transform named `x | y`.

**Why this exists.** Flutter derives its Apple bundle identifier by camelCasing
the project name while Android keeps it snake, so one name yields
`com.example.myProject` **and** `com.example.my_project` in the same project —
plus `My Project` for the home-screen label. The four casings cover one of the
three; named transforms cover the rest.

The Android sources are the same fact one level up: they live in
`android/app/src/main/kotlin/com/example/…`, a directory path spelling out the
package the organisation names. `pathCase` derives that path from the
organisation itself — `com.acme` → `com/acme` — so the two cannot be set
inconsistently. It is the one transform that is not a case conversion: segments
keep the spelling they were given, so `com.acmeCorp` is `com/acmeCorp`, not
`com/acme/corp`.

Templates are validated at pack time *and* again at unpack, so a bad
placeholder or an undeclared variable fails when the template is built, not
when someone uses it. Rendering happens at unpack, and a rendered value is
never re-scanned — it cannot cascade into another substitution.

### Precedence

All rules are applied in a **single left-to-right pass**:

- longest match wins at the same position; leftmost wins across positions
- no cascading — a substituted value is never re-scanned
- an explicit substitution beats a derived rename key on collision
- between two variables whose tokens collapse to the same casings, the later
  one in the manifest wins

---

## Choosing a `replaces` token

Substitution is literal, so a token that is mostly a substring of other words
corrupts the project. `mold` measures this rather than guessing: it counts
every occurrence of every derived casing, and how many sit inside a longer
identifier.

| collateral | verdict                                 |
| ---------- | --------------------------------------- |
| ≥ 30%      | **error** — `PROJECT_TOKEN_TOO_GENERIC` |
| ≥ 5%       | warning — `PROJECT_PARTIAL_OVERLAP`     |
| below      | silent                                  |

A match is collateral when the characters around it continue the word *in the
casing that matched*. For the snake, kebab and SCREAMING forms a letter or
digit continues it, and `_`, `-` and anything else end it — so
`app_template_test` is a whole-word match for `replaces: app_template`, and
renaming it to `my_app_test` is the point. For the Pascal form only a following
lowercase letter continues it: `AppTemplateTest` and `MyAppTemplate` are whole
words, `AppTemplateer` is not. `my_app` in `my_appendix`, `app` in
`application` and `MyApp` in `MyApplication` are all still collateral.

Measured on a fresh `flutter create` project (Flutter 3.47): `bin` 75%, `test`
73%, `app` 65%; `runner` and the project's own name under 5%.

```text
[PROJECT_TOKEN_TOO_GENERIC] Variable 'project_name': token 'app' matches 615
times; 398 (65%) inside longer words: application (72),
flutter_application_1 (40), apple (36). Substituting it would rewrite those
too — pick a more distinctive token, or replace these sites with explicit
extra_substitutions.
```

When a token is too generic, the way forward is explicit `extra_substitutions`
and `path_renames`, not a blunter rename.

The manifest file itself is excluded from that search — a `replaces:` line is a
declaration, not evidence the project uses the token.

---

## Previewing a rename

```sh
mold unpack super_server.mold -t ./my_project --dry-run
```

```text
Dry run — nothing written to ./my_project.
  129 files: 3 renamed, 18 rewritten (50 replacements), 108 unchanged.

Renamed:
  android/.../com/example/super_server/MainActivity.kt  ->  .../my_project/...  (1)
  super_server.iml  ->  my_project.iml

Rewritten:
  pubspec.yaml  (1)
  macos/Runner.xcodeproj/project.pbxproj  (13)
```

Add `--diff` for the content changes as a unified diff. Unchanged files are
counted but not listed — a template is mostly unchanged files, and listing them
buries the ones that matter.

The preview runs the same validation, resolution and substitution rules as a
real unpack, so it cannot disagree with one; it is that computation minus the
writes. The target is validated too, so a dry run also answers "is the
destination usable".

Into an occupied target (`--force`), the preview says what the write would do
to the files already there:

```text
Dry run — nothing written to ./my_project.
  4 files: 1 renamed, 3 rewritten (5 replacements), 1 unchanged.
  Target is not empty: 1 to create, 3 to overwrite (2 identical).
...
Created:
  lib/src/new_in_template.dart

Overwritten:
  pubspec.yaml
```

Overwrites that would change nothing are counted, not listed. With `--diff`,
an overwritten file is diffed against the file already there (`--- pubspec.yaml
(in target)`), since that is the change the write makes; a created file is
diffed against the template, as without `--force`.

`mold pack --dry-run` is a **preflight**: which files would be captured, how
many each filter removed, and the token verdict.

```text
Dry run — nothing written. 129 files would be captured, 36 gitignored,
0 symlinks skipped.
```

`mold pack --diff` answers the other question a template author has — *are my
rules right?* — without packing, distributing and unpacking first:

```sh
mold pack ./super_server --diff --var project_name=tempo
```

```text
Preview — nothing written.
  129 files: 1 renamed, 18 rewritten (50 replacements), 111 unchanged.
...
--- linux/runner/my_application.cc
+++ linux/runner/my_application.cc
-    gtk_window_set_title(window, "app");
+    gtk_window_set_title(window, "tempo");
```

The archive is built in memory and handed to the same planner `unpack --diff`
uses, so the two cannot disagree. Values come from `--var` and manifest
defaults only — `pack` never prompts, so it stays usable from CI.

---

## Validation

Every phase is validated with structured, coded errors.
`ValidationResult.throwIfInvalid()` throws a `ValidationException` when any
error-severity issue is present; warnings never block and are printed to
stderr.

| Phase  | Code                                | Meaning                                        |
| ------ | ----------------------------------- | ---------------------------------------------- |
| pack   | `MANIFEST_MISSING_NAME`             | required field absent                          |
| pack   | `MANIFEST_MISSING_VERSION`          | required field absent                          |
| pack   | `MANIFEST_DUPLICATE_VARIABLE`       | two variables share a name                     |
| pack   | `MANIFEST_INVALID_GLOB`             | a bad pattern in include/exclude/no_substitute |
| pack   | `MANIFEST_EMPTY_REPLACES`           | `replaces: ""`                                 |
| pack   | `MANIFEST_UNSUPPORTED_REPLACES`     | token has no ASCII word characters             |
| pack   | `MANIFEST_MALFORMED_PLACEHOLDER`    | bad syntax inside `{{ }}`                      |
| pack   | `MANIFEST_UNTERMINATED_PLACEHOLDER` | `{{` with no `}}`                              |
| pack   | `MANIFEST_UNKNOWN_VARIABLE`         | placeholder names an undeclared variable       |
| pack   | `MANIFEST_UNKNOWN_TRANSFORM`        | not one of the six transforms                  |
| pack   | `MANIFEST_UNUSED_VARIABLE` ⚠        | variable does nothing                          |
| pack   | `MANIFEST_DUPLICATE_SUBSTITUTION`   | two entries in one section share a `from`      |
| pack   | `PROJECT_DIR_NOT_FOUND`             | source directory missing                       |
| pack   | `PROJECT_DIR_EMPTY`                 | nothing to pack after filtering                |
| pack   | `PROJECT_REPLACES_NOT_FOUND`        | token occurs in no captured file               |
| pack   | `PROJECT_TOKEN_TOO_GENERIC`         | ≥30% of matches are collateral                 |
| pack   | `PROJECT_PARTIAL_OVERLAP` ⚠         | ≥5% of matches are collateral                  |
| pack   | `PROJECT_SYMLINK_SKIPPED` ⚠         | a symlink was left out, with the reason        |
| unpack | `ARCHIVE_INVALID`                   | not a valid gzipped tar                        |
| unpack | `ARCHIVE_TOO_LARGE`                 | decompresses past the size ceiling             |
| unpack | `ARCHIVE_MISSING_MANIFEST`          | no embedded `mold.yaml`                        |
| unpack | `ARCHIVE_MISSING_FILES`             | no `files/` tree                               |
| unpack | `ARCHIVE_UNSAFE_PATH`               | an entry escapes the target directory          |
| unpack | `TARGET_PARENT_NOT_FOUND`           | parent directory missing                       |
| unpack | `TARGET_OCCUPIED`                   | target is a file, or not empty (no `--force`)  |
| unpack | `TARGET_NOT_WRITABLE`               | no write permission                            |
| unpack | `VARIABLE_MISSING`                  | required variable has no value                 |
| unpack | `VARIABLE_INVALID_FORMAT`           | value is not a well-formed name token          |
| unpack | `VARIABLE_UNKNOWN`                  | `--var` names a variable the template lacks    |
| unpack | `RENAME_COLLISION`                  | two entries would land on the same path        |
| unpack | `TARGET_PATH_CONFLICT`              | `--force`: a path is blocked in the target     |

⚠ = warning; does not block.

Every warning is reported at **both** pack and unpack. A template is usually
unpacked by someone other than its author, so a warning that only reached
whoever packed it reached nobody.

Phase order — pack: `Manifest → Project`; unpack:
`Archive → Manifest → Target → Variables → Rename`. The first failing phase aborts
before the next runs. Target precedes variables so an interactive unpack does
not make you answer every prompt before learning the destination is occupied.
`TARGET_PATH_CONFLICT` is the one target check that runs after Rename: which
paths conflict depends on where renaming puts each file.

### Exit codes

| code | meaning                          |
| ---- | -------------------------------- |
| `0`  | success                          |
| `1`  | validation, IO or format failure |
| `64` | usage error (bad arguments)      |

---

## Library usage

```dart
import 'package:mold/mold.dart';

// Pack — always returns the gzipped-tar archive bytes.
final archive = await const Bundler().bundle(
  projectDir: './super_server',
  manifest: Manifest.fromFile('./super_server/mold.yaml'),
  onWarning: (message) => print('Warning: $message'),
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

`onWarning` receives non-fatal problems that would otherwise be invisible — a
skipped symlink, a token that will over-reach, a failed `chmod`.

`overwrite: true` is the CLI's `--force`, on `unbundle`, `unbundleBytes`,
`unbundleFile` and `plan`:

```dart
await const Unbundler().unbundleBytes(
  source: archive,
  targetDir: './my_project', // may already hold files
  vars: {'project_name': 'my_project'},
  overwrite: true,
);
```

### Previewing programmatically

```dart
final plan = const Unbundler().plan(
  bytes: archive,
  targetDir: './my_project',
  vars: {'project_name': 'my_project'},
);

for (final file in plan.renamed) {
  print('${file.from} -> ${file.to} (${file.replacements})');
}
print('${plan.totalReplacements} replacements in ${plan.files.length} files');
```

Each `PlannedFile` carries `from`, `to`, `verbatim`, `replacements`, and — for
text files — `before` and `after`, which `UnifiedDiff` renders. With
`overwrite: true` it also says whether it `overwrites` a file already in the
target, whether that file is `identicalToExisting`, and the `existing` text;
`plan.created` and `plan.overwritten` split the files by it.

### Prompting

```dart
final resolver = VariableResolver(
  noPrompt: false, // true → defaults only, never prompt
  prompter: VariablePrompter(stdout, stdin.readLineSync),
);

await const Unbundler().unbundleBytes(
  source: archive,
  targetDir: './my_project',
  vars: const {},
  resolver: resolver,
);
```

Catch `ValidationException` — not `FormatException` — to handle a missing
variable.

---

## Embedding a template in a binary

`-f bytes` / `-f base64` emit a Dart source file (with an
`AUTO-GENERATED — DO NOT EDIT` header) so a template can ship inside a compiled
executable and scaffold offline.

The file is meant to be committed into your package, so it is made to pass
your tooling unchanged. It carries `// ignore_for_file: type=lint`, the standard
header of generated code: lint sets disagree about its very declarations
(`omit_obvious_property_types` against `always_specify_types`), so no spelling
of them would satisfy every set, and errors are still reported. And
`dart format` leaves it as it is, in both the tall and the pre-3.7 style — no
need to exclude it from a format check.

```sh
mold pack ./super_server -f bytes  -o lib/template.dart
mold pack ./super_server -f base64 -o lib/template.dart
```

```dart
// lib/template.dart (generated)
// AUTO-GENERATED — DO NOT EDIT.
// Produced by `mold pack`.

// ignore_for_file: type=lint

const List<int> kSuperServerTemplate = <int>[
  // 2741 bytes: a gzipped tar archive.
  31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 237, 189, 107, 115, 219,
  // ...
];
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

`-n` names both the output file and the generated const, so two templates
packed from one manifest do not collide on the identifier.

To render the source yourself:

```dart
final dartSource = const EmbedSource()
    .bytesSource(archive: archive, name: 'super_server');
```

---

## What is preserved

- **The owner-executable bit** — a template's scripts and hooks stay runnable.
- **A leading UTF-8 BOM** — Windows-authored `.bat`, `.ps1` and `.csproj` keep
  their encoding marker.
- **Bytes of anything not substituted** — binaries, `no_substitute` matches,
  and any file that is not valid UTF-8, including CRLF, NUL bytes and emoji.

The archive is materialized in memory — no scratch directory is written to
disk, and `pack` never mutates the source.

## Out of scope

- **Templating the packed files.** Project content is never evaluated — no
  conditionals, loops, partials or includes, and a `{{ }}` inside a packed file
  is just text. The one place `{{ }}` is interpreted is a manifest `to:` value.
- **Content-based binary detection** — extensions only, no MIME sniffing. The
  UTF-8 fallback is a decode failure, not classification.
- **File modes beyond the executable bit** — no ownership, no full mode round
  trip.
- **Preserving symlinks as symlinks** — they are dereferenced, so an unpack
  needs no symlink privileges (Windows requires them).
- **Empty directories** — not represented in the archive.
- **Compression other than gzip**, encryption, or signing.
- **Remote template registries** or fetching over the network.
- **Updating an already-scaffolded project** when its template moves forward.
  `--force` regenerates over it, but replaces rather than merges: edits in the
  files the template has are overwritten.
