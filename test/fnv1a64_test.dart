import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/hash/fnv1a64.dart';

void main() {
  test('FNV-1a 64 preserves canonical vectors', () {
    expect(Fnv1a64().hex, 'cbf29ce484222325');
    expect((Fnv1a64()..add(utf8.encode('hello'))).hex, 'a430d84680aabd0b');
  });

  test('FNV-1a 64 is invariant across arbitrary stream chunks', () {
    final bytes = <int>[
      for (var index = 0; index < 4096; index++)
        (index * 31 + index ~/ 7) & 0xff,
    ];
    final whole = Fnv1a64()..add(bytes);
    final chunked = Fnv1a64();
    var offset = 0;
    for (final size in [1, 63, 64, 65, 511, 1024, 2048, 384]) {
      final end = (offset + size).clamp(0, bytes.length);
      chunked.add(bytes.sublist(offset, end));
      offset = end;
    }

    expect(offset, bytes.length);
    expect(chunked.hex, _bigIntFnv(bytes));
    expect(chunked.fingerprint, whole.fingerprint);
  });
}

String _bigIntFnv(List<int> bytes) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = BigInt.parse('ffffffffffffffff', radix: 16);
  for (final byte in bytes) {
    hash ^= BigInt.from(byte);
    hash = (hash * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
