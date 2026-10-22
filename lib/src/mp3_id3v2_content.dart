part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// Content analysis of the ID3v2 frames (after unsynchronisation and
// decompression have been undone).
// ---------------------------------------------------------------------------

Map<String, Object?> _mp3ParseFrameContent(
    String id, Uint8List d, _Mp3Id3Context ctx, List<String> w, int depth) {
  final canon = ctx.major == 2 ? (_mp3V22ToV23[id] ?? id) : id;
  if (d.isEmpty) return <String, Object?>{'empty': true};
  if (ctx.major == 2 && id == 'PIC') return _mp3ContentPicture(d, ctx, w, true);
  switch (canon) {
    case 'TXXX':
      return _mp3ContentUserText(d, ctx, w);
    case 'WXXX':
      return _mp3ContentUserUrl(d, ctx, w);
    case 'COMM':
    case 'USLT':
    case 'USER':
      return _mp3ContentLanguageText(canon, d, ctx, w);
    case 'APIC':
      return _mp3ContentPicture(d, ctx, w, false);
    case 'GEOB':
      return _mp3ContentGeneralObject(d, ctx, w);
    case 'UFID':
    case 'PRIV':
      return _mp3ContentOwnerData(canon, d, w);
    case 'PCNT':
      if (d.length < 4) w.add('play counter must be at least 4 bytes');
      return <String, Object?>{'type': 'play counter', 'counter': _mp3Counter(d, 0, d.length)};
    case 'POPM':
      return _mp3ContentPopularimeter(d);
    case 'ENCR':
    case 'GRID':
      return _mp3ContentRegistration(canon, d);
    case 'AENC':
      return _mp3ContentAudioEncryption(d);
    case 'CRM':
      return _mp3ContentEncryptedMeta(d);
    case 'LINK':
      return _mp3ContentLink(d, ctx);
    case 'MCDI':
      return _mp3ContentMusicCdId(d);
    case 'ETCO':
      return _mp3ContentEventTiming(d);
    case 'SYLT':
      return _mp3ContentSyncLyrics(d, ctx, w);
    case 'SYTC':
      return <String, Object?>{
        'type': 'synchronised tempo codes',
        'timestampFormat': _mp3TimestampFormat(d[0]),
        'tempoDataBytes': d.length - 1,
        'tempoDataHexPreview': _mp3HexPreview(Uint8List.sublistView(d, 1)),
      };
    case 'MLLT':
      return _mp3ContentLocationLookup(d);
    case 'RVA2':
      return _mp3ContentRelativeVolume2(d);
    case 'RVAD':
      return _mp3ContentRelativeVolume(d);
    case 'EQU2':
      return _mp3ContentEqualisation2(d);
    case 'EQUA':
      return <String, Object?>{
        'type': 'equalisation',
        'adjustmentBits': d[0],
        'dataHexPreview': _mp3HexPreview(Uint8List.sublistView(d, 1)),
      };
    case 'RVRB':
      return _mp3ContentReverb(d);
    case 'RBUF':
      return <String, Object?>{
        'type': 'recommended buffer size',
        'bufferSize': _mp3UInt(d, 0, 3),
        'embeddedInfoFlag': (d[3] & 1) != 0,
        if (d.length >= 8) 'offsetToNextTag': _mp3UInt(d, 4, 4),
      };
    case 'POSS':
      return <String, Object?>{
        'type': 'position synchronisation',
        'timestampFormat': _mp3TimestampFormat(d[0]),
        'position': _mp3Counter(d, 1, d.length),
      };
    case 'SEEK':
      return <String, Object?>{'type': 'seek frame', 'minimumOffsetToNextTag': _mp3UInt(d, 0, 4)};
    case 'ASPI':
      return <String, Object?>{
        'type': 'audio seek point index',
        'indexedDataStart': _mp3UInt(d, 0, 4),
        'indexedDataLength': _mp3UInt(d, 4, 4),
        'numberOfIndexPoints': _mp3UInt(d, 8, 2),
        'bitsPerIndexPoint': d[10],
      };
    case 'SIGN':
      return <String, Object?>{
        'type': 'signature',
        'groupSymbol': d[0],
        'signatureBytes': d.length - 1,
        'signatureHexPreview': _mp3HexPreview(Uint8List.sublistView(d, 1)),
      };
    case 'OWNE':
      return _mp3ContentOwnership(d, ctx, w);
    case 'COMR':
      return _mp3ContentCommercial(d, ctx, w);
    case 'CHAP':
      return _mp3ContentChapter(d, ctx, depth);
    case 'CTOC':
      return _mp3ContentTableOfContents(d, ctx, depth);
  }
  if (canon.startsWith('T') || canon == 'GRP1' || canon == 'MVNM' || canon == 'MVIN') {
    return _mp3ContentText(canon, d, ctx, w);
  }
  if (canon.startsWith('W')) {
    final url = _mp3ReadString(d, 0, 0);
    return <String, Object?>{'type': 'URL link frame', 'url': url.value};
  }
  return <String, Object?>{
    'type': 'unknown, experimental or proprietary frame',
    'hexPreview': _mp3HexPreview(d, 64),
    'asciiPreview': _mp3AsciiPreview(d),
  };
}

