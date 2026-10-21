/// `mold` — pack a project into a portable template archive and unpack it
/// with manifest-driven renaming.
///
/// `Bundler` packs a project into archive bytes; `Unbundler` plans an unpack
/// (`UnpackPlan`) and applies it. `EmbedSource` renders an archive as a Dart
/// source to ship inside a binary, and `UnifiedDiff` renders a planned file's
/// change.
///
/// Problems with the inputs throw a `ValidationException`; its errors carry
/// the codes listed in `MoldCode`. Warnings reach an `onWarning` callback as
/// `ValidationError`s with the same codes. A failing filesystem throws an
/// `IOException`.
library;

export 'src/bundler/bundler.dart' show Bundler;
export 'src/manifest/manifest.dart'
    show Manifest, Substitution, TemplateVariable;
export 'src/output/embed_source.dart' show EmbedSource;
export 'src/output/unified_diff.dart' show UnifiedDiff;
export 'src/prompt/variable_prompter.dart' show LineReader, VariablePrompter;
export 'src/prompt/variable_resolver.dart' show VariableResolver;
export 'src/unbundler/unbundler.dart' show Unbundler;
export 'src/unbundler/unpack_plan.dart' show PlannedFile, UnpackPlan;
export 'src/validation/codes.dart' show MoldCode;
export 'src/validation/validation_error.dart'
    show Severity, ValidationError, WarningSink;
export 'src/validation/validation_result.dart' show ValidationException;
