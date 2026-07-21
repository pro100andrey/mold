# mold example

Pack a real project into a template archive, then unpack it under a new name
with the old name rewritten in every casing.

## The manifest

The rules live in [`mold.yaml`](mold.yaml), beside the project rather than as
placeholders inside it:

```yaml
name: super_server
version: 1.0.0

variables:
  project_name:
    description: The new project name
    default: my_project
    replaces: super_server        # rewrites snake, kebab, SCREAMING, Pascal

extra_substitutions:
  - from: Super Server
    to: "{{ project_name | titleCase }}"   # a form the four casings can't reach
```

## Run it

[`mold_example.dart`](mold_example.dart) reads that manifest, packs a throwaway
`super_server` project, and unpacks it as `acme_shop`:

```console
$ dart run example/mold_example.dart
Packed 604 bytes.
Unpacked into /tmp/mold_example_XXXX/acme_shop:
  name: acme_shop
  const banner = 'Welcome to Acme Shop';
```

`super_server` → `acme_shop` in the path and the pubspec, and `Super Server` →
`Acme Shop` in the banner — the one string a casing rule cannot produce, filled
by the `titleCase` transform.

## The same thing from the shell

The library API above mirrors the CLI one-to-one:

```sh
mold pack ./super_server -m mold.yaml -o super_server.mold
mold unpack super_server.mold -t ./acme_shop --var project_name=acme_shop
```

Add `--diff` to either command to preview every rename before it happens. See
the [package README](../README.md) for the full manifest reference.