// --- helpers ---------------------------------------------------------------

int _mp3TextEncoding(Uint8List d, int offset, _Mp3Id3Context ctx, List<String> w, Map<String, Object?> out) {
  final enc = d[offset];
  out['textEncoding'] = <String, Object?>{'byte': enc, 'name': _mp3EncodingNames[enc] ?? 'invalid'};
  if (enc > 3) {
    w.add('invalid text encoding byte $enc, decoded as ISO-8859-1');
    return 0;
  }
  if (enc >= 2 && ctx.major < 4) {
    w.add('text encoding $enc (${_mp3EncodingNames[enc]}) is only defined in ID3v2.4');
  }
  return enc;
}

Map<String, Object?> _mp3TimestampFormat(int f) => <String, Object?>{
      'byte': f,
      'meaning': f == 1
          ? 'absolute time in MPEG frames'
          : (f == 2 ? 'absolute time in milliseconds' : 'undefined'),
    };

Map<String, Object?> _mp3AnalyzeBinaryObject(Uint8List b) {
  final out = <String, Object?>{'sizeBytes': b.length, 'hexPreview': _mp3HexPreview(b, 16)};
  String? format;
  int? width;
  int? height;
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    format = 'JPEG';
    final dims = _mp3JpegDimensions(b);
    if (dims != null) {
      width = dims[0];
      height = dims[1];
    }
  } else if (b.length >= 8 && b[0] == 0x89 && _mp3StartsWith(b, 1, 'PNG')) {
    format = 'PNG';
    if (b.length >= 24 && _mp3StartsWith(b, 12, 'IHDR')) {
      width = _mp3UInt(b, 16, 4);
      height = _mp3UInt(b, 20, 4);
    }
  } else if (_mp3StartsWith(b, 0, 'GIF8')) {
    format = 'GIF';
    if (b.length >= 10) {
      width = _mp3UIntLE(b, 6, 2);
      height = _mp3UIntLE(b, 8, 2);
    }
  } else if (_mp3StartsWith(b, 0, 'BM') && b.length >= 26) {
    format = 'BMP';
    width = _mp3UIntLE(b, 18, 4);
    height = _mp3UIntLE(b, 22, 4);
  } else if (_mp3StartsWith(b, 0, 'RIFF') && _mp3StartsWith(b, 8, 'WEBP')) {
    format = 'WebP';
  } else if (_mp3StartsWith(b, 4, 'ftyp')) {
    format = 'ISO base media (MP4/HEIF/AVIF)';
  } else if (_mp3StartsWith(b, 0, '%PDF')) {
    format = 'PDF';
  } else if (_mp3StartsWith(b, 0, 'PK')) {
    format = 'ZIP';
  } else if (_mp3StartsWith(b, 0, '-->')) {
    format = 'URL link (picture is referenced, not embedded)';
  }
  if (format != null) out['detectedFormat'] = format;
  if (width != null) out['width'] = width;
  if (height != null) out['height'] = height;
  return out;
}

