part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// Minimal zlib / deflate decoder (RFC 1950 / RFC 1951) for compressed ID3v2
// frames. Pure Dart, so it also works on the web (no dart:io).
// ---------------------------------------------------------------------------

class _Mp3InflateException implements Exception {
  final String message;

  _Mp3InflateException(this.message);

  @override
  String toString() => 'inflate error: $message';
}

/// Decompresses zlib data (falls back to raw deflate if there is no zlib header).
Uint8List _mp3ZlibInflate(Uint8List d) {
  if (d.length >= 2 && (d[0] & 0x0F) == 8 && ((d[0] << 8) | d[1]) % 31 == 0) {
    if ((d[1] & 0x20) != 0) {
      throw _Mp3InflateException('preset dictionary is not supported');
    }
    return _Mp3Inflater(d, 2).inflate();
  }
  return _Mp3Inflater(d, 0).inflate();
}

const _mp3LenBase = <int>[
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, //
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
];
const _mp3LenExtra = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, //
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
];
const _mp3DistBase = <int>[
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, //
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
];
const _mp3DistExtra = <int>[
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, //
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
];
const _mp3CodeLengthOrder = <int>[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

class _Mp3Huffman {
  final List<int> count = List<int>.filled(16, 0);
  final List<int> symbol;

  _Mp3Huffman(List<int> lengths) : symbol = List<int>.filled(lengths.length, 0) {
    for (final l in lengths) {
      count[l]++;
    }
    final offs = List<int>.filled(16, 0);
    for (var len = 1; len < 15; len++) {
      offs[len + 1] = offs[len] + count[len];
    }
    for (var s = 0; s < lengths.length; s++) {
      if (lengths[s] != 0) symbol[offs[lengths[s]]++] = s;
    }
  }
}

class _Mp3Inflater {
  final Uint8List _in;
  int _pos;
  int _bitBuf = 0;
  int _bitCnt = 0;
  final List<int> _out = <int>[];

  _Mp3Inflater(this._in, this._pos);

  int _bits(int need) {
    var val = _bitBuf;
    while (_bitCnt < need) {
      if (_pos >= _in.length) throw _Mp3InflateException('unexpected end of data');
      val |= _in[_pos++] << _bitCnt;
      _bitCnt += 8;
    }
    _bitBuf = val >> need;
    _bitCnt -= need;
    return val & ((1 << need) - 1);
  }

  void _stored() {
    _bitBuf = 0;
    _bitCnt = 0;
    if (_pos + 4 > _in.length) throw _Mp3InflateException('stored block header truncated');
    final len = _in[_pos] | (_in[_pos + 1] << 8);
    final nlen = _in[_pos + 2] | (_in[_pos + 3] << 8);
    _pos += 4;
    if (len != (~nlen & 0xFFFF)) throw _Mp3InflateException('stored block length check failed');
    if (_pos + len > _in.length) throw _Mp3InflateException('stored block truncated');
    _out.addAll(_in.getRange(_pos, _pos + len));
    _pos += len;
  }

  int _decode(_Mp3Huffman h) {
    var code = 0;
    var first = 0;
    var index = 0;
    for (var len = 1; len < 16; len++) {
      code |= _bits(1);
      final count = h.count[len];
      if (code - count < first) return h.symbol[index + (code - first)];
      index += count;
      first += count;
      first <<= 1;
      code <<= 1;
    }
    throw _Mp3InflateException('invalid Huffman code');
  }

  void _codes(_Mp3Huffman lencode, _Mp3Huffman distcode) {
    while (true) {
      var sym = _decode(lencode);
      if (sym < 256) {
        _out.add(sym);
      } else if (sym == 256) {
        return;
      } else {
        sym -= 257;
        if (sym >= 29) throw _Mp3InflateException('invalid length symbol');
        final len = _mp3LenBase[sym] + _bits(_mp3LenExtra[sym]);
        final dsym = _decode(distcode);
        if (dsym >= 30) throw _Mp3InflateException('invalid distance symbol');
        final dist = _mp3DistBase[dsym] + _bits(_mp3DistExtra[dsym]);
        if (dist > _out.length) throw _Mp3InflateException('distance too far back');
        final start = _out.length - dist;
        for (var i = 0; i < len; i++) {
          _out.add(_out[start + i]);
        }
      }
    }
  }

  void _fixed() {
    final lengths = List<int>.filled(288, 0);
    for (var i = 0; i < 288; i++) {
      lengths[i] = i < 144 ? 8 : (i < 256 ? 9 : (i < 280 ? 7 : 8));
    }
    _codes(_Mp3Huffman(lengths), _Mp3Huffman(List<int>.filled(30, 5)));
  }

  void _dynamic() {
    final nlen = _bits(5) + 257;
    final ndist = _bits(5) + 1;
    final ncode = _bits(4) + 4;
    if (nlen > 286 || ndist > 30) throw _Mp3InflateException('bad dynamic block counts');
    final clen = List<int>.filled(19, 0);
    for (var i = 0; i < ncode; i++) {
      clen[_mp3CodeLengthOrder[i]] = _bits(3);
    }
    final lencode = _Mp3Huffman(clen);
    final lengths = List<int>.filled(nlen + ndist, 0);
    var index = 0;
    while (index < nlen + ndist) {
      final sym = _decode(lencode);
      if (sym < 16) {
        lengths[index++] = sym;
      } else {
        var value = 0;
        int repeat;
        if (sym == 16) {
          if (index == 0) throw _Mp3InflateException('repeat without previous length');
          value = lengths[index - 1];
          repeat = 3 + _bits(2);
        } else if (sym == 17) {
          repeat = 3 + _bits(3);
        } else {
          repeat = 11 + _bits(7);
        }
        if (index + repeat > nlen + ndist) throw _Mp3InflateException('too many lengths');
        while (repeat-- > 0) {
          lengths[index++] = value;
        }
      }
    }
    if (lengths[256] == 0) throw _Mp3InflateException('no end-of-block code');
    _codes(_Mp3Huffman(lengths.sublist(0, nlen)), _Mp3Huffman(lengths.sublist(nlen)));
  }

  Uint8List inflate() {
    var last = 0;
    do {
      last = _bits(1);
      final type = _bits(2);
      if (type == 0) {
        _stored();
      } else if (type == 1) {
        _fixed();
      } else if (type == 2) {
        _dynamic();
      } else {
        throw _Mp3InflateException('invalid block type');
      }
    } while (last == 0);
    return Uint8List.fromList(_out);
  }
}
