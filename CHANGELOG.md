# Changelog

## 0.1.4

- **`mold unpack --force`** unpacks into a directory that already holds files —
  for a tool that regenerates a project in place, which until now had to unpack
  into a scratch directory and copy the result over itself. Each file the
  template has is written over the file at the same path; every other file is
  left as it is. Without the flag nothing changes: a non-empty target is still
  `TARGET_OCCUPIED`, and a target that is a file is refused either way.

  In the library it is `overwrite: true` on `unbundle`, `unbundleBytes`,
  `unbundleFile` and `plan`, and on `TargetValidator`.

  - A template file that would land on a directory, under a file, or through a
    symlink is a new error, `TARGET_PATH_CONFLICT`, reported before anything is
    written. The symlink case keeps every write inside the target, the same
    guarantee the archive validator makes about entry paths.
  - `--force --dry-run` lists which files would be created and which
    overwritten, counting overwrites that change nothing rather than listing
    them. `--force --diff` diffs an overwritten file against the one already
    there. `PlannedFile` gains `overwrites`, `identicalToExisting` and
    `existing`; `UnpackPlan` gains `created` and `overwritten`.
  - A write that fails partway is undone: created files are removed,
    overwritten files get their previous content back, and directories the
    unpack created are removed once empty. Anything that cannot be undone is
    named through `onWarning`. Writes go straight into the target rather than
    through a scratch directory — moving a tree into an occupied directory is
    one rename per file, so staging would be no more atomic.
  - The writability probe uses a unique name, so in a non-empty target it
    cannot overwrite, then delete, a file of the user's that happens to share
    its name.

- **Generated embed sources pass the consumer's tooling.** `pack --format
  bytes|base64` output carries `// ignore_for_file: type=lint`, the standard
  header of generated code. Lint sets disagree about its declarations —
  `omit_obvious_property_types` flags the explicit type, `always_specify_types`
  demands it — so the file had to be excluded from analysis. Errors are still
  reported.

  It is also `dart format`-stable now, in both the tall and the pre-3.7 style.
  It was not: the byte rows ran to 81 columns and ended in a trailing space,
  and the formatter exploded the list to one byte per line. Rows are 15 bytes
  and open with a comment, which both styles keep as written. Regenerating an
  embedded template therefore changes the file once.

- **No false `PROJECT_PARTIAL_OVERLAP` on separator-joined names.** A match
  counted as "inside a longer word" when any `\w` touched it, and `_` is one,
  so for `replaces: app_template` the project's own `app_template_test` and
  `app_template_g` counted as over-reach — warning on every pack, or past 30%
  refusing it — although rewriting them to `my_app_test` is the point. What
  continues a word now depends on the casing that matched: for snake, kebab and
  SCREAMING a letter or digit, for Pascal a following lowercase letter. So
  `AppTemplateTest` and `MyAppTemplate` are whole words too, while `my_app` in
  `my_appendix`, `app` in `application` and `MyApp` in `MyApplication` are
  still caught. Thresholds and messages are unchanged.

  Ratios drop for most tokens. On a fresh `flutter create` project: `app` 83%
  → 65%, `test` 95% → 73%, `runner` 26% → under 5%, `bin` 75% unchanged.

- Requires Dart 3.13.5; dependencies bumped.

## 0.1.3

- **Archives are reproducible.** Every tar entry used to carry the wall-clock
  time of the pack, so packing one unchanged tree twice produced two different
  archives — different bytes, and different lengths, because a different set of
  timestamps compresses differently. Entry timestamps are now fixed at the
  epoch.

  It matters most where an archive is committed: `pack --format bytes|base64`
  writes the whole thing into a generated Dart source, and without this every
  regeneration was a whole-file diff over a template nobody had touched.

  A template's identity is its content, not the moment it was packed — the same
  reasoning that already keeps everything but the executable bit out of the
  recorded file mode.

- Archives packed by earlier versions are unaffected: entry timestamps were
  never read back. The reader discards them and unpacking writes files fresh.