List<int>? _mp3JpegDimensions(Uint8List b) {
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++;
      continue;
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final segmentLength = _mp3UInt(b, i + 2, 2);
    final isSof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
    if (isSof) return <int>[_mp3UInt(b, i + 7, 2), _mp3UInt(b, i + 5, 2)];
    if (segmentLength < 2) return null;
    i += 2 + segmentLength;
  }
  return null;
}

// --- text frames -----------------------------------------------------------

Map<String, Object?> _mp3ContentText(String canon, Uint8List d, _Mp3Id3Context ctx, List<String> w) {
  final out = <String, Object?>{'type': 'text information frame'};
  final enc = _mp3TextEncoding(d, 0, ctx, w, out);
  final values = _mp3ReadStringList(d, 1, enc);
  if (values.length > 1 && ctx.major < 4) {
    w.add('several null separated strings are only defined in ID3v2.4');
  }
  out['values'] = values;
  out['text'] = values.join(' / ');
  final first = values.isEmpty ? '' : values.first.trim();
  if (canon == 'TRCK' || canon == 'TPOS') {
    final parts = first.split('/');
    out['number'] = int.tryParse(parts[0].trim());
    if (parts.length > 1) out['total'] = int.tryParse(parts[1].trim());
  } else if (canon == 'TLEN') {
    final ms = int.tryParse(first);
    if (ms != null) out['length'] = _mp3FormatDuration(ms);
  } else if (canon == 'TCON') {
    out['genres'] = _mp3ResolveGenres(values);
  } else if (canon == 'IPLS' || canon == 'TIPL' || canon == 'TMCL') {
    final pairs = <Map<String, Object?>>[];
    for (var i = 0; i + 1 < values.length; i += 2) {
      pairs.add(<String, Object?>{'role': values[i], 'person': values[i + 1]});
    }
    out['pairs'] = pairs;
  } else if (canon == 'TFLT') {
    const types = <String, String>{
      'MIME': 'MIME type follows',
      'MPG': 'MPEG audio',
      '/1': 'MPEG 1/2 layer I',
      '/2': 'MPEG 1/2 layer II',
      '/3': 'MPEG 1/2 layer III',
      '/2.5': 'MPEG 2.5',
      '/AAC': 'Advanced audio compression',
      'VQF': 'Transform-domain Weighted Interleave Vector Quantisation',
      'PCM': 'Pulse Code Modulated audio',
    };
    final known = types[first];
    if (known != null) out['meaning'] = known;
  }
  return out;
}

Map<String, Object?> _mp3ContentUserText(Uint8List d, _Mp3Id3Context ctx, List<String> w) {
  final out = <String, Object?>{'type': 'user defined text information'};
  final enc = _mp3TextEncoding(d, 0, ctx, w, out);
  final description = _mp3ReadString(d, 1, enc);
  final values = _mp3ReadStringList(d, description.next, enc);
  out['description'] = description.value;
  out['values'] = values;
  out['value'] = values.join(' / ');
  return out;
}

Map<String, Object?> _mp3ContentUserUrl(Uint8List d, _Mp3Id3Context ctx, List<String> w) {
  final out = <String, Object?>{'type': 'user defined URL link'};
  final enc = _mp3TextEncoding(d, 0, ctx, w, out);
  final description = _mp3ReadString(d, 1, enc);
  out['description'] = description.value;
  out['url'] = _mp3ReadString(d, description.next, 0).value;
  return out;
}

