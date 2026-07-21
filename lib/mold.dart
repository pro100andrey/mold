/// `mold` — pack a project into a portable template archive and unpack it
/// with manifest-driven renaming.
library;

export 'src/archive/archive_path.dart' show isContainedArchivePath;
export 'src/archive/archive_reader.dart' show ArchiveReader, BundleArchive;
export 'src/archive/archive_validator.dart' show ArchiveValidator;
export 'src/archive/archive_writer.dart' show ArchiveWriter;
export 'src/bundler/bundler.dart' show Bundler, BundlerBase;
export 'src/bundler/file_classifier.dart' show FileClassifier, FileKind;
export 'src/bundler/file_scanner.dart' show FileScanner, ScanResult, SkipReason;
export 'src/bundler/project_validator.dart' show ProjectInput, ProjectValidator;
export 'src/cli/cli.dart'
    show CliException, PackCommand, UnpackCommand, buildRunner, runBundleCli;
export 'src/manifest/manifest.dart'
    show Manifest, Substitution, TemplateVariable;
export 'src/manifest/manifest_validator.dart' show ManifestValidator;
export 'src/manifest/substitution_template.dart'
    show
        LiteralSegment,
        PlaceholderSegment,
        SubstitutionTemplate,
        TemplateError,
        TemplateErrorKind,
        TemplateSegment;
export 'src/output/embed_source.dart' show EmbedSource;
export 'src/output/output_format.dart' show OutputFormat;
export 'src/prompt/variable_prompter.dart' show LineReader, VariablePrompter;
export 'src/prompt/variable_resolver.dart' show VariableResolver;
export 'src/unbundler/case_converter.dart' show CaseConverter;
export 'src/unbundler/case_transform.dart' show CaseTransform;
export 'src/unbundler/substitutor.dart' show Substitutor;
export 'src/unbundler/target_validator.dart' show TargetValidator;
export 'src/unbundler/unbundler.dart' show Unbundler, UnbundlerBase;
export 'src/unbundler/unpack_plan.dart' show PlannedFile, UnpackPlan;
export 'src/unbundler/variables_validator.dart'
    show VariablesInput, VariablesValidator;
export 'src/validation/validation_error.dart' show Severity, ValidationError;
export 'src/validation/validation_result.dart'
    show ValidationException, ValidationResult;
export 'src/validation/validator_base.dart' show ValidatorBase;
