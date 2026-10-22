part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// ID3v1 / ID3v1.1 (last 128 bytes) and the enhanced "TAG+" block (227 bytes
// in front of the ID3v1 tag).
// ---------------------------------------------------------------------------

String _mp3V1Text(Uint8List d, int start, int length) {
  var e = start;
  while (e < start + length && d[e] != 0) {
    e++;
  }
  return String.fromCharCodes(d, start, e).trimRight();
}

Map<String, Object?> _mp3V1Field(Uint8List d, int tagOffset, String name, int start, int length,
    {Object? value}) {
  final s = tagOffset + start;
  var hiddenData = false;
  var nul = -1;
  for (var i = s; i < s + length; i++) {
    if (d[i] == 0 && nul < 0) nul = i;
    if (nul >= 0 && d[i] != 0) hiddenData = true;
  }
  return <String, Object?>{
    'field': name,
    'offsetInTag': start,
    'offset': s,
    'length': length,
    'hex': _mp3Hex(d, s, s + length),
    'value': value ?? _mp3V1Text(d, s, length),
    if (hiddenData) 'warning': 'non-zero bytes after the string terminator',
  };
}

Map<String, Object?> _mp3ParseId3v1(Uint8List d, int off) {
  final isV11 = d[off + 125] == 0 && d[off + 126] != 0;
  final genre = d[off + 127];
  final fields = <Map<String, Object?>>[
    _mp3V1Field(d, off, 'Identifier', 0, 3),
    _mp3V1Field(d, off, 'Title', 3, 30),
    _mp3V1Field(d, off, 'Artist', 33, 30),
    _mp3V1Field(d, off, 'Album', 63, 30),
    _mp3V1Field(d, off, 'Year', 93, 4),
    _mp3V1Field(d, off, 'Comment', 97, isV11 ? 28 : 30),
    if (isV11) _mp3V1Field(d, off, 'Zero byte (ID3v1.1 marker)', 125, 1, value: 0),
    if (isV11) _mp3V1Field(d, off, 'Track', 126, 1, value: d[off + 126]),
    <String, Object?>{
      ..._mp3V1Field(d, off, 'Genre', 127, 1, value: genre),
      'genre': _mp3GenreName(genre),
    },
  ];
  return <String, Object?>{
    'version': isV11 ? 'ID3v1.1' : 'ID3v1.0',
    'offset': off,
    'offsetHex': _mp3HexOffset(off),
    'size': 128,
    'frames': fields,
    'values': <String, Object?>{
      'title': _mp3V1Text(d, off + 3, 30),
      'artist': _mp3V1Text(d, off + 33, 30),
      'album': _mp3V1Text(d, off + 63, 30),
      'year': _mp3V1Text(d, off + 93, 4),
      'comment': _mp3V1Text(d, off + 97, isV11 ? 28 : 30),
      if (isV11) 'track': d[off + 126],
      'genreIndex': genre,
      'genre': _mp3GenreName(genre),
    },
  };
}

Map<String, Object?> _mp3ParseId3v1Enhanced(Uint8List d, int off) {
  const speeds = <String>['unset', 'slow', 'medium', 'fast', 'hardcore'];
  final speed = d[off + 184];
  final fields = <Map<String, Object?>>[
    _mp3V1Field(d, off, 'Identifier', 0, 4),
    _mp3V1Field(d, off, 'Title (continuation, 60 chars)', 4, 60),
    _mp3V1Field(d, off, 'Artist (continuation, 60 chars)', 64, 60),
    _mp3V1Field(d, off, 'Album (continuation, 60 chars)', 124, 60),
    <String, Object?>{
      ..._mp3V1Field(d, off, 'Speed', 184, 1, value: speed),
      'meaning': speed < speeds.length ? speeds[speed] : 'undefined',
    },
    _mp3V1Field(d, off, 'Genre (free text)', 185, 30),
    _mp3V1Field(d, off, 'Start time (mmm:ss)', 215, 6),
    _mp3V1Field(d, off, 'End time (mmm:ss)', 221, 6),
  ];
  return <String, Object?>{
    'version': 'ID3v1 enhanced (TAG+)',
    'offset': off,
    'offsetHex': _mp3HexOffset(off),
    'size': 227,
    'frames': fields,
  };
}