Map<String, Object?> _mp3ContentLanguageText(String canon, Uint8List d, _Mp3Id3Context ctx, List<String> w) {
  final out = <String, Object?>{
    'type': canon == 'COMM'
        ? 'comment'
        : (canon == 'USLT' ? 'unsynchronised lyrics / text transcription' : 'terms of use'),
  };
  final enc = _mp3TextEncoding(d, 0, ctx, w, out);
  out['language'] = _mp3Latin1(d, 1, 4);
  var textStart = 4;
  if (canon != 'USER') {
    final descriptor = _mp3ReadString(d, 4, enc);
    out['contentDescriptor'] = descriptor.value;
    textStart = descriptor.next;
  }
  out['text'] = _mp3ReadStringList(d, textStart, enc).join('\n');
  return out;
}

// --- binary frames ---------------------------------------------------------

const _mp3PictureTypes = <String>[
  'Other',
  '32x32 pixels file icon (PNG only)',
  'Other file icon',
  'Cover (front)',
  'Cover (back)',
  'Leaflet page',
  'Media (e.g. label side of CD)',
  'Lead artist / lead performer / soloist',
  'Artist / performer',
  'Conductor',
  'Band / Orchestra',
  'Composer',
  'Lyricist / text writer',
  'Recording location',
  'During recording',
  'During performance',
  'Movie / video screen capture',
  'A bright coloured fish',
  'Illustration',
  'Band / artist logotype',
  'Publisher / studio logotype',
];

Map<String, Object?> _mp3ContentPicture(Uint8List d, _Mp3Id3Context ctx, List<String> w, bool v22) {
  final out = <String, Object?>{'type': 'attached picture'};
  final enc = _mp3TextEncoding(d, 0, ctx, w, out);
  var p = 1;
  if (v22) {
    out['imageFormat'] = _mp3Latin1(d, 1, 4);
    p = 4;
  } else {
    final mime = _mp3ReadString(d, 1, 0);
    out['mimeType'] = mime.value;
    p = mime.next;
  }
  final type = d[p];
  out['pictureType'] = <String, Object?>{
    'byte': type,
    'name': type < _mp3PictureTypes.length ? _mp3PictureTypes[type] : 'undefined',
  };
  final description = _mp3ReadString(d, p + 1, enc);
  out['description'] = description.value;
  out['picture'] = _mp3AnalyzeBinaryObject(Uint8List.sublistView(d, description.next));
  return out;
}

Map<String, Object?> _mp3ContentGeneralObject(Uint8List d, _Mp3Id3Context ctx, List<String> w) {
  final out = <String, Object?>{'type': 'general encapsulated object'};
  final enc = _mp3TextEncoding(d, 0, ctx, w, out);
  final mime = _mp3ReadString(d, 1, 0);
  final filename = _mp3ReadString(d, mime.next, enc);
  final description = _mp3ReadString(d, filename.next, enc);
  out['mimeType'] = mime.value;
  out['filename'] = filename.value;
  out['contentDescription'] = description.value;
  out['object'] = _mp3AnalyzeBinaryObject(Uint8List.sublistView(d, description.next));
  return out;
}

Map<String, Object?> _mp3ContentOwnerData(String canon, Uint8List d, List<String> w) {
  final owner = _mp3ReadString(d, 0, 0);
  final data = Uint8List.sublistView(d, owner.next);
  if (canon == 'UFID' && data.length > 64) w.add('UFID identifier must not exceed 64 bytes');
  if (owner.value.isEmpty) w.add('owner identifier is empty');
  return <String, Object?>{
    'type': canon == 'UFID' ? 'unique file identifier' : 'private frame',
    'ownerIdentifier': owner.value,
    'dataBytes': data.length,
    'dataHexPreview': _mp3HexPreview(data, 64),
    'dataAsciiPreview': _mp3AsciiPreview(data),
  };
}

