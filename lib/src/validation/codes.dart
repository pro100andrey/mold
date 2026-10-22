import '../archive/archive_validator.dart';
import '../bundler/project_validator.dart';
import '../manifest/manifest_validator.dart';
import '../unbundler/rename_validator.dart';
import '../unbundler/target_validator.dart';
import '../unbundler/unbundler.dart';
import '../unbundler/variables_validator.dart';
import 'validation_error.dart';

/// Every code a [ValidationError] can carry, in one place.
///
/// Codes are stable: wording may change, codes do not. Branch on these, never
/// on a message. Each is defined beside the check that raises it; this class
/// is the index, so a caller does not need the validators themselves.
///
/// Grouped by phase, in the order the phases run. ⚠ marks a warning — it is
/// reported and never blocks.
abstract final class MoldCode {
  // ─── manifest (pack and unpack) ───────────────────────────────────────────

  /// Not YAML, or not shaped like a manifest.
  static const String manifestInvalid = ManifestValidator.invalid;

  /// `Manifest.fromFile` found no file.
  static const String manifestNotFound = ManifestValidator.notFound;

  /// `name` is absent.
  static const String manifestMissingName = ManifestValidator.missingName;

  /// `version` is absent.
  static const String manifestMissingVersion = ManifestValidator.missingVersion;

  /// Two variables share a name.
  static const String manifestDuplicateVariable =
      ManifestValidator.duplicateVariable;

  /// A pattern in include / exclude / no_substitute does not compile.
  static const String manifestInvalidGlob = ManifestValidator.invalidGlob;

  /// `replaces: ""`.
  static const String manifestEmptyReplaces = ManifestValidator.emptyReplaces;

  /// A `replaces` token with no ASCII word characters.
  static const String manifestUnsupportedReplaces =
      ManifestValidator.unsupportedReplaces;

  /// Bad syntax inside `{{ }}`.
  static const String manifestMalformedPlaceholder =
      ManifestValidator.malformedPlaceholder;

  /// `{{` with no `}}`.
  static const String manifestUnterminatedPlaceholder =
      ManifestValidator.unterminatedPlaceholder;

  /// A placeholder names an undeclared variable.
  static const String manifestUnknownVariable =
      ManifestValidator.unknownVariable;

  /// A placeholder names a transform that does not exist.
  static const String manifestUnknownTransform =
      ManifestValidator.unknownTransform;

  /// ⚠ A variable that does nothing.
  static const String manifestUnusedVariable = ManifestValidator.unusedVariable;

  /// Two entries in one section share a `from`.
  static const String manifestDuplicateSubstitution =
      ManifestValidator.duplicateSubstitution;

  /// ⚠ Two variables' tokens derive a casing in common.
  static const String manifestConflictingTokens =
      ManifestValidator.conflictingTokens;

  /// A variable's `pattern` is not a valid regular expression.
  static const String manifestInvalidPattern = ManifestValidator.invalidPattern;

  /// A variable's `default` fails its own `pattern` or `choices`.
  static const String manifestInvalidDefault = ManifestValidator.invalidDefault;

  /// ⚠ A key the manifest format does not define — usually a misspelling.
  static const String manifestUnknownKey = ManifestValidator.unknownKey;

  // ─── project (pack) ───────────────────────────────────────────────────────

  /// The source directory is missing.
  static const String projectDirNotFound = ProjectValidator.dirNotFound;

  /// Nothing to pack after filtering.
  static const String projectDirEmpty = ProjectValidator.dirEmpty;

  /// A token occurs in no captured file.
  static const String projectReplacesNotFound =
      ProjectValidator.replacesNotFound;

  /// At least 30% of a token's matches are inside longer words.
  static const String projectTokenTooGeneric = ProjectValidator.tokenTooGeneric;

  /// ⚠ At least 5% of a token's matches are inside longer words.
  static const String projectPartialOverlap = ProjectValidator.partialOverlap;

  /// ⚠ A symlink was left out, with the reason.
  static const String projectSymlinkSkipped = ProjectValidator.symlinkSkipped;

  /// ⚠ A token occurs in files copied verbatim, which keep it.
  static const String projectTokenInVerbatim = ProjectValidator.tokenInVerbatim;

  /// ⚠ An `extra_substitutions.from` occurs in no substituted file.
  static const String projectSubstitutionUnused =
      ProjectValidator.substitutionUnused;

