# Changelog

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
- Archive entries that would escape the target directory are rejected.
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