Map<String, Object?> _mp3ContentPopularimeter(Uint8List d) {
  final email = _mp3ReadString(d, 0, 0);
  final out = <String, Object?>{'type': 'popularimeter', 'email': email.value};
  if (email.next < d.length) {
    final rating = d[email.next];
    out['rating'] = rating;
    out['ratingStars'] = rating == 0
        ? 'unknown'
        : (rating < 32 ? 1 : (rating < 96 ? 2 : (rating < 160 ? 3 : (rating < 224 ? 4 : 5))));
    if (email.next + 1 < d.length) out['counter'] = _mp3Counter(d, email.next + 1, d.length);
  }
  return out;
}

Map<String, Object?> _mp3ContentRegistration(String canon, Uint8List d) {
  final owner = _mp3ReadString(d, 0, 0);
  final symbol = owner.next < d.length ? d[owner.next] : null;
  final data = owner.next + 1 <= d.length ? Uint8List.sublistView(d, owner.next + 1) : Uint8List(0);
  return <String, Object?>{
    'type': canon == 'ENCR' ? 'encryption method registration' : 'group identification registration',
    'ownerIdentifier': owner.value,
    if (canon == 'ENCR') 'methodSymbol': symbol else 'groupSymbol': symbol,
    if (symbol != null) 'symbolHex': _mp3HexByte(symbol),
    if (symbol != null && symbol < 0x80) 'note': 'symbols below 0x80 are reserved',
    'dataBytes': data.length,
    'dataHexPreview': _mp3HexPreview(data),
  };
}

Map<String, Object?> _mp3ContentAudioEncryption(Uint8List d) {
  final owner = _mp3ReadString(d, 0, 0);
  final p = owner.next;
  return <String, Object?>{
    'type': 'audio encryption',
    'ownerIdentifier': owner.value,
    'previewStartFrames': _mp3UInt(d, p, 2),
    'previewLengthFrames': _mp3UInt(d, p + 2, 2),
    'encryptionInfoBytes': d.length - p - 4,
    'encryptionInfoHexPreview': _mp3HexPreview(Uint8List.sublistView(d, p + 4)),
  };
}

Map<String, Object?> _mp3ContentEncryptedMeta(Uint8List d) {
  final owner = _mp3ReadString(d, 0, 0);
  final explanation = _mp3ReadString(d, owner.next, 0);
  final data = Uint8List.sublistView(d, explanation.next);
  return <String, Object?>{
    'type': 'encrypted meta frame (ID3v2.2)',
    'ownerIdentifier': owner.value,
    'contentExplanation': explanation.value,
    'encryptedBytes': data.length,
    'encryptedHexPreview': _mp3HexPreview(data),
  };
}

Map<String, Object?> _mp3ContentLink(Uint8List d, _Mp3Id3Context ctx) {
  final idLength = ctx.major == 2 ? 3 : 4;
  final url = _mp3ReadString(d, idLength, 0);
  return <String, Object?>{
    'type': 'linked information',
    'linkedFrameId': _mp3Latin1(d, 0, idLength),
    'url': url.value,
    'additionalIdData': _mp3ReadStringList(d, url.next, 0),
  };
}

Map<String, Object?> _mp3ContentMusicCdId(Uint8List d) {
  final out = <String, Object?>{
    'type': 'music CD identifier (binary CD table of contents)',
    'sizeBytes': d.length,
    'hexPreview': _mp3HexPreview(d, 64),
  };
  if (d.length >= 4) {
    out['tocDataLength'] = _mp3UInt(d, 0, 2);
    out['firstTrack'] = d[2];
    out['lastTrack'] = d[3];
    final tracks = <Map<String, Object?>>[];
    for (var p = 4; p + 8 <= d.length; p += 8) {
      tracks.add(<String, Object?>{
        'track': d[p + 2] == 0xAA ? 'lead-out' : d[p + 2],
        'adrControl': _mp3HexByte(d[p + 1]),
        'startAddressLba': _mp3UInt(d, p + 4, 4),
      });
    }
    out['tracks'] = tracks;
  }
  return out;
}

