/// `mold` — pack a project into a portable template archive and unpack it
/// with manifest-driven renaming.
///
/// The operations are *pack* and *unpack*, as the CLI names them. The classes
/// performing them are `Bundler` and `Unbundler`; what they produce keeps the
/// operation's name — an `UnpackPlan`, an `UnpackStamp`, `UNPACK_…` codes.
///
/// `Bundler` packs a project into archive bytes; `Unbundler` plans an unpack
/// (`UnpackPlan`) and applies it, or describes an archive without unpacking
/// it (`Unbundler.inspect`, a `TemplateInfo`). `EmbedSource` renders an
/// archive as a Dart source to ship inside a binary, and `UnifiedDiff`
/// renders a planned file's change.
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
export 'src/unbundler/unbundler.dart' show TemplateInfo, Unbundler;
export 'src/unbundler/unpack_plan.dart' show PlannedFile, UnpackPlan;
export 'src/unbundler/unpack_stamp.dart' show UnpackStamp;
export 'src/validation/codes.dart' show MoldCode;
export 'src/validation/validation_error.dart'
    show Severity, ValidationError, WarningSink;
export 'src/validation/validation_result.dart' show ValidationException;
