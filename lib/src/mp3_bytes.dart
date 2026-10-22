part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// Byte helpers
// ---------------------------------------------------------------------------

String _mp3Hex(Uint8List bytes, [int start = 0, int? end]) {
  final e = end == null || end > bytes.length ? bytes.length : end;
  final sb = StringBuffer();
  for (var i = start; i < e; i++) {
    if (i > start) sb.write(' ');
    sb.write(bytes[i].toRadixString(16).padLeft(2, '0').toUpperCase());
  }
  return sb.toString();
}

String _mp3HexPreview(Uint8List bytes, [int maxBytes = 32]) {
  if (bytes.length <= maxBytes) return _mp3Hex(bytes);
  return '${_mp3Hex(bytes, 0, maxBytes)} ... (${bytes.length} bytes)';
}

String _mp3HexOffset(int offset) =>
    '0x${offset.toRadixString(16).toUpperCase().padLeft(8, '0')}';

String _mp3HexByte(int value) =>
    '0x${value.toRadixString(16).toUpperCase().padLeft(2, '0')}';

String _mp3Bin(int value, int bits) => value.toRadixString(2).padLeft(bits, '0');

/// Printable ASCII, other bytes are shown as '.'.
String _mp3AsciiPreview(Uint8List bytes, [int maxBytes = 64]) {
  final n = bytes.length < maxBytes ? bytes.length : maxBytes;
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    final c = bytes[i];
    sb.writeCharCode(c >= 0x20 && c < 0x7F ? c : 0x2E);
  }
  if (bytes.length > maxBytes) sb.write('...');
  return sb.toString();
}

/// Big endian unsigned integer (length <= 6 to stay exact on the web).
int _mp3UInt(Uint8List b, int offset, int length) {
  var v = 0;
  for (var i = 0; i < length; i++) {
    v = v * 256 + b[offset + i];
  }
  return v;
}

/// Little endian unsigned integer.
int _mp3UIntLE(Uint8List b, int offset, int length) {
  var v = 0;
  for (var i = length - 1; i >= 0; i--) {
    v = v * 256 + b[offset + i];
  }
  return v;
}

int _mp3Int16(Uint8List b, int offset) {
  final v = _mp3UInt(b, offset, 2);
  return v >= 0x8000 ? v - 0x10000 : v;
}

/// Counter of arbitrary length (PCNT, POPM ...): int if it fits, else String.
Object _mp3Counter(Uint8List b, int start, int end) {
  if (end - start <= 6) return _mp3UInt(b, start, end - start);
  var v = BigInt.zero;
  for (var i = start; i < end; i++) {
    v = (v << 8) + BigInt.from(b[i]);
  }
  return v.toString();
}

/// Syncsafe integer: 7 bits per byte, bit 7 is always zero.
int _mp3Syncsafe(Uint8List b, int offset, int length) {
  var v = 0;
  for (var i = 0; i < length; i++) {
    v = v * 128 + (b[offset + i] & 0x7F);
  }
  return v;
}

bool _mp3IsSyncsafe(Uint8List b, int offset, int length) {
  for (var i = 0; i < length; i++) {
    if ((b[offset + i] & 0x80) != 0) return false;
  }
  return true;
}