const _mp3EventTypes = <int, String>{
  0x00: 'padding (no meaning)',
  0x01: 'end of initial silence',
  0x02: 'intro start',
  0x03: 'main part start',
  0x04: 'outro start',
  0x05: 'outro end',
  0x06: 'verse start',
  0x07: 'refrain start',
  0x08: 'interlude start',
  0x09: 'theme start',
  0x0A: 'variation start',
  0x0B: 'key change',
  0x0C: 'time change',
  0x0D: 'momentary unwanted noise (snap, crackle & pop)',
  0x0E: 'sustained noise',
  0x0F: 'sustained noise end',
  0x10: 'intro end',
  0x11: 'main part end',
  0x12: 'verse end',
  0x13: 'refrain end',
  0x14: 'theme end',
  0x15: 'profanity',
  0x16: 'profanity end',
  0xFD: 'audio end (start of silence)',
  0xFE: 'audio file ends',
  0xFF: 'one more byte of events follows',
};

Map<String, Object?> _mp3ContentEventTiming(Uint8List d) {
  final events = <Map<String, Object?>>[];
  for (var p = 1; p + 5 <= d.length; p += 5) {
    final t = d[p];
    events.add(<String, Object?>{
      'eventType': _mp3HexByte(t),
      'meaning': _mp3EventTypes[t] ??
          (t >= 0xE0 && t <= 0xEF ? 'not predefined synch ${t - 0xE0}' : 'reserved'),
      'time': _mp3UInt(d, p + 1, 4),
    });
  }
  return <String, Object?>{
    'type': 'event timing codes',
    'timestampFormat': _mp3TimestampFormat(d[0]),
    'events': events,
  };
}

Map<String, Object?> _mp3ContentSyncLyrics(Uint8List d, _Mp3Id3Context ctx, List<String> w) {
  const contentTypes = <String>[
    'other',
    'lyrics',
    'text transcription',
    'movement / part name',
    'events',
    'chord',
    'trivia / pop up information',
    'URLs to webpages',
    'URLs to images',
  ];
  final out = <String, Object?>{'type': 'synchronised lyrics / text'};
  final enc = _mp3TextEncoding(d, 0, ctx, w, out);
  out['language'] = _mp3Latin1(d, 1, 4);
  out['timestampFormat'] = _mp3TimestampFormat(d[4]);
  final ct = d[5];
  out['contentType'] = <String, Object?>{
    'byte': ct,
    'name': ct < contentTypes.length ? contentTypes[ct] : 'undefined',
  };
  final descriptor = _mp3ReadString(d, 6, enc);
  out['contentDescriptor'] = descriptor.value;
  final entries = <Map<String, Object?>>[];
  var p = descriptor.next;
  while (p < d.length) {
    final s = _mp3ReadString(d, p, enc);
    p = s.next;
    if (p + 4 > d.length) break;
    entries.add(<String, Object?>{'time': _mp3UInt(d, p, 4), 'text': s.value});
    p += 4;
  }
  out['entries'] = entries;
  return out;
}

Map<String, Object?> _mp3ContentLocationLookup(Uint8List d) => <String, Object?>{
      'type': 'MPEG location lookup table',
      'framesBetweenReference': _mp3UInt(d, 0, 2),
      'bytesBetweenReference': _mp3UInt(d, 2, 3),
      'millisecondsBetweenReference': _mp3UInt(d, 5, 3),
      'bitsForBytesDeviation': d[8],
      'bitsForMillisecondsDeviation': d[9],
      'referenceDataBytes': d.length - 10,
      'referenceDataHexPreview': _mp3HexPreview(Uint8List.sublistView(d, 10)),
    };

const _mp3ChannelTypes = <String>[
  'other',
  'master volume',
  'front right',
  'front left',
  'back right',
  'back left',
  'front centre',
  'back centre',
  'subwoofer',
];

