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

  /// The target's parent directory is missing.
  static const String targetParentNotFound = TargetValidator.parentNotFound;

  /// The target is a file, or not empty without overwrite.
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

  // ─── rename (unpack) ──────────────────────────────────────────────────────

  /// Two entries would land on the same path.
  static const String renameCollision = RenameValidator.collision;

  /// A renamed path escapes the target directory.
  static const String renameUnsafePath = RenameValidator.unsafePath;

  // ─── write (unpack) ───────────────────────────────────────────────────────

  /// ⚠ `chmod` failed; files are written but not executable.
  static const String unpackChmodFailed = Unbundler.chmodFailed;

  /// ⚠ A failed write could not be fully undone.
  static const String unpackUndoIncomplete = Unbundler.undoIncomplete;
}