  /// ⚠ A `path_renames.from` occurs in no packed path.
  static const String projectPathRenameUnused =
      ProjectValidator.pathRenameUnused;

  /// ⚠ A spelling of a token no derived casing matches (`appTemplate`).
  static const String projectUncoveredCasing = ProjectValidator.uncoveredCasing;

  /// ⚠ A file that looks like a secret, by name or content.
  static const String projectSecretSuspected = ProjectValidator.secretSuspected;

  /// ⚠ A path that cannot exist on every platform.
  static const String projectPathNotPortable = ProjectValidator.pathNotPortable;

  // ─── archive (unpack) ─────────────────────────────────────────────────────

  /// The archive file does not exist.
  static const String archiveNotFound = ArchiveValidator.notFound;

  /// Not a valid gzipped tar.
  static const String archiveInvalid = ArchiveValidator.invalid;

  /// Decompresses past the size ceiling.
  static const String archiveTooLarge = ArchiveValidator.tooLarge;

  /// No embedded `mold.yaml`.
  static const String archiveMissingManifest = ArchiveValidator.missingManifest;

  /// No `files/` tree.
  static const String archiveMissingFiles = ArchiveValidator.missingFiles;

  /// An entry escapes the target directory.
  static const String archiveUnsafePath = ArchiveValidator.unsafePath;

  // ─── target (unpack) ──────────────────────────────────────────────────────

  /// The target, or a directory on the way to it, is a file. Missing
  /// directories are not a problem: the unpack creates them.
  static const String targetNotDirectory = TargetValidator.notDirectory;

  /// The target is a non-empty directory, without overwrite.
  static const String targetOccupied = TargetValidator.occupied;

  /// No write permission.
  static const String targetNotWritable = TargetValidator.notWritable;

  /// With overwrite: a file would land on a directory, under a file, or
  /// through a symlink.
  static const String targetPathConflict = TargetValidator.pathConflict;

  // ─── variables (unpack) ───────────────────────────────────────────────────

  /// A required variable has no value.
  static const String variableMissing = VariablesValidator.missing;

  /// A `replaces` value is not a well-formed name token.
  static const String variableInvalidFormat = VariablesValidator.invalidFormat;

  /// A value names a variable the template does not declare.
  static const String variableUnknown = VariablesValidator.unknown;

  /// A value does not match the variable's `pattern`.
  static const String variablePatternMismatch =
      VariablesValidator.patternMismatch;

  /// A value is not one of the variable's `choices`.
  static const String variableNotAChoice = VariablesValidator.notAChoice;

  /// ⚠ A variable's value already occurs in the template.
  static const String variableValuePresent = VariablesValidator.valuePresent;

  /// ⚠ A recorded value (a stamp's) names a variable the template no longer
  /// declares; it is dropped.
  static const String variableDropped = VariablesValidator.dropped;

  // ─── rename (unpack) ──────────────────────────────────────────────────────

  /// Two entries would land on the same path.
  static const String renameCollision = RenameValidator.collision;

  /// A renamed path escapes the target directory.
  static const String renameUnsafePath = RenameValidator.unsafePath;

  /// ⚠ Two destinations differ only in case.
  static const String renameCaseCollision = RenameValidator.caseCollision;

  /// On Windows: a renamed path Windows cannot create — a reserved device
  /// name, `<>:"|?*` or a control character, a trailing dot or space.
  static const String renameInvalidName = RenameValidator.invalidName;

  // ─── write (unpack) ───────────────────────────────────────────────────────

  /// ⚠ `chmod` failed; files are written but not executable.
  static const String unpackChmodFailed = Unbundler.chmodFailed;

  /// ⚠ A failed write could not be fully undone.
  static const String unpackUndoIncomplete = Unbundler.undoIncomplete;

  /// ⚠ Files the previous unpack wrote are no longer in the template; they
  /// were left in place.
  static const String unpackStaleFiles = Unbundler.staleFiles;

  /// ⚠ The target's `.mold.json` is not a mold stamp.
  static const String unpackStampInvalid = Unbundler.stampInvalid;

  /// ⚠ An overwrite discards edits made since the stamped unpack.
  static const String unpackOverwritesEdits = Unbundler.overwritesEdits;

  /// ⚠ The target's stamp is another template's; it is left alone and not
  /// used. An error when a stamp is to be written.
  static const String unpackStampForeign = Unbundler.stampForeign;
}