Map<String, Object?> _mp3ContentRelativeVolume2(Uint8List d) {
  final identification = _mp3ReadString(d, 0, 0);
  final channels = <Map<String, Object?>>[];
  var p = identification.next;
  while (p + 4 <= d.length) {
    final type = d[p];
    final bits = d[p + 3];
    final peakBytes = (bits + 7) ~/ 8;
    channels.add(<String, Object?>{
      'channelType': type,
      'channel': type < _mp3ChannelTypes.length ? _mp3ChannelTypes[type] : 'undefined',
      'volumeAdjustmentDb': _mp3Int16(d, p + 1) / 512.0,
      'bitsRepresentingPeak': bits,
      if (peakBytes > 0 && p + 4 + peakBytes <= d.length) 'peakVolume': _mp3Counter(d, p + 4, p + 4 + peakBytes),
    });
    p += 4 + peakBytes;
  }
  return <String, Object?>{
    'type': 'relative volume adjustment (2)',
    'identification': identification.value,
    'channels': channels,
  };
}

Map<String, Object?> _mp3ContentRelativeVolume(Uint8List d) {
  const names = <String>[
    'right', 'left', 'peakRight', 'peakLeft', //
    'rightBack', 'leftBack', 'peakRightBack', 'peakLeftBack',
    'center', 'peakCenter', 'bass', 'peakBass',
  ];
  final incDec = d[0];
  final bits = d[1];
  final n = (bits + 7) ~/ 8;
  final values = <String, Object?>{};
  var p = 2;
  for (final name in names) {
    if (n == 0 || p + n > d.length) break;
    values[name] = _mp3Counter(d, p, p + n);
    p += n;
  }
  return <String, Object?>{
    'type': 'relative volume adjustment',
    'incrementDecrement': <String, Object?>{
      'bits': _mp3Bin(incDec, 8),
      'right': (incDec & 0x01) != 0 ? 'increment' : 'decrement',
      'left': (incDec & 0x02) != 0 ? 'increment' : 'decrement',
      'rightBack': (incDec & 0x04) != 0 ? 'increment' : 'decrement',
      'leftBack': (incDec & 0x08) != 0 ? 'increment' : 'decrement',
      'center': (incDec & 0x10) != 0 ? 'increment' : 'decrement',
      'bass': (incDec & 0x20) != 0 ? 'increment' : 'decrement',
    },
    'bitsUsedForVolumeDescription': bits,
    'values': values,
  };
}

Map<String, Object?> _mp3ContentEqualisation2(Uint8List d) {
  final identification = _mp3ReadString(d, 1, 0);
  final points = <Map<String, Object?>>[];
  for (var p = identification.next; p + 4 <= d.length; p += 4) {
    points.add(<String, Object?>{
      'frequencyHz': _mp3UInt(d, p, 2) / 2.0,
      'volumeAdjustmentDb': _mp3Int16(d, p + 2) / 512.0,
    });
  }
  return <String, Object?>{
    'type': 'equalisation (2)',
    'interpolationMethod': d[0] == 0 ? 'band' : (d[0] == 1 ? 'linear' : 'undefined (${d[0]})'),
    'identification': identification.value,
    'adjustmentPoints': points,
  };
}

Map<String, Object?> _mp3ContentReverb(Uint8List d) => <String, Object?>{
      'type': 'reverb',
      'reverbLeftMs': _mp3UInt(d, 0, 2),
      'reverbRightMs': _mp3UInt(d, 2, 2),
      'reverbBouncesLeft': d[4],
      'reverbBouncesRight': d[5],
      'reverbFeedbackLeftToLeft': d[6],
      'reverbFeedbackLeftToRight': d[7],
      'reverbFeedbackRightToRight': d[8],
      'reverbFeedbackRightToLeft': d[9],
      'premixLeftToRight': d[10],
      'premixRightToLeft': d[11],
    };

