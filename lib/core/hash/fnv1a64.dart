library;

/// Incremental FNV-1a 64-bit hash with native integer work per byte.
///
/// Dart's native runtime keeps the masked value as a signed 64-bit integer.
/// Conversion to [BigInt] is intentionally deferred until rendering so large
/// streams do not allocate a `BigInt` for every byte.
final class Fnv1a64 {
  int _hash = 0xcbf29ce484222325;

  void add(List<int> bytes) {
    for (final byte in bytes) {
      _hash ^= byte;
      _hash = (_hash * 0x100000001b3) & 0xffffffffffffffff;
    }
  }

  String get hex {
    final unsigned = _hash < 0
        ? BigInt.from(_hash) + (BigInt.one << 64)
        : BigInt.from(_hash);
    return unsigned.toRadixString(16).padLeft(16, '0');
  }

  String get fingerprint => 'fnv1a64:$hex';
}
