/// Canonical validation helpers for catalog and persisted profile wire data.
library;

final RegExp _immutableRevision = RegExp(
  r'^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64}|sha256:[0-9a-fA-F]{64})$',
);

final RegExp _catalogSha256 = RegExp(r'^[0-9a-f]{64}$');

/// A full source commit/content digest, never a branch or tag.
bool isImmutablePowertrainRevision(String value) =>
    _immutableRevision.hasMatch(value.trim());

/// The lowercase SHA-256 from the bundled catalog manifest.
bool isPowertrainCatalogSha256(String value) =>
    _catalogSha256.hasMatch(value.trim());

/// Exact 11-bit or 29-bit CAN identifier in the catalog's canonical spelling.
bool isExactPowertrainCanId(String value) {
  final text = value.trim().toUpperCase();
  if (RegExp(r'^[0-7][0-9A-F]{2}$').hasMatch(text)) return true;
  if (!RegExp(r'^[0-9A-F]{8}$').hasMatch(text)) return false;
  final parsed = int.tryParse(text, radix: 16);
  return parsed != null && parsed <= 0x1FFFFFFF;
}