## 0.1.2

- A seventh transform, `pathCase`: `com.acme` → `com/acme`. It derives the
  directory that holds a package — `android/app/src/main/kotlin/com/example/…`
  — from the organisation that names it, so the path and the package cannot be
  set inconsistently the way two separate variables could be.

  Unlike the other six it is not a case conversion but a `.` → `/` swap:
  segments keep the spelling they were given, so `com.acmeCorp` yields
  `com/acmeCorp`, not `com/acme/corp`. Empty segments are dropped, and a value
  with no dots is returned unchanged.

- **Breaking, technically.** `CaseTransform` is exported from `lib/mold.dart`,
  so a new enum value fails compilation for anyone switching over it
  exhaustively. Nothing else changed, and manifests are unaffected.

## 0.1.1

No API or behaviour changes — `lib/` is identical to 0.1.0.

- A runnable `example/`: a manifest beside the code, a script that packs a
  throwaway project and unpacks it under a new name, and a README that pub.dev
  renders on the Example tab.
- pub.dev topics: `scaffolding`, `template`, `cli`, `boilerplate`,
  `project-generator`.

## 0.1.0

First release.

Pack an existing project into a portable template archive and unpack it under a
new name. The template is a real, runnable project; renaming rules live in a
manifest beside it rather than as placeholders in the source.

### Renaming

- `replaces` derives four casings of a token — snake, kebab, SCREAMING and
  Pascal — and applies them to both paths and content.
- `extra_substitutions` reaches content only; `path_renames` reaches paths
  only. Together they cover what a single token cannot: a literal that needs
  opposite treatment in different places.
- The `to:` side of either is a template — `{{ variable }}` or
  `{{ variable | transform }}` — over six transforms: `snakeCase`,
  `kebabCase`, `camelCase`, `pascalCase`, `screamingCase`, `titleCase`.
  `{{{{` escapes a literal `{{`.

### File selection

- The project's own `.gitignore` files are honoured by default, including
  nested ones, with `!` negation, anchoring and last-match-wins ordering.
  `.git/` is never packed. Disable with `use_gitignore: false`.
- `include` / `exclude` globs apply on top; `no_substitute` and
  `binary_extensions` mark files copied byte-for-byte.
- Symlinks inside the project are dereferenced; ones pointing outside it, at a
  directory, or at nothing are skipped and reported.

### Safety

- A `replaces` token is measured, not just located: at or above 30% collateral
  matches packing is refused, at or above 5% it warns, naming the identifiers
  it would corrupt.
- Archive entries that would escape the target directory are rejected, and an
  archive that decompresses past a 512 MiB ceiling is refused before it can
  exhaust memory — templates are made to be unpacked by third parties, so the
  untrusted-input path is the normal one.
- A failed unpack cleans up after itself: files it wrote are removed, and a
  destination directory it created is removed, so the obvious retry is not
  blocked by half-written debris. A directory that already existed is left in
  place.
- Two entries that would land on the same path are rejected before anything is
  written. Substitution rewrites paths, so a `path_renames` pair or a token
  whose casings converge can point two files at one destination; the writer
  would have kept only the last, unpacking an archive into fewer files than it
  holds without saying so.
- A `--var` naming a variable the template does not declare is an error. It
  used to be dropped, leaving the variable on its default and scaffolding a
  wrong project with exit 0.
- Every phase is validated with structured, stable codes; warnings reach
  stderr at both pack and unpack, rather than only reaching whoever packed.

### Preview

- `mold unpack --dry-run` shows the plan, `--diff` adds a unified diff, and
  neither writes anything. Both run the same rules as a real unpack.
- `mold pack --dry-run` is a preflight: what would be captured, what each
  filter removed, and the token verdict.

### Preserved through a round trip

The owner-executable bit, a leading UTF-8 BOM, and the bytes of anything not
substituted — binaries, `no_substitute` matches, and files that are not valid
UTF-8.
