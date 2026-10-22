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
dart install mold@^0.2.0

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

- [Install](#install) · [Quick start](#quick-start) · [Commands](#commands) · [`init`](#starting-a-manifest)
- [The manifest](#the-manifest-moldyaml) — [file selection](#file-selection) · [variables](#variables) · [substitutions](#substitutions) · [path renames](#path-renames) · [verbatim files](#verbatim-files) · [message](#message)
- [Interpolation and transforms](#interpolation-and-transforms)
- [Choosing a `replaces` token](#choosing-a-replaces-token)
- [Previewing](#previewing-a-rename)
- [Validation](#validation) · [exit codes](#exit-codes)
- [Library usage](#library-usage) · [embedding](#embedding-a-template-in-a-binary)
- [What is preserved](#what-is-preserved) · [out of scope](#out-of-scope)

---

## Quick start

```sh
# 1. Describe the rename beside the project you already have —
#    `mold init ./super_server` writes a start — or by hand:
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
mold init [dir] [options]
  --token          The name to replace        (default: detected, see below)
  --variable       The variable replacing it  (default: project_name)
  --yes,      -y   Add the suggested entries without asking
  --no-prompt      Never ask; leave the suggestions out
  --force          Overwrite an existing mold.yaml
  --dry-run        Print the manifest on stdout instead of writing it
  --json           Print the result as JSON on stdout

mold pack <source_dir> [options]
  --manifest, -m   Path to the manifest      (default: <source_dir>/mold.yaml;
                                              error if absent and -m not given)
  --output,   -o   Output path               (default: ./<name>.mold, or
                                              ./<name>.dart for embed formats)
  --name,     -n   Output file name stem      (also names the embedded const)
  --format,   -f   tar.gz | bytes | base64    (default: tar.gz)
  --level          gzip level 0-9             (default: 6)
  --fast           zlib instead of pure-Dart deflate (faster; bytes vary by OS)
  --var,      -v   key=value                  (repeatable, for --diff)
  --vars-file      YAML/JSON values, or a stamp (for --diff)
  --dry-run        Validate and list what would be captured, without writing
  --diff           Preview the renames this manifest would make
  --check          Exit 1 if the output file is stale; write nothing
  --json           Print the result as JSON on stdout

mold unpack <source | -> [options]
  --target,   -t   Destination dir            (default: ./<source-stem>)
  --var,      -v   key=value                  (repeatable; overrides the file)
  --vars-file      YAML/JSON values, or a .mold.json stamp
  --no-prompt      Use only --var + manifest defaults; never prompt
  --force          Unpack into a non-empty target (see below)
  --stamp          Record the unpack in <target>/.mold.json
  --dry-run        Show what would be written, without writing it
  --diff           Also show a unified diff (implies --dry-run)
  --json           Print the plan as JSON on stdout

mold inspect <archive | -> [options]
  --files          Also list every file, with its size
  --manifest       Print the embedded mold.yaml as written, on stdout
  --json           Print the description as JSON on stdout
```

`mold help <command>` for the full option list. During development:
`dart run mold:mold pack ./super_server`.

Human-facing output goes to stderr; stdout carries only `--json` documents.
Under `--json`, warnings are part of the document, and a failure is a document
too — `{"errors": [{"code": …, "message": …}], "warnings": […]}` with exit 1 —
so a tool reading stdout always gets JSON. Failures that carry no library code
use `CLI_USAGE` (bad arguments, a missing vars file — exit 64) and
`IO_FAILURE` (exit 1).

### Starting a manifest

`mold init ./app_template` writes a starting `mold.yaml`: the project's own
name as the `replaces` token of one variable, `project_name`, and the manifest
itself excluded from what it packs. The name is read from the project's
package manifest — `pubspec.yaml`, `package.json`, `composer.json`,
`Cargo.toml`, `go.mod`, `pyproject.toml`, `settings.gradle(.kts)`, `pom.xml`,
`Package.swift` or a lone `.csproj`, `.fsproj` or `.vbproj` — else taken from the directory;
`--token` names it instead.

It then runs the pack's checks on that draft. Spellings of the name the four
derived casings miss are offered as entries — `extra_substitutions` for those
in file content, `path_renames` for those in paths, both when they are in
both. On a fresh Flutter project, the bundle id and the display name:

```text
Spellings of the name no derived casing covers:
  'appTemplate' → {{ project_name | camelCase }}  (2 files)
  'App Template' → {{ project_name | titleCase }}  (1 file)
Add them to extra_substitutions? [Y/n]
```

Everything else the pack would say — a token too generic, a suspected secret
— is reported as a warning, and the manifest is written anyway: it is a start,
to review with `mold pack ./app_template --dry-run`.

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

### Reading the archive from stdin

`-` in place of the archive reads it from stdin, so a template on a server
needs no intermediate file:

```sh
curl -sL https://example.com/app.mold | mold unpack - -t ./my_app --var name=my_app
```

stdin then carries the archive, so nothing can be prompted for: values come
from `--var`, `--vars-file` and defaults, as under `--no-prompt`, and
`--target` is required — there is no file name to derive it from.
`mold inspect -` works the same way.

### Inspecting a template

`mold inspect super_server.mold` says what a template is before you run it: its
name and version, the variables it asks for (with defaults, patterns and
choices), its explicit substitutions, and — with `--files` — what it holds. It
runs the archive and manifest checks an unpack runs, so a template that
inspects cleanly can fail an unpack only on its variables or its target.
`--manifest` prints the embedded `mold.yaml` itself, as written — on stdout,
so `mold inspect app.mold --manifest > mold.yaml` recovers it.

### Checking a committed archive in CI

```sh
mold pack ./templates/app -f bytes -o lib/src/template.dart --check
```

Exit 0 when the file holds what packing would write now, 1 when it is stale or
missing — with what changed: `1 changed (lib/main.dart); 1 added (…)`.
Nothing is written.

The comparison is by **content**: the archive is unpacked from the committed
file (from inside the Dart source, for `-f bytes|base64`) and its manifest,
files and executable bits compared with the project's. Compressed bytes are
not compared, so a file written on another OS, by another Dart SDK, at another
`--level` or with `--fast` is not called stale when its content is current.
An embed source must also be exactly what this mold renders around its
archive, so a changed `-n` or a newer mold's layout is stale too. Line endings
are not a change: a source committed with LF and checked out with CRLF — Git
for Windows' default — is current.

Nothing is compressed for the check: the project's files are compared with the
committed archive's as they are read. On a 48 MB project it takes 0.7 s, a
third of a pack.

### Reproducible archives

Packing the same tree and manifest at the same `--level` gives the same bytes
on any OS and Dart SDK — for a given version of mold and `package:archive` —
so regenerating a committed `-f bytes` source on another machine is an empty
diff. Two things are pinned for it: compression uses `package:archive`'s
pure-Dart deflate rather than the zlib built into the VM, whose output can
vary by platform; and every gzip header is the same ten bytes (no mtime, OS
"unknown"), where zlib writes a per-platform OS byte. CI checks this on Linux,
macOS and Windows against committed golden archives.

`--fast` compresses with the VM's zlib instead: about 2.7x faster at that
step (0.66 s against 1.8 s for a 48 MB tar), still reproducible on one
machine, and still fine for `--check` — but no longer byte-identical across
platforms.

### Regenerating a project

`--stamp` leaves a `.mold.json` in the target: the template, its version, the
variable values and every file written. A target that already has one gets it
updated on every later `--force`, whether or not `--stamp` is repeated.

```sh
mold unpack app.mold -t ./my_app --var name=my_app --stamp
# …later, with a newer template:
mold unpack app.mold -t ./my_app --force --vars-file ./my_app/.mold.json --dry-run
```

`--vars-file` takes the stamp's values, so a regeneration does not depend on
remembering what was typed the first time; `--var` still overrides any of
them. A variable the template has dropped since is `VARIABLE_DROPPED` ⚠ — its
value is not used — rather than an error that would make the stamp useless
after the first change to the template's variables. The stamp also records a SHA-256 of
every file it wrote, which tells a regeneration two things:

- which files it is about to overwrite hold content it did not write — edited
  since, or never written by it at all (the project's own file, at a path the
  template has added since) — `UNPACK_OVERWRITES_EDITS`, listed in a dry run,
  so `--force` no longer discards work without a word;
- which files the template has since **dropped** — listed under "No longer in
  the template", reported as `UNPACK_STALE_FILES`, and left in place: never
  deleted, since they may have been edited. They stay in the stamp while they
  exist, so every regeneration reports them, not just the first.

A regeneration rewrites only files that change: one identical to what is
there is compared, not written, so mtimes — and build caches and file
watchers — are left alone. A stamp at a project's root is never packed into a
template: it describes one unpack into one directory, and would hand every
later unpack its author's values and history. Only a stamp — a `.mold.json`
that is some other tool's file is packed like any other.

A stamp belongs to one template. Unpacking another into the same directory
with `--force` — an add-on template into a project made from a first one —
reports `UNPACK_STAMP_FOREIGN` ⚠ and leaves the first one's stamp as it is:
it is not used to tell stale or edited files, which would call every file of
the first template stale, and not rewritten for the second. With `--stamp` it
is an error, since one `.mold.json` cannot describe both.

On macOS and Windows, a path whose casing changed between unpacks
(`MyApp.swift` → `Myapp.swift`, after a value's casing changed) is the same
file, and treated as one: neither stale nor the project's own.

`--vars-file` also takes a plain YAML or JSON map of values. `--var` applies
over it; a key the template does not declare is `VARIABLE_UNKNOWN`, as for
`--var` — a map is typed by hand, so an unknown key there is more likely a
typo than a dropped variable.

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
    pattern: null           # regex the whole value must match
    choices: []             # the only values allowed; empty → any

extra_substitutions: []     # from/to, applied to CONTENT only
path_renames: []            # from/to, applied to PATHS only

# ─── copied verbatim ────────────────────────────────────────
no_substitute: []           # globs; content untouched, path still renamed
binary_extensions: []       # extra extensions treated as binary

# ─── after unpacking ────────────────────────────────────────
message: null               # shown once unpacked; a template like `to:`
```

Values are read as written: an unquoted `version: 1.10` is `1.10`, not the
number YAML would make of it (`1.1`), and `007` stays `007` — in the manifest
and in `--vars-file` alike.

A key the format does not define is ignored, but never silently: it warns as
`MANIFEST_UNKNOWN_KEY`, with the key it probably means — `excludes` → did you
mean `exclude`? — at the top level, inside a variable, and inside a
substitution entry.

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

The value given for a `replaces` variable must be something the casings can be
derived from: ASCII letters, digits, spaces, `_` and `-`, starting with a
letter or digit and holding at least one letter — `3d-viewer` is fine; `123`,
`-app` and `my/app` are `VARIABLE_INVALID_FORMAT`.
Anything a particular language forbids on top of that, such as a leading digit
in a Dart package name, belongs in the variable's `pattern`.

A variable **without** `replaces` contributes no renames; it exists to be
interpolated. One that is neither used as a token nor referenced by any
substitution warns as `MANIFEST_UNUSED_VARIABLE`.

A variable can constrain its value: `pattern` is a regular expression the
**whole** value must match (it is anchored for you), and `choices` lists the
only values allowed — the prompt shows them. An answer the variable refuses
— outside `choices`, not matching `pattern`, not a name its casings can be
derived from — is explained and asked again, up to three times, rather than
failing the unpack after every other prompt.

```yaml
variables:
  org:
    pattern: '[a-z]+(\.[a-z]+)+'
    default: com.example
  platform:
    choices: [android, ios]
    default: android
```

A value outside them is `VARIABLE_PATTERN_MISMATCH` or `VARIABLE_NOT_A_CHOICE`;
a pattern that does not compile, or a default its own constraints reject, is
caught at pack.

Two variables whose tokens derive the same casing (`my_app` and `my-app`
share `MyApp`) warn as `MANIFEST_CONFLICTING_TOKENS`: those sites take the
later variable's value.

Resolution precedence: explicit `--var` › `--vars-file` › manifest `default` ›
interactive prompt. End of input is not an answer — with stdin closed, a
variable with no default stays unresolved and is reported as
`VARIABLE_MISSING`, rather than silently becoming an empty string; input that
ends after a refused answer keeps that answer, to fail on it, rather than
falling back to the default.

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

### Message

What to tell the person once the project exists — the next steps, usually:

```yaml
message: |
  Next:
    cd {{ project_name }}
    dart pub get
    dart run bin/{{ project_name | snakeCase }}.dart
```

`mold unpack` prints it, rendered, after `Unpacked into …` — not on a dry
run. It is a template like a substitution's `to:` and is validated like one;
a variable it names counts as used. `--json` carries it as `message`, and
`UnpackPlan.message` holds it rendered.

---

## Interpolation and transforms

Only the `to:` side of a substitution or path rename is a template, and the
[`message`](#message).

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
| `flatCase`      | `my_project` | `myproject`  |
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
and `path_renames`, not a blunter rename. The check matches exactly as
unpacking will — one pattern over every casing and every explicit
substitution, longest first — so a site an `extra_substitutions` entry claims
is not counted against the token: pinning `MyApplication` to itself removes it
from the collateral.

The four casings are not every way a name gets written, and the check says
so. A token's words matched case-insensitively, joined by one of ` ._-` or by
nothing, that land on no derived casing are reported as
`PROJECT_UNCOVERED_CASING` — with the entries that would rename them,
wherever a transform reproduces the spelling exactly: under
`extra_substitutions` for a spelling in content, under `path_renames` for one
in a path. On a fresh
`flutter create` project named `app_template`:

```text
[PROJECT_UNCOVERED_CASING] Variable 'name': 'appTemplate' (10:
ios/Runner.xcodeproj/project.pbxproj, macos/Runner.xcodeproj/project.pbxproj,
macos/Runner/Configs/AppInfo.xcconfig), 'App Template' (1: ios/Runner/Info.plist)
spell token 'app_template' in a way no derived casing matches, so unpacking
leaves them as they are. To rename them too, add to extra_substitutions:
  - from: "appTemplate"
    to: "{{ name | camelCase }}"
  - from: "App Template"
    to: "{{ name | titleCase }}"
```

That is the iOS and macOS bundle identifier and the display name: without it,
the scaffolded app ships under the template's identity.

The same pass reports other things worth knowing at pack:

- a token that occurs in files copied verbatim (binary extensions,
  `no_substitute`, non-UTF-8) — `PROJECT_TOKEN_IN_VERBATIM`; their paths are
  renamed, their content keeps the token;
- an `extra_substitutions` or `path_renames` entry that never fires —
  `PROJECT_SUBSTITUTION_UNUSED`, `PROJECT_PATH_RENAME_UNUSED`; usually a typo;
- a file that looks like a secret — `PROJECT_SECRET_SUSPECTED`: by name
  (`.env`, `key.properties`, `google-services.json`, `*.pem`, `*.jks`, SSH
  keys, …; `.env.example` and friends excepted) or by content (a PEM private
  key, an AWS access key id, a Google API key, a GitHub token). A template is
  made to be shared;
- a path that cannot exist everywhere — `PROJECT_PATH_NOT_PORTABLE`: two that
  differ only in case (one file on macOS and Windows), or a name Windows
  refuses (`aux.txt`, `a:b`, a trailing dot). A warning, since the template
  unpacks fine elsewhere; unpacking it on Windows is `RENAME_INVALID_NAME`,
  before anything is written.

At unpack, a variable's **value** is checked against the template:
`VARIABLE_VALUE_PRESENT` when a casing of it already occurs there as a word.
Unpacking `super_server` as `my_app` into a template with a `MyApp` class
leaves two classes called `MyApp`, and nothing else would notice.

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

The files are read and checked as a pack would, then handed to the same
planner `unpack --diff` uses, so the two cannot disagree — and an unpack's
warnings, such as a value already in the template, show up in the preview
too. Nothing is compressed. Values come from `--var`, `--vars-file` and
manifest defaults only — `pack` never prompts, so it stays usable from CI.

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
| pack   | `MANIFEST_UNKNOWN_TRANSFORM`        | not one of the transforms listed above         |
| pack   | `MANIFEST_UNUSED_VARIABLE` ⚠        | variable does nothing                          |
| pack   | `MANIFEST_DUPLICATE_SUBSTITUTION`   | two entries in one section share a `from`      |
| pack   | `MANIFEST_CONFLICTING_TOKENS` ⚠     | two variables derive the same casing           |
| pack   | `MANIFEST_INVALID_PATTERN`          | a variable's `pattern` does not compile        |
| pack   | `MANIFEST_INVALID_DEFAULT`          | a default its own constraints reject           |
| pack   | `MANIFEST_UNKNOWN_KEY` ⚠            | a key the format does not define               |
| both   | `MANIFEST_INVALID`                  | not UTF-8 YAML, or not shaped like a manifest  |
| both   | `MANIFEST_NOT_FOUND`                | no manifest file at the path                   |
| pack   | `PROJECT_DIR_NOT_FOUND`             | source directory missing                       |
| pack   | `PROJECT_DIR_EMPTY`                 | nothing to pack after filtering                |
| pack   | `PROJECT_REPLACES_NOT_FOUND`        | token occurs in no captured file               |
| pack   | `PROJECT_TOKEN_TOO_GENERIC`         | ≥30% of matches are collateral                 |
| pack   | `PROJECT_PARTIAL_OVERLAP` ⚠         | ≥5% of matches are collateral                  |
| pack   | `PROJECT_SYMLINK_SKIPPED` ⚠         | a symlink was left out, with the reason        |
| pack   | `PROJECT_TOKEN_IN_VERBATIM` ⚠       | a token in files copied verbatim               |
| pack   | `PROJECT_SUBSTITUTION_UNUSED` ⚠     | an `extra_substitutions` entry never fires     |
| pack   | `PROJECT_PATH_RENAME_UNUSED` ⚠      | a `path_renames` entry never fires             |
| pack   | `PROJECT_UNCOVERED_CASING` ⚠        | a spelling of a token no casing matches        |
| pack   | `PROJECT_SECRET_SUSPECTED` ⚠        | a file that looks like a secret                |
| pack   | `PROJECT_PATH_NOT_PORTABLE` ⚠       | a path not every platform can create           |
| unpack | `ARCHIVE_NOT_FOUND`                 | no archive file at the path                    |
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
| unpack | `VARIABLE_PATTERN_MISMATCH`         | value does not match the variable's `pattern`  |
| unpack | `VARIABLE_NOT_A_CHOICE`             | value is not one of the variable's `choices`   |
| unpack | `VARIABLE_VALUE_PRESENT` ⚠          | the value already occurs in the template       |
| unpack | `VARIABLE_DROPPED` ⚠                | a stamped value names a variable now gone      |
| unpack | `RENAME_COLLISION`                  | two entries on one path, or a file under one   |
| unpack | `TARGET_PATH_CONFLICT`              | `--force`: a path is blocked in the target     |
| unpack | `RENAME_UNSAFE_PATH`                | a renamed path escapes the target              |
| unpack | `RENAME_CASE_COLLISION` ⚠           | renamed paths differ only in case              |
| unpack | `RENAME_INVALID_NAME`               | on Windows: a path Windows cannot create       |
| unpack | `UNPACK_STALE_FILES` ⚠              | files the template dropped, left in place      |
| unpack | `UNPACK_STAMP_INVALID` ⚠            | the target's `.mold.json` is not a stamp       |
| unpack | `UNPACK_STAMP_FOREIGN` ⚠            | the target's stamp is another template's       |
| unpack | `UNPACK_OVERWRITES_EDITS` ⚠         | overwriting files edited since the stamp       |
| unpack | `UNPACK_CHMOD_FAILED` ⚠             | files written, but not made executable         |
| unpack | `UNPACK_UNDO_INCOMPLETE` ⚠          | a failed write could not be fully undone       |

⚠ = warning; does not block. Every code is a constant on `MoldCode`.

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
  onWarning: (warning) => print('Warning: $warning'),
);
await File('super_server.mold').writeAsBytes(archive);

// Unpack from bytes (e.g. an embedded template)…
await const Unbundler().unbundle(
  bytes: archive,
  targetDir: './my_project',
  vars: {'project_name': 'my_project'},
);

// …or from a file.
await const Unbundler().unbundleFile(
  source: 'super_server.mold',
  targetDir: './my_project',
  vars: {'project_name': 'my_project'},
);
```

`onWarning` receives each non-fatal problem as a `ValidationError` — a skipped
symlink, a token that will over-reach, a failed `chmod` — with its `code`, so
a caller can filter or escalate by code rather than by message.

Both `unbundle` options of the CLI are parameters: `overwrite: true` is
`--force`, `stamp: true` is `--stamp`.

### Errors

Every problem with the inputs — the manifest, the project, the archive, the
variables, the target — throws a `ValidationException`; its `errors` carry
stable codes, all listed as constants on `MoldCode`. A failing filesystem
throws an `IOException`. Nothing else is expected: a `StateError` is a bug.

```dart
try {
  await const Unbundler().unbundle(bytes: archive, targetDir: dir);
} on ValidationException catch (e) {
  if (e.codes.contains(MoldCode.targetOccupied)) {
    // ask, then retry with overwrite: true
  }
}
```

The async methods report through their `Future`: nothing is thrown before it
is returned.

### Plan, show, apply

An unpack is two steps, and both are public. `plan` decides everything —
validation, variables, where each file lands and the exact bytes it gets —
and `apply` writes a plan. `unbundle` is the two in a row, so a preview and
the write are the same computation, and a caller that shows a preview and
asks first applies the plan it showed instead of computing it again:

```dart
const unbundler = Unbundler();
final plan = unbundler.plan(
  bytes: archive,
  targetDir: './my_project',
  vars: {'project_name': 'my_project'},
  overwrite: true,
);

for (final file in plan.overwritten.where((f) => !f.identicalToExisting)) {
  print(const UnifiedDiff().render(
    before: file.existing ?? '',
    after: file.after ?? '',
    fromLabel: '${file.to} (current)',
    toLabel: file.to,
  ));
}
if (confirmed) {
  await unbundler.apply(plan); // validates the target again first
}
```

Each `PlannedFile` carries `from`, `to`, `verbatim`, `replacements`, the
`bytes` it will be written with, `executable`, and — with `withContent` (the
default for `plan`) — the text `before` and `after` substitution. With
`overwrite: true` it also says whether it `overwrites` a file already in the
target, whether that file is `identicalToExisting`, and its `existing` text.
`plan.created`, `plan.overwritten` and `plan.stale` split the files; a plan
also carries the `manifest` and the resolved `values`. A plan made with no
`targetDir` previews substitution only and cannot be applied.

To regenerate a project from its stamp, pass the stamp's values as
`recorded`. They come after `vars` and before the resolver, and one naming a
variable the template has dropped is a `VARIABLE_DROPPED` warning, not the
`VARIABLE_UNKNOWN` error it would be in `vars`:

```dart
final stamp = UnpackStamp.tryParse(
  File('./my_project/${UnpackStamp.fileName}').readAsStringSync(),
);
final plan = unbundler.plan(
  bytes: archive,
  targetDir: './my_project',
  recorded: stamp?.vars ?? const {},
  overwrite: true,
);
```

`inspect` describes an archive without unpacking it — its `manifest` (and
`manifestYaml`, as written), each file's size, which are executable.

### Prompting

```dart
final resolver = VariableResolver(
  noPrompt: false, // true → defaults only, never prompt
  prompter: VariablePrompter(stdout, stdin.readLineSync),
);

await const Unbundler().unbundle(
  bytes: archive,
  targetDir: './my_project',
  resolver: resolver,
);
```

A variable left without a value is `VARIABLE_MISSING`.

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

await const Unbundler().unbundle(
  bytes: kSuperServerTemplate,
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
disk, and `pack` never mutates the source. Unpacking keeps each file as a view
into the decompressed archive, and copies only the files substitution changes.
On a 48 MB, 1731-file corpus: pack ~2.2 s (half of it the portable deflate;
`--fast` or `--level` trade it), unpack ~0.4 s, peak memory ~300–360 MB.

## Out of scope

- **Templating the packed files.** Project content is never evaluated — no
  conditionals, loops, partials or includes, and a `{{ }}` inside a packed file
  is just text. `{{ }}` is interpreted only in the manifest: a `to:` value
  and the `message`.
- **Content-based binary detection** — extensions only, no MIME sniffing. The
  UTF-8 fallback is a decode failure, not classification.
- **File modes beyond the executable bit** — no ownership, no full mode round
  trip.
- **Preserving symlinks as symlinks** — they are dereferenced, so an unpack
  needs no symlink privileges (Windows requires them).
- **Empty directories** — not represented in the archive.
- **Compression other than gzip**, encryption, or signing.
- **Remote template registries** or fetching over the network.
- **Merging template updates into an edited project.** `--force` regenerates
  over it and the stamp says what the template dropped, but a file the
  template has is replaced, not merged: edits in it are overwritten.