Map<String, Object?> _mp3ContentOwnership(Uint8List d, _Mp3Id3Context ctx, List<String> w) {
  final out = <String, Object?>{'type': 'ownership'};
  final enc = _mp3TextEncoding(d, 0, ctx, w, out);
  final price = _mp3ReadString(d, 1, 0);
  out['pricePaid'] = price.value;
  out['dateOfPurchase'] = _mp3Latin1(d, price.next, price.next + 8);
  out['seller'] = _mp3ReadString(d, price.next + 8, enc).value;
  return out;
}

Map<String, Object?> _mp3ContentCommercial(Uint8List d, _Mp3Id3Context ctx, List<String> w) {
  const receivedAs = <String>[
    'other',
    'standard CD album with other songs',
    'compressed audio on CD',
    'file over the Internet',
    'stream over the Internet',
    'as note sheets',
    'as note sheets in a book with other sheets',
    'music on other media',
    'non-musical merchandise',
  ];
  final out = <String, Object?>{'type': 'commercial frame'};
  final enc = _mp3TextEncoding(d, 0, ctx, w, out);
  final price = _mp3ReadString(d, 1, 0);
  out['priceString'] = price.value;
  out['validUntil'] = _mp3Latin1(d, price.next, price.next + 8);
  final url = _mp3ReadString(d, price.next + 8, 0);
  out['contactUrl'] = url.value;
  final r = d[url.next];
  out['receivedAs'] = <String, Object?>{'byte': r, 'meaning': r < receivedAs.length ? receivedAs[r] : 'undefined'};
  final seller = _mp3ReadString(d, url.next + 1, enc);
  final description = _mp3ReadString(d, seller.next, enc);
  out['nameOfSeller'] = seller.value;
  out['description'] = description.value;
  if (description.next < d.length) {
    final mime = _mp3ReadString(d, description.next, 0);
    out['pictureMimeType'] = mime.value;
    out['sellerLogo'] = _mp3AnalyzeBinaryObject(Uint8List.sublistView(d, mime.next));
  }
  return out;
}

// --- chapters (ID3v2 Chapter Frame Addendum) ---------------------------------

Object _mp3ChapterOffset(int v) => v == 0xFFFFFFFF ? 'not used (0xFFFFFFFF)' : v;

Map<String, Object?> _mp3ContentChapter(Uint8List d, _Mp3Id3Context ctx, int depth) {
  final element = _mp3ReadString(d, 0, 0);
  final p = element.next;
  final startMs = _mp3UInt(d, p, 4);
  final endMs = _mp3UInt(d, p + 4, 4);
  return <String, Object?>{
    'type': 'chapter',
    'elementId': element.value,
    'startTimeMs': startMs,
    'startTime': _mp3FormatDuration(startMs),
    'endTimeMs': endMs,
    'endTime': _mp3FormatDuration(endMs),
    'startOffset': _mp3ChapterOffset(_mp3UInt(d, p + 8, 4)),
    'endOffset': _mp3ChapterOffset(_mp3UInt(d, p + 12, 4)),
    'subFrames': depth < 4 ? _mp3ParseId3v2Frames(d, p + 16, d.length, ctx, null, depth + 1) : const <Object?>[],
  };
}

Map<String, Object?> _mp3ContentTableOfContents(Uint8List d, _Mp3Id3Context ctx, int depth) {
  final element = _mp3ReadString(d, 0, 0);
  var p = element.next;
  final flags = d[p];
  final count = d[p + 1];
  p += 2;
  final children = <String>[];
  for (var i = 0; i < count && p < d.length; i++) {
    final s = _mp3ReadString(d, p, 0);
    children.add(s.value);
    p = s.next;
  }
  return <String, Object?>{
    'type': 'table of contents',
    'elementId': element.value,
    'flags': _mp3Bin(flags, 8),
    'topLevel': (flags & 0x02) != 0,
    'ordered': (flags & 0x01) != 0,
    'entryCount': count,
    'childElementIds': children,
    'subFrames': depth < 4 ? _mp3ParseId3v2Frames(d, p, d.length, ctx, null, depth + 1) : const <Object?>[],
  };
}
