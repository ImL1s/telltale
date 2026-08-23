/// Escapes untrusted text before it becomes part of a line-oriented evidence
/// file.
///
/// Adapter names and native error strings can contain control characters or
/// Unicode direction controls. Rendering them verbatim would let one value
/// forge another transcript line or make the visible order differ from the
/// stored order. Printable text stays readable; ambiguous code points become
/// explicit ASCII escapes.
String escapeEvidenceText(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    switch (rune) {
      case 0x5C:
        out.write(r'\\');
      case 0x09:
        out.write(r'\t');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      default:
        if (_isByteControl(rune)) {
          out.write(
            '\\x${rune.toRadixString(16).toUpperCase().padLeft(2, '0')}',
          );
        } else if (_isInvisibleUnicodeControl(rune)) {
          out.write('\\u{${rune.toRadixString(16).toUpperCase()}}');
        } else {
          out.writeCharCode(rune);
        }
    }
  }
  return out.toString();
}

bool _isByteControl(int rune) =>
    rune < 0x20 || (rune >= 0x7F && rune <= 0x9F);

bool _isInvisibleUnicodeControl(int rune) =>
    rune == 0x00AD ||
    rune == 0x061C ||
    rune == 0x180E ||
    (rune >= 0x200B && rune <= 0x200F) ||
    (rune >= 0x2028 && rune <= 0x202E) ||
    (rune >= 0x2060 && rune <= 0x206F) ||
    rune == 0xFEFF;