bool _mp3StartsWith(Uint8List b, int offset, String ascii) {
  if (offset < 0 || offset + ascii.length > b.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (b[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

String _mp3Latin1(Uint8List b, int start, int end) =>
    String.fromCharCodes(b, start, end > b.length ? b.length : end);

/// Removes the ID3v2 unsynchronisation scheme ($FF $00 -> $FF).
Uint8List _mp3RemoveUnsync(Uint8List d) {
  final out = <int>[];
  for (var i = 0; i < d.length; i++) {
    out.add(d[i]);
    if (d[i] == 0xFF && i + 1 < d.length && d[i + 1] == 0x00) i++;
  }
  return Uint8List.fromList(out);
}

String _mp3FormatDuration(num milliseconds) {
  final total = milliseconds.round();
  final ms = total % 1000;
  final s = (total ~/ 1000) % 60;
  final m = (total ~/ 60000) % 60;
  final h = total ~/ 3600000;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  final mss = ms.toString().padLeft(3, '0');
  return h > 0 ? '$h:$mm:$ss.$mss' : '$mm:$ss.$mss';
}

// ---------------------------------------------------------------------------
// ID3v2 text encodings
// ---------------------------------------------------------------------------

const _mp3EncodingNames = <int, String>{
  0: 'ISO-8859-1',
  1: 'UTF-16 with BOM (ID3v2.2: UCS-2)',
  2: 'UTF-16BE without BOM',
  3: 'UTF-8',
};

bool _mp3IsWide(int enc) => enc == 1 || enc == 2;

/// Index of the string terminator ($00 or $00 00 for UTF-16) or -1.
int _mp3FindTerminator(Uint8List b, int start, int enc) {
  if (_mp3IsWide(enc)) {
    for (var i = start; i + 1 < b.length; i += 2) {
      if (b[i] == 0 && b[i + 1] == 0) return i;
    }
    return -1;
  }
  for (var i = start; i < b.length; i++) {
    if (b[i] == 0) return i;
  }
  return -1;
}

String _mp3DecodeText(Uint8List b, int start, int end, int enc) {
  if (end > b.length) end = b.length;
  if (end <= start) return '';
  if (_mp3IsWide(enc)) {
    var s = start;
    var littleEndian = false;
    if (end - s >= 2) {
      if (b[s] == 0xFF && b[s + 1] == 0xFE) {
        littleEndian = true;
        s += 2;
      } else if (b[s] == 0xFE && b[s + 1] == 0xFF) {
        s += 2;
      }
    }
    final units = <int>[];
    for (var i = s; i + 1 < end; i += 2) {
      units.add(littleEndian ? (b[i] | (b[i + 1] << 8)) : ((b[i] << 8) | b[i + 1]));
    }
    return String.fromCharCodes(units);
  }
  if (enc == 3) {
    return utf8.decode(Uint8List.sublistView(b, start, end), allowMalformed: true);
  }
  return String.fromCharCodes(b, start, end);
}

class _Mp3Str {
  final String value;

  /// Index of the first byte after the string (and its terminator).
  final int next;
  final bool terminated;

  const _Mp3Str(this.value, this.next, this.terminated);
}

_Mp3Str _mp3ReadString(Uint8List b, int start, int enc) {
  if (start >= b.length) return _Mp3Str('', b.length, false);
  final t = _mp3FindTerminator(b, start, enc);
  if (t < 0) return _Mp3Str(_mp3DecodeText(b, start, b.length, enc), b.length, false);
  return _Mp3Str(_mp3DecodeText(b, start, t, enc), t + (_mp3IsWide(enc) ? 2 : 1), true);
}

/// All (null separated) strings from [start] to the end of [b].
List<String> _mp3ReadStringList(Uint8List b, int start, int enc) {
  final values = <String>[];
  var pos = start;
  while (pos < b.length) {
    final r = _mp3ReadString(b, pos, enc);
    values.add(r.value);
    pos = r.next;
  }
  while (values.length > 1 && values.last.isEmpty) {
    values.removeLast();
  }
  return values;
}

// ---------------------------------------------------------------------------
// CRC-32 (ISO 3309 / ITU-T V.42, as used by the ID3v2 extended header)
// ---------------------------------------------------------------------------

final List<int> _mp3CrcTable = _mp3MakeCrcTable();

List<int> _mp3MakeCrcTable() {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c & 0xFFFFFFFF;
  }
  return t;
}

int _mp3Crc32(Uint8List d, int start, int end) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    c = (_mp3CrcTable[(c ^ d[i]) & 0xFF] ^ (c >> 8)) & 0xFFFFFFFF;
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
