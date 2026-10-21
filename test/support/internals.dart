/// Everything the tests reach for, including what `package:mold` keeps
/// private: most tests exercise one validator or helper directly.
library;

export 'package:mold/src/archive/archive_codec.dart'
    show
        ArchiveTooLargeException,
        decodeGzipBounded,
        defaultMaxDecompressedBytes;
export 'package:mold/src/archive/archive_path.dart' show isContainedArchivePath;
export 'package:mold/src/archive/archive_reader.dart'
    show ArchiveReader, BundleArchive;
export 'package:mold/src/archive/archive_validator.dart' show ArchiveValidator;
export 'package:mold/src/archive/archive_writer.dart' show ArchiveWriter;
export 'package:mold/src/bundler/bundler.dart' show Bundler;
export 'package:mold/src/bundler/file_classifier.dart'
    show FileClassifier, FileKind;
export 'package:mold/src/bundler/file_scanner.dart'
    show FileScanner, ScanResult, SkipReason;
export 'package:mold/src/bundler/gitignore.dart' show GitignoreRules;
export 'package:mold/src/bundler/project_validator.dart'
    show ProjectInput, ProjectValidator;
export 'package:mold/src/cli/cli.dart'
    show CliException, buildRunner, runBundleCli;
export 'package:mold/src/manifest/content_policy.dart' show ContentPolicy;
export 'package:mold/src/manifest/manifest.dart'
    show Manifest, Substitution, TemplateVariable;
export 'package:mold/src/manifest/manifest_validator.dart'
    show ManifestValidator;
export 'package:mold/src/manifest/substitution_template.dart'
    show
        LiteralSegment,
        PlaceholderSegment,
        SubstitutionTemplate,
        TemplateError,
        TemplateErrorKind,
        TemplateSegment;
export 'package:mold/src/output/embed_source.dart' show EmbedSource;
export 'package:mold/src/output/output_format.dart' show OutputFormat;
export 'package:mold/src/output/unified_diff.dart' show UnifiedDiff;
export 'package:mold/src/prompt/variable_prompter.dart'
    show LineReader, VariablePrompter;
export 'package:mold/src/prompt/variable_resolver.dart' show VariableResolver;
export 'package:mold/src/unbundler/case_converter.dart' show CaseConverter;
export 'package:mold/src/unbundler/case_transform.dart' show CaseTransform;
export 'package:mold/src/unbundler/rename_validator.dart' show RenameValidator;
export 'package:mold/src/unbundler/substitutor.dart' show Substitutor;
export 'package:mold/src/unbundler/target_validator.dart' show TargetValidator;
export 'package:mold/src/unbundler/unbundler.dart' show TemplateInfo, Unbundler;
export 'package:mold/src/unbundler/unpack_plan.dart'
    show PlannedFile, UnpackPlan;
export 'package:mold/src/unbundler/unpack_stamp.dart' show UnpackStamp;
export 'package:mold/src/unbundler/variables_validator.dart'
    show VariablesInput, VariablesValidator;
export 'package:mold/src/validation/codes.dart' show MoldCode;
export 'package:mold/src/validation/validation_error.dart'
    show Severity, ValidationError;
export 'package:mold/src/validation/validation_error.dart' show WarningSink;
export 'package:mold/src/validation/validation_result.dart'
    show ValidationException, ValidationResult;
export 'package:mold/src/validation/validator_base.dart' show ValidatorBase;
