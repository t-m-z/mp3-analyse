part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// WAV (RIFF / RIFX / RF64 / BW64 WAVE) analysis.
//
// Every chunk is listed with offset, header, size and pad byte; the content
// of the known chunks is analysed (fmt, data, fact, LIST/INFO, LIST/adtl,
// cue, plst, smpl, inst, acid, bext, cart, ds64, PEAK, iXML, axml, _PMX,
// DISP, afsp, chna, JUNK/PAD/FLLR, id3/ID3). ID3 tags (in "id3 " chunks, in
// front of or behind the RIFF container) are analysed with the ID3 analysis
// of this library.
// ---------------------------------------------------------------------------

class _WavContext {
  final bool bigEndian;
  final List<String> warnings;
  final List<Map<String, Object?>> id3v2 = <Map<String, Object?>>[];
  final List<Map<String, Object?>> id3v1 = <Map<String, Object?>>[];
  final Map<String, String> info = <String, String>{};
  final Map<String, int> ds64Table = <String, int>{};
  Map<String, Object?>? fmt;
  Map<String, Object?>? dataChunk;
  int? dataStart;
  int? dataEnd;
  int? ds64RiffSize;
  int? ds64DataSize;
  int? ds64SampleCount;
  int? factSamples;
  bool hasBext = false;

  _WavContext(this.bigEndian, this.warnings);

  int u(Uint8List d, int o, int l) => bigEndian ? _mp3UInt(d, o, l) : _mp3UIntLE(d, o, l);

  int s(Uint8List d, int o, int l) {
    final v = u(d, o, l);
    final half = l == 1 ? 0x80 : (l == 2 ? 0x8000 : (l == 3 ? 0x800000 : 0x80000000));
    return v >= half ? v - 2 * half : v;
  }

  int u64(Uint8List d, int o) =>
      bigEndian ? u(d, o, 4) * 0x100000000 + u(d, o + 4, 4) : u(d, o, 4) + u(d, o + 4, 4) * 0x100000000;

  double f32(Uint8List d, int o) =>
      ByteData.sublistView(d, o, o + 4).getFloat32(0, bigEndian ? Endian.big : Endian.little);

  int? get sampleRate => fmt?['sampleRate'] as int?;
}

// --- tables -----------------------------------------------------------------

const _wavFormatTags = <int, String>{
  0x0000: 'Unknown',
  0x0001: 'PCM (integer)',
  0x0002: 'Microsoft ADPCM',
  0x0003: 'IEEE float',
  0x0006: 'ITU G.711 A-law',
  0x0007: 'ITU G.711 µ-law',
  0x0010: 'OKI ADPCM',
  0x0011: 'IMA ADPCM (DVI)',
  0x0014: 'ITU G.723 ADPCM (Yamaha)',
  0x0022: 'DSP Group TrueSpeech',
  0x0031: 'GSM 6.10',
  0x0040: 'ITU G.721 ADPCM',
  0x0050: 'MPEG-1 Layer I/II',
  0x0055: 'MPEG Layer III (MP3)',
  0x0092: 'Dolby AC-3 SPDIF',
  0x00FF: 'AAC',
  0x0160: 'Windows Media Audio v1',
  0x0161: 'Windows Media Audio v2',
  0x0162: 'Windows Media Audio Pro',
  0x0163: 'Windows Media Audio Lossless',
  0x1610: 'HE-AAC (ADTS)',
  0x2000: 'Dolby AC-3',
  0x2001: 'DTS',
  0x674F: 'Ogg Vorbis (mode 1)',
  0x6750: 'Ogg Vorbis (mode 2)',
  0x6751: 'Ogg Vorbis (mode 3)',
  0xF1AC: 'FLAC',
  0xFFFE: 'WAVE_FORMAT_EXTENSIBLE',
  0xFFFF: 'Experimental',
};

const _wavSpeakers = <String>[
  'Front left', 'Front right', 'Front center', 'Low frequency (LFE)', //
  'Back left', 'Back right', 'Front left of center', 'Front right of center',
  'Back center', 'Side left', 'Side right', 'Top center',
  'Top front left', 'Top front center', 'Top front right',
  'Top back left', 'Top back center', 'Top back right',
];

const _wavChunkNames = <String, String>{
  'fmt ': 'Format',
  'data': 'Audio data',
  'fact': 'Fact (number of samples)',
  'LIST': 'List',
  'cue ': 'Cue points',
  'plst': 'Playlist',
  'smpl': 'Sampler',
  'inst': 'Instrument',
  'acid': 'ACID loop information',
  'bext': 'Broadcast audio extension (BWF)',
  'cart': 'Cart chunk (AES46)',
  'ds64': 'RF64 64-bit sizes',
  'PEAK': 'Peak envelope',
  'levl': 'Peak envelope (EBU levl)',
  'iXML': 'iXML production metadata',
  'axml': 'XML metadata (EBU axml)',
  '_PMX': 'XMP metadata',
  'chna': 'Channel assignment (ADM)',
  'umid': 'UMID (unique material identifier)',
  'DISP': 'Display',
  'afsp': 'AFsp metadata',
  'id3 ': 'ID3 tag',
  'ID3 ': 'ID3 tag',
  'ID32': 'ID3 tag',
  'JUNK': 'Junk (padding / alignment)',
  'junk': 'Junk (padding / alignment)',
  'PAD ': 'Padding',
  'FLLR': 'Filler',
  'fllr': 'Filler',
  'MD5 ': 'MD5 checksum of the audio data',
  'strc': 'Stretch information (ACID)',
  'minf': 'Sound Forge information',
  'elm1': 'Sound Forge information',
  'regn': 'Sound Forge regions',
  'ovwf': 'Sound Forge overview',
  'dbmd': 'Dolby metadata',
  'slnt': 'Silence',
  'labl': 'Label (associated data list)',
  'note': 'Note (associated data list)',
  'ltxt': 'Labelled text (associated data list)',
  'file': 'Embedded file (associated data list)',
};

const _wavInfoNames = <String, String>{
  'IARL': 'Archival location',
  'IART': 'Artist',
  'ICMS': 'Commissioned',
  'ICMT': 'Comment',
  'ICOP': 'Copyright',
  'ICRD': 'Creation date',
  'ICRP': 'Cropped',
  'IDIM': 'Dimensions',
  'IDIT': 'Digitization time',
  'IDPI': 'Dots per inch',
  'IENC': 'Encoded by',
  'IENG': 'Engineer',
  'IGNR': 'Genre',
  'IKEY': 'Keywords',
  'ILGT': 'Lightness',
  'ILNG': 'Language',
  'IMED': 'Medium',
  'INAM': 'Name (title)',
  'IPLT': 'Palette setting',
  'IPRD': 'Product (album)',
  'IPRT': 'Part (track number)',
  'ISBJ': 'Subject',
  'ISFT': 'Software',
  'ISHP': 'Sharpness',
  'ISMP': 'SMPTE time code',
  'ISRC': 'Source',
  'ISRF': 'Source form',
  'ITCH': 'Technician',
  'ITRK': 'Track number',
  'TORG': 'Origin',
  'TURL': 'URL',
};

const _wavListTypes = <String, String>{
  'INFO': 'Information (metadata as text)',
  'adtl': 'Associated data list (labels and notes for cue points)',
  'wavl': 'Wave list (alternating data and silence chunks)',
  'exif': 'EXIF metadata',
};

// --- helpers ------------------------------------------------------------------

bool _wavIsChunkId(Uint8List d, int o) {
  if (o < 0 || o + 4 > d.length) return false;
  for (var i = 0; i < 4; i++) {
    final c = d[o + i];
    if (c < 0x20 || c > 0x7E) return false;
  }
  return true;
}

/// Zero terminated text (UTF-8 if valid, otherwise ISO-8859-1).
String _wavText(Uint8List b, int start, int end) {
  if (end > b.length) end = b.length;
  if (start >= end) return '';
  var e = start;
  while (e < end && b[e] != 0) {
    e++;
  }
  final bytes = Uint8List.sublistView(b, start, e);
  try {
    return utf8.decode(bytes).trimRight();
  } on FormatException {
    return String.fromCharCodes(bytes).trimRight();
  }
}

String _wavTextPreview(Uint8List b, [int max = 2000]) {
  final t = _wavText(b, 0, b.length);
  return t.length > max ? '${t.substring(0, max)}...' : t;
}

double _wavRound(num v, [int digits = 2]) => double.parse(v.toStringAsFixed(digits));

double? _wavDb(double ratio) => ratio <= 0 ? null : _wavRound(20 * math.log(ratio) / math.ln10);

String _wavGuid(Uint8List b, int o, _WavContext ctx) {
  final d1 = ctx.u(b, o, 4).toRadixString(16).padLeft(8, '0');
  final d2 = ctx.u(b, o + 4, 2).toRadixString(16).padLeft(4, '0');
  final d3 = ctx.u(b, o + 6, 2).toRadixString(16).padLeft(4, '0');
  final d4 = _mp3Hex(b, o + 8, o + 10).replaceAll(' ', '');
  final d5 = _mp3Hex(b, o + 10, o + 16).replaceAll(' ', '');
  return '$d1-$d2-$d3-$d4-$d5'.toUpperCase();
}

List<String> _wavChannelLayout(int channels, int? mask) {
  if (mask != null && mask != 0 && mask != 0x80000000) {
    return <String>[
      for (var i = 0; i < _wavSpeakers.length; i++)
        if ((mask >> i) & 1 == 1) _wavSpeakers[i],
    ];
  }
  if (channels == 1) return const <String>['Mono'];
  if (channels == 2) return const <String>['Front left', 'Front right'];
  return <String>[for (var i = 1; i <= channels; i++) 'Channel $i (unassigned)'];
}

Map<String, Object?> _wavGenericContent(Uint8List b) => <String, Object?>{
      'hexPreview': _mp3HexPreview(b, 32),
      'asciiPreview': _mp3AsciiPreview(b),
    };

Map<String, Object?> _wavPaddingContent(Uint8List b) {
  var allZero = true;
  for (final x in b) {
    if (x != 0) {
      allZero = false;
      break;
    }
  }
  return <String, Object?>{
    'type': 'padding / reserved space (no meaning)',
    'allZero': allZero,
    if (!allZero) 'hexPreview': _mp3HexPreview(b, 32),
    if (!allZero) 'asciiPreview': _mp3AsciiPreview(b),
  };
}

// --- public entry -------------------------------------------------------------

/// Analyses the bytes of a WAV file (RIFF, RIFX, RF64 and BW64 containers).
///
/// The result is a JSON compatible map:
///
/// ```text
/// {
///   fileSize:   int
///   container:  { id, byteOrder, formType, offset, headerHex, declaredSize, ... }
///   format:     analysed "fmt " chunk (format tag, channels, sample rate, ...)
///   summary:    { format, channels, channelLayout, sampleRateHz,
///                 bitsPerSample, bitrateKbps, sampleFrames, duration, ... }
///   chunks:     [ { id, name, offset, headerHex, size, paddingByte,
///                   content{...}, subChunks?[...], warnings? } ]
///   chunksAfterRiff: [ ... ]          chunks behind the declared RIFF end
///   info:       { INAM: ..., IART: ... }   values of LIST/INFO
///   tagsFound:  [String]
///   id3v2:      [ tag ]               ID3v2 tags (id3 chunks, before/after RIFF)
///   id3v1:      [ tag ]               ID3v1 tags (id3 chunk or end of file)
///   trailingData: { offset, length, ... } | null
///   warnings:   [String]
/// }
/// ```
///
/// The ID3 tags have the same structure as in [id3v2Analyze] / [id3v1Analyze].
/// For PCM and IEEE float data, per channel statistics (peak, RMS, DC offset,
/// clipping) are calculated; MPEG audio inside a WAV file (format 0x0050 or
/// 0x0055) is analysed frame by frame like in [mp3Analyze].
Map<String, Object?> wavAnalyze(Uint8List data) {
  final warnings = <String>[];
  final result = <String, Object?>{'fileSize': data.length};

  // ID3v2 in front of the RIFF header (not standard, but exists).
  final leadingId3 = <Map<String, Object?>>[];
  var start = 0;
  try {
    while (start + 10 <= data.length && _mp3StartsWith(data, start, 'ID3')) {
      final tag = _mp3ParseId3v2Tag(data, start, 'in front of the RIFF header (non-standard)');
      if (tag == null) break;
      leadingId3.add(tag);
      final total = (tag['totalSize'] as int?) ?? 0;
      if (total <= 0) break;
      start += total;
    }
  } catch (e) {
    warnings.add('ID3v2 analysis in front of the RIFF header aborted: $e');
  }
  if (leadingId3.isNotEmpty) warnings.add('ID3v2 tag in front of the RIFF header is not standard');

  final containerId = start + 12 <= data.length ? _mp3Latin1(data, start, start + 4) : '';
  if (!const <String>{'RIFF', 'RIFX', 'RF64', 'BW64'}.contains(containerId)) {
    warnings.add('no RIFF/RIFX/RF64/BW64 header found at offset $start');
    result.addAll(<String, Object?>{
      'container': null,
      'format': null,
      'summary': null,
      'chunks': const <Object?>[],
      'tagsFound': <String>[for (final t in leadingId3) '${t['version']}'],
      'id3v2': leadingId3,
      'id3v1': const <Object?>[],
      'warnings': warnings,
    });
    return result;
  }

  final ctx = _WavContext(containerId == 'RIFX', warnings);
  final declaredSize = ctx.u(data, start + 4, 4);
  final formType = _mp3Latin1(data, start + 8, start + 12);
  if (formType != 'WAVE') warnings.add('form type is "$formType", expected "WAVE"');

  var riffSize = declaredSize;
  var sizeSource = 'RIFF header';
  if (declaredSize == 0xFFFFFFFF && start + 28 <= data.length && _mp3StartsWith(data, start + 12, 'ds64')) {
    riffSize = ctx.u64(data, start + 20);
    sizeSource = 'ds64 chunk';
  } else if (containerId == 'RF64' || containerId == 'BW64') {
    if (declaredSize == 0xFFFFFFFF) warnings.add('RF64 container without ds64 chunk');
  }
  var riffEnd = start + 8 + riffSize;
  final container = <String, Object?>{
    'id': containerId,
    'meaning': containerId == 'RIFX'
        ? 'RIFF with big endian byte order'
        : (containerId == 'RIFF' ? 'Resource Interchange File Format' : '$containerId (64-bit extension of RIFF)'),
    'byteOrder': ctx.bigEndian ? 'big endian' : 'little endian',
    'offset': start,
    'headerHex': _mp3Hex(data, start, start + 12),
    'declaredSize': declaredSize,
    if (sizeSource != 'RIFF header') 'size': riffSize,
    'sizeSource': sizeSource,
    'formType': formType,
    'expectedFileEnd': riffEnd,
  };
  if (riffEnd > data.length) {
    warnings.add('file is truncated: RIFF container ends at $riffEnd, file size is ${data.length}');
    container['truncated'] = true;
    riffEnd = data.length;
  }
  result['container'] = container;

  final chunks = _wavParseChunks(data, start + 12, riffEnd, ctx, 0, null);
  result['chunks'] = chunks;

  // Data behind the RIFF container: ID3 tags, further chunks, garbage.
  var pos = riffEnd;
  if (declaredSize.isOdd && pos < data.length && data[pos] == 0) pos++;
  var trailingEnd = data.length;
  final trailingId3v1 = id3v1Analyze(data);
  if (trailingId3v1 != null && data.length - 128 >= pos) {
    trailingEnd = data.length - 128;
    final enhanced = trailingId3v1['enhanced'];
    if (enhanced is Map && (enhanced['offset'] as int) >= pos) trailingEnd = enhanced['offset'] as int;
    trailingId3v1['location'] = 'end of file (behind the RIFF container)';
    ctx.id3v1.add(trailingId3v1);
  }
  try {
    while (pos + 10 <= trailingEnd && _mp3StartsWith(data, pos, 'ID3')) {
      final tag = _mp3ParseId3v2Tag(data, pos, 'behind the RIFF container');
      if (tag == null) break;
      ctx.id3v2.add(tag);
      final total = (tag['totalSize'] as int?) ?? 0;
      if (total <= 0) break;
      pos += total;
    }
  } catch (e) {
    warnings.add('ID3v2 analysis behind the RIFF container aborted: $e');
  }
  if (pos + 8 <= trailingEnd && _wavIsChunkId(data, pos)) {
    warnings.add('chunks found behind the declared end of the RIFF container (RIFF size too small)');
    result['chunksAfterRiff'] = _wavParseChunks(data, pos, trailingEnd, ctx, 0, null);
    pos = trailingEnd;
  }
  if (pos < trailingEnd) {
    final rest = Uint8List.sublistView(data, pos, trailingEnd);
    result['trailingData'] = <String, Object?>{
      'offset': pos,
      'offsetHex': _mp3HexOffset(pos),
      'length': rest.length,
      ..._wavPaddingContent(rest),
    };
    warnings.add('${rest.length} byte(s) of unknown data behind the RIFF container');
  } else {
    result['trailingData'] = null;
  }

  // Audio data (analysed last, so that fmt and fact are known).
  final dataChunk = ctx.dataChunk;
  if (dataChunk != null) {
    try {
      dataChunk['content'] = _wavDataContent(data, ctx.dataStart!, ctx.dataEnd!, ctx);
    } catch (e) {
      final dw = (dataChunk['warnings'] as List<String>?) ?? <String>[];
      dw.add('data analysis failed: $e');
      dataChunk['warnings'] = dw;
    }
  } else {
    warnings.add('no "data" chunk found');
  }
  if (ctx.fmt == null) warnings.add('no "fmt " chunk found');

  final allId3v2 = <Map<String, Object?>>[...leadingId3, ...ctx.id3v2];
  result['format'] = ctx.fmt;
  result['summary'] = _wavSummary(containerId, chunks, ctx);
  result['info'] = ctx.info;
  result['tagsFound'] = <String>[
    for (final t in allId3v2) '${t['version']}',
    for (final t in ctx.id3v1) '${t['version']}',
    if (ctx.info.isNotEmpty) 'RIFF LIST/INFO',
    if (ctx.hasBext) 'BWF bext',
  ];
  result['id3v2'] = allId3v2;
  result['id3v1'] = ctx.id3v1;
  result['warnings'] = warnings;
  return result;
}

// --- chunk walking --------------------------------------------------------------

List<Map<String, Object?>> _wavParseChunks(
    Uint8List d, int start, int end, _WavContext ctx, int depth, String? listType) {
  final chunks = <Map<String, Object?>>[];
  var pos = start;
  while (pos + 8 <= end) {
    if (!_wavIsChunkId(d, pos)) {
      final rest = Uint8List.sublistView(d, pos, end);
      final padding = _wavPaddingContent(rest);
      chunks.add(<String, Object?>{
        'id': null,
        'name': 'unparsed data (no valid chunk ID)',
        'offset': pos,
        'offsetHex': _mp3HexOffset(pos),
        'size': rest.length,
        'content': padding,
      });
      if (padding['allZero'] != true) {
        ctx.warnings.add('chunk parsing stopped at offset $pos: invalid chunk ID '
            '"${_mp3AsciiPreview(Uint8List.sublistView(d, pos, pos + 4))}"');
      }
      return chunks;
    }
    final id = _mp3Latin1(d, pos, pos + 4);
    final w = <String>[];
    final headerSize = ctx.u(d, pos + 4, 4);
    var size = headerSize;
    var sizeSource = 'chunk header';
    final dataStart = pos + 8;

    if (headerSize == 0xFFFFFFFF) {
      final fromDs64 = id == 'data' ? ctx.ds64DataSize : ctx.ds64Table[id];
      if (fromDs64 != null) {
        size = fromDs64;
        sizeSource = 'ds64 chunk';
      }
    }
    if (id == 'data' && depth == 0 && sizeSource == 'chunk header' && (size == 0 || size == 0xFFFFFFFF) &&
        end > dataStart && !(end - dataStart >= 8 && _wavIsChunkId(d, dataStart))) {
      w.add('data chunk size $headerSize is invalid (file was not finalised / streamed), '
          'assuming audio data up to the end of the container');
      size = end - dataStart;
      sizeSource = 'assumed (rest of container)';
    }
    var dataEnd = dataStart + size;
    if (dataEnd > end) {
      w.add('chunk truncated: $size bytes declared, ${end - dataStart} available');
      dataEnd = end;
    }
    var next = dataStart + size;
    var padded = false;
    if (size.isOdd && next < end) {
      if (_wavIsChunkId(d, next) && !_wavIsChunkId(d, next + 1) && next + 8 <= end) {
        w.add('odd chunk size without pad byte (non-conforming writer)');
      } else {
        padded = true;
        if (d[next] != 0) w.add('pad byte is not zero');
        next++;
      }
    }

    final chunk = <String, Object?>{
      'id': id,
      'name': (listType == 'INFO' ? _wavInfoNames[id] : null) ?? _wavChunkNames[id] ?? 'unknown chunk',
      'offset': pos,
      'offsetHex': _mp3HexOffset(pos),
      'headerHex': _mp3Hex(d, pos, pos + 8),
      'size': size,
      if (sizeSource != 'chunk header') 'sizeSource': sizeSource,
      'paddingByte': padded,
      'totalSize': (next > end ? end : next) - pos,
    };
    final body = Uint8List.sublistView(d, dataStart, dataEnd);
    try {
      if (id == 'LIST') {
        final type = body.length >= 4 ? _mp3Latin1(body, 0, 4) : '';
        chunk['content'] = <String, Object?>{
          'listType': type,
          'listTypeName': _wavListTypes[type] ?? 'unknown list type',
        };
        if (depth < 4) chunk['subChunks'] = _wavParseChunks(d, dataStart + 4, dataEnd, ctx, depth + 1, type);
        if (type == 'INFO') {
          final values = <String, Object?>{};
          for (final c in (chunk['subChunks'] as List?) ?? const <Object?>[]) {
            final m = c as Map<String, Object?>;
            final content = m['content'];
            if (m['id'] is String && content is Map && content['text'] is String) {
              values['${m['id']}'] = content['text'];
              if (depth == 0) ctx.info['${m['id']}'] = content['text'] as String;
            }
          }
          (chunk['content'] as Map<String, Object?>)['values'] = values;
        }
      } else if (id == 'data' && depth == 0) {
        if (ctx.dataChunk != null) {
          w.add('more than one data chunk, only the first one is analysed');
          chunk['content'] = <String, Object?>{'hexPreview': _mp3HexPreview(body, 16)};
        } else {
          ctx.dataChunk = chunk;
          ctx.dataStart = dataStart;
          ctx.dataEnd = dataEnd;
          chunk['content'] = null;
        }
      } else {
        chunk['content'] = _wavChunkContent(id, d, dataStart, body, ctx, listType, depth, w);
      }
    } catch (e) {
      w.add('content analysis failed: $e');
      chunk['content'] = _wavGenericContent(body);
    }
    if (w.isNotEmpty) chunk['warnings'] = w;
    chunks.add(chunk);
    pos = next;
  }
  if (pos < end) {
    final rest = Uint8List.sublistView(d, pos, end);
    final padding = _wavPaddingContent(rest);
    chunks.add(<String, Object?>{
      'id': null,
      'name': 'remaining bytes (too short for a chunk header)',
      'offset': pos,
      'offsetHex': _mp3HexOffset(pos),
      'size': rest.length,
      'content': padding,
    });
    if (padding['allZero'] != true) ctx.warnings.add('${rest.length} unparsed byte(s) at offset $pos');
  }
  return chunks;
}

Map<String, Object?> _wavChunkContent(String id, Uint8List file, int fileOffset, Uint8List b, _WavContext ctx,
    String? listType, int depth, List<String> w) {
  if (listType == 'INFO') {
    return <String, Object?>{'text': _wavText(b, 0, b.length)};
  }
  if (listType == 'adtl') {
    switch (id) {
      case 'labl':
      case 'note':
        return <String, Object?>{'cuePointId': ctx.u(b, 0, 4), 'text': _wavText(b, 4, b.length)};
      case 'ltxt':
        final purpose = _mp3Latin1(b, 8, 12);
        return <String, Object?>{
          'cuePointId': ctx.u(b, 0, 4),
          'sampleLength': ctx.u(b, 4, 4),
          'purpose': purpose,
          if (purpose == 'rgn ') 'purposeMeaning': 'region',
          'country': ctx.u(b, 12, 2),
          'language': ctx.u(b, 14, 2),
          'dialect': ctx.u(b, 16, 2),
          'codePage': ctx.u(b, 18, 2),
          'text': _wavText(b, 20, b.length),
        };
      case 'file':
        return <String, Object?>{
          'cuePointId': ctx.u(b, 0, 4),
          'mediaType': _mp3Latin1(b, 4, 8),
          'fileData': _mp3AnalyzeBinaryObject(Uint8List.sublistView(b, 8)),
        };
    }
  }
  switch (id) {
    case 'fmt ':
      if (depth > 0) break;
      if (ctx.fmt != null) w.add('more than one fmt chunk, only the first one is used');
      final fmt = _wavFmtContent(b, ctx, w);
      ctx.fmt ??= fmt;
      return fmt;
    case 'fact':
      final samples = ctx.u(b, 0, 4);
      final out = <String, Object?>{'sampleLength': samples};
      if (samples == 0xFFFFFFFF && ctx.ds64SampleCount != null) {
        out['sampleLength'] = ctx.ds64SampleCount;
        out['sampleLengthSource'] = 'ds64 chunk';
      }
      ctx.factSamples = out['sampleLength'] as int;
      final rate = ctx.sampleRate;
      if (rate != null && rate > 0) out['durationSeconds'] = ctx.factSamples! / rate;
      return out;
    case 'ds64':
      return _wavDs64Content(b, ctx);
    case 'cue ':
      return _wavCueContent(b, ctx);
    case 'plst':
      final count = ctx.u(b, 0, 4);
      return <String, Object?>{
        'segmentCount': count,
        'segments': <Map<String, Object?>>[
          for (var p = 4, i = 0; i < count && p + 12 <= b.length; i++, p += 12)
            <String, Object?>{'cuePointId': ctx.u(b, p, 4), 'lengthSamples': ctx.u(b, p + 4, 4), 'repeats': ctx.u(b, p + 8, 4)},
        ],
      };
    case 'smpl':
      return _wavSmplContent(b, ctx);
    case 'inst':
      return <String, Object?>{
        'unshiftedNote': b[0],
        'fineTuneCents': ctx.s(b, 1, 1),
        'gainDb': ctx.s(b, 2, 1),
        'lowNote': b[3],
        'highNote': b[4],
        'lowVelocity': b[5],
        'highVelocity': b[6],
      };
    case 'acid':
      final flags = ctx.u(b, 0, 4);
      return <String, Object?>{
        'flags': _mp3Bin(flags, 32),
        'oneShot': flags & 0x01 != 0,
        'rootNoteSet': flags & 0x02 != 0,
        'stretch': flags & 0x04 != 0,
        'diskBased': flags & 0x08 != 0,
        'rootNote': ctx.u(b, 4, 2),
        'numberOfBeats': ctx.u(b, 12, 4),
        'meter': '${ctx.u(b, 18, 2)}/${ctx.u(b, 16, 2)}',
        'tempoBpm': _wavRound(ctx.f32(b, 20), 3),
      };
    case 'bext':
      ctx.hasBext = true;
      return _wavBextContent(b, ctx, w);
    case 'cart':
      return _wavCartContent(b, ctx);
    case 'PEAK':
      final channels = (ctx.fmt?['channels'] as int?) ?? ((b.length - 8) ~/ 8);
      return <String, Object?>{
        'version': ctx.u(b, 0, 4),
        'timestamp': ctx.u(b, 4, 4),
        'channels': <Map<String, Object?>>[
          for (var c = 0, p = 8; c < channels && p + 8 <= b.length; c++, p += 8)
            <String, Object?>{
              'channel': c + 1,
              'peak': _wavRound(ctx.f32(b, p), 6),
              'peakDbfs': _wavDb(ctx.f32(b, p).abs()),
              'positionSampleFrame': ctx.u(b, p + 4, 4),
            },
        ],
      };
    case 'iXML':
    case 'axml':
    case '_PMX':
      final text = _wavTextPreview(b);
      final root = RegExp(r'<([A-Za-z_][\w:.-]*)[\s>]').allMatches(text).map((m) => m.group(1)!).firstWhere(
          (n) => !n.startsWith('?') && !n.startsWith('!'),
          orElse: () => '');
      return <String, Object?>{
        'type': 'XML',
        if (root.isNotEmpty) 'rootElement': root,
        'length': b.length,
        'xml': text,
      };
    case 'DISP':
      final type = ctx.u(b, 0, 4);
      return <String, Object?>{
        'clipboardFormat': type,
        'clipboardFormatName': const <int, String>{1: 'CF_TEXT', 2: 'CF_BITMAP', 3: 'CF_METAFILEPICT', 8: 'CF_DIB'}[type] ??
            'unknown',
        if (type == 1) 'text': _wavText(b, 4, b.length) else 'data': _mp3AnalyzeBinaryObject(Uint8List.sublistView(b, 4)),
      };
    case 'afsp':
      return <String, Object?>{
        'identifier': _mp3Latin1(b, 0, 4),
        'values': _mp3ReadStringList(b, 4, 0),
      };
    case 'chna':
      final tracks = ctx.u(b, 0, 2);
      final uids = ctx.u(b, 2, 2);
      return <String, Object?>{
        'numberOfTracks': tracks,
        'numberOfUids': uids,
        'audioIds': <Map<String, Object?>>[
          for (var p = 4, i = 0; i < uids && p + 40 <= b.length; i++, p += 40)
            <String, Object?>{
              'trackIndex': ctx.u(b, p, 2),
              'uid': _mp3Latin1(b, p + 2, p + 14),
              'trackFormatRef': _mp3Latin1(b, p + 14, p + 28),
              'packFormatRef': _mp3Latin1(b, p + 28, p + 39),
            },
        ],
      };
    case 'umid':
      return <String, Object?>{'umid': _mp3Hex(b)};
    case 'MD5 ':
      return <String, Object?>{'md5': _mp3Hex(b).replaceAll(' ', '')};
    case 'JUNK':
    case 'junk':
    case 'PAD ':
    case 'FLLR':
    case 'fllr':
      return _wavPaddingContent(b);
    case 'id3 ':
    case 'ID3 ':
    case 'ID32':
      return _wavId3Content(id, file, fileOffset, b, ctx, w);
  }
  if (b.length >= 10 && _mp3StartsWith(b, 0, 'ID3')) {
    w.add('unknown chunk ID, but the chunk contains an ID3v2 tag');
    return _wavId3Content(id, file, fileOffset, b, ctx, w);
  }
  return _wavGenericContent(b);
}

// --- single chunks --------------------------------------------------------------

Map<String, Object?> _wavFmtContent(Uint8List b, _WavContext ctx, List<String> w) {
  if (b.length < 14) {
    w.add('fmt chunk too short (${b.length} bytes, at least 14 required)');
    return _wavGenericContent(b);
  }
  final tag = ctx.u(b, 0, 2);
  final channels = ctx.u(b, 2, 2);
  final sampleRate = ctx.u(b, 4, 4);
  final byteRate = ctx.u(b, 8, 4);
  final blockAlign = ctx.u(b, 12, 2);
  final bits = b.length >= 16 ? ctx.u(b, 14, 2) : null;
  final out = <String, Object?>{
    'structure': b.length < 16
        ? 'WAVEFORMAT (14 bytes)'
        : (b.length < 18 ? 'PCMWAVEFORMAT (16 bytes)' : 'WAVEFORMATEX (18+ bytes)'),
    'hex': _mp3HexPreview(b, 64),
    'formatTag': tag,
    'formatTagHex': '0x${tag.toRadixString(16).toUpperCase().padLeft(4, '0')}',
    'formatName': _wavFormatTags[tag] ?? 'unknown format',
    'channels': channels,
    'sampleRate': sampleRate,
    'byteRate': byteRate,
    'bitrateKbps': byteRate * 8 / 1000,
    'blockAlign': blockAlign,
    if (bits != null) 'bitsPerSample': bits,
  };
  var effectiveTag = tag;
  int? channelMask;
  if (b.length >= 18) {
    final cbSize = ctx.u(b, 16, 2);
    out['extensionSize'] = cbSize;
    if (18 + cbSize > b.length) w.add('cbSize $cbSize exceeds the fmt chunk');
    final ext = 18;
    if (tag == 0xFFFE) {
      if (cbSize >= 22 && b.length >= 40) {
        final v = ctx.u(b, ext, 2);
        channelMask = ctx.u(b, ext + 2, 4);
        final guid = _wavGuid(b, ext + 6, ctx);
        final standard = guid.endsWith('-0000-0010-8000-00AA00389B71');
        final ambisonic = guid.endsWith('-0721-11D3-8644-C8C1CA000000');
        if (standard || ambisonic) effectiveTag = ctx.u(b, ext + 6, 4);
        out['extensible'] = <String, Object?>{
          'validBitsPerSample': v,
          'samplesPerBlock': v,
          'note': 'the union field is validBitsPerSample for PCM/float, samplesPerBlock for compressed formats',
          'channelMask': _mp3Bin(channelMask, 32),
          'channelMaskHex': '0x${channelMask.toRadixString(16).toUpperCase().padLeft(8, '0')}',
          'speakers': _wavChannelLayout(channels, channelMask),
          'subFormatGuid': guid,
          'subFormat': standard
              ? (_wavFormatTags[effectiveTag] ?? 'unknown format 0x${effectiveTag.toRadixString(16)}')
              : (ambisonic ? 'Ambisonic B-format (${_wavFormatTags[effectiveTag] ?? effectiveTag})' : 'unknown GUID'),
        };
        out['validBitsPerSample'] = v;
        if (bits != null && v > bits) w.add('validBitsPerSample $v is larger than bitsPerSample $bits');
        final setBits = channelMask.toRadixString(2).replaceAll('0', '').length;
        if (channelMask != 0 && channelMask != 0x80000000 && setBits != channels) {
          w.add('channel mask defines $setBits speaker(s), but there are $channels channel(s)');
        }
      } else {
        w.add('WAVE_FORMAT_EXTENSIBLE requires 22 extension bytes');
      }
    } else if (tag == 0x0002 && cbSize >= 4) {
      final numCoef = ctx.u(b, ext + 2, 2);
      out['adpcm'] = <String, Object?>{
        'samplesPerBlock': ctx.u(b, ext, 2),
        'numberOfCoefficients': numCoef,
        'coefficients': <List<int>>[
          for (var i = 0, p = ext + 4; i < numCoef && p + 4 <= b.length; i++, p += 4) <int>[ctx.s(b, p, 2), ctx.s(b, p + 2, 2)],
        ],
      };
    } else if ((tag == 0x0011 || tag == 0x0031) && cbSize >= 2) {
      out['samplesPerBlock'] = ctx.u(b, ext, 2);
    } else if (tag == 0x0055 && cbSize >= 12) {
      final flags = ctx.u(b, ext + 2, 4);
      out['mpegLayer3'] = <String, Object?>{
        'id': ctx.u(b, ext, 2),
        'idMeaning': ctx.u(b, ext, 2) == 1 ? 'MPEGLAYER3_ID_MPEG' : 'unknown',
        'flags': flags,
        'padding': const <int, String>{0: 'ISO (padding as needed)', 1: 'padding always on', 2: 'padding always off'}[flags] ??
            'unknown',
        'blockSize': ctx.u(b, ext + 6, 2),
        'framesPerBlock': ctx.u(b, ext + 8, 2),
        'codecDelay': ctx.u(b, ext + 10, 2),
      };
    } else if (tag == 0x0050 && cbSize >= 22) {
      final layer = ctx.u(b, ext, 2);
      final mode = ctx.u(b, ext + 6, 2);
      out['mpeg1'] = <String, Object?>{
        'headLayer': const <int, String>{1: 'Layer I', 2: 'Layer II', 4: 'Layer III'}[layer] ?? 'unknown ($layer)',
        'headBitrate': ctx.u(b, ext + 2, 4),
        'headMode': const <int, String>{1: 'Stereo', 2: 'Joint stereo', 4: 'Dual channel', 8: 'Single channel'}[mode] ??
            'unknown ($mode)',
        'headModeExtension': ctx.u(b, ext + 8, 2),
        'headEmphasis': ctx.u(b, ext + 10, 2),
        'headFlags': _mp3Bin(ctx.u(b, ext + 12, 2), 16),
        'ptsLow': ctx.u(b, ext + 14, 4),
        'ptsHigh': ctx.u(b, ext + 18, 4),
      };
    } else if (cbSize > 0) {
      out['extensionHex'] = _mp3HexPreview(Uint8List.sublistView(b, ext, ext + cbSize > b.length ? b.length : ext + cbSize));
    }
  }
  out['effectiveFormatTag'] = effectiveTag;
  out['effectiveFormatName'] = _wavFormatTags[effectiveTag] ?? 'unknown format';
  out['channelLayout'] = _wavChannelLayout(channels, channelMask);
  if (channelMask != null) out['channelMask'] = channelMask;

  // Consistency checks.
  if (channels == 0) w.add('number of channels is 0');
  if (sampleRate == 0) w.add('sample rate is 0');
  final isPcm = effectiveTag == 1 || effectiveTag == 3 || effectiveTag == 6 || effectiveTag == 7;
  if (isPcm && bits != null && channels > 0) {
    final expectedAlign = channels * ((bits + 7) ~/ 8);
    if (blockAlign != expectedAlign) {
      w.add('blockAlign $blockAlign does not match channels * bytes per sample ($expectedAlign)');
    }
    if (byteRate != sampleRate * blockAlign) {
      w.add('byteRate $byteRate does not match sampleRate * blockAlign (${sampleRate * blockAlign})');
    }
    if (effectiveTag == 3 && bits != 32 && bits != 64) w.add('IEEE float with $bits bits per sample is unusual');
    if (tag == 1 && (bits > 16 || channels > 2)) {
      w.add('PCM with more than 16 bits or more than 2 channels should use WAVE_FORMAT_EXTENSIBLE');
    }
    if (tag == 1 && bits % 8 != 0) w.add('bitsPerSample $bits is not a multiple of 8');
  }
  return out;
}

Map<String, Object?> _wavDs64Content(Uint8List b, _WavContext ctx) {
  ctx.ds64RiffSize = ctx.u64(b, 0);
  ctx.ds64DataSize = ctx.u64(b, 8);
  ctx.ds64SampleCount = ctx.u64(b, 16);
  final tableLength = b.length >= 28 ? ctx.u(b, 24, 4) : 0;
  final table = <Map<String, Object?>>[];
  for (var i = 0, p = 28; i < tableLength && p + 12 <= b.length; i++, p += 12) {
    final id = _mp3Latin1(b, p, p + 4);
    final size = ctx.u64(b, p + 4);
    ctx.ds64Table[id] = size;
    table.add(<String, Object?>{'chunkId': id, 'size': size});
  }
  return <String, Object?>{
    'riffSize': ctx.ds64RiffSize,
    'dataSize': ctx.ds64DataSize,
    'sampleCount': ctx.ds64SampleCount,
    'tableLength': tableLength,
    'table': table,
  };
}

Map<String, Object?> _wavCueContent(Uint8List b, _WavContext ctx) {
  final count = ctx.u(b, 0, 4);
  final rate = ctx.sampleRate;
  final points = <Map<String, Object?>>[];
  for (var i = 0, p = 4; i < count && p + 24 <= b.length; i++, p += 24) {
    final sampleOffset = ctx.u(b, p + 20, 4);
    points.add(<String, Object?>{
      'id': ctx.u(b, p, 4),
      'position': ctx.u(b, p + 4, 4),
      'dataChunkId': _mp3Latin1(b, p + 8, p + 12),
      'chunkStart': ctx.u(b, p + 12, 4),
      'blockStart': ctx.u(b, p + 16, 4),
      'sampleOffset': sampleOffset,
      if (rate != null && rate > 0) 'time': _mp3FormatDuration(sampleOffset * 1000 / rate),
    });
  }
  return <String, Object?>{'cuePointCount': count, 'cuePoints': points};
}

Map<String, Object?> _wavSmplContent(Uint8List b, _WavContext ctx) {
  const loopTypes = <int, String>{0: 'forward', 1: 'alternating (ping-pong)', 2: 'backward'};
  const smpteFormats = <int, String>{0: 'no SMPTE offset', 24: '24 fps', 25: '25 fps', 29: '30 fps drop frame', 30: '30 fps'};
  final numLoops = ctx.u(b, 28, 4);
  final samplerData = ctx.u(b, 32, 4);
  final period = ctx.u(b, 8, 4);
  final smpte = ctx.u(b, 20, 4);
  final smpteOffset = ctx.u(b, 24, 4);
  final smpteHours = (smpteOffset >> 24) >= 0x80 ? (smpteOffset >> 24) - 0x100 : (smpteOffset >> 24);
  String two(int v) => v.toString().padLeft(2, '0');
  final note = ctx.u(b, 12, 4);
  const names = <String>['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  return <String, Object?>{
    'manufacturer': '0x${ctx.u(b, 0, 4).toRadixString(16).toUpperCase().padLeft(8, '0')}',
    'product': ctx.u(b, 4, 4),
    'samplePeriodNs': period,
    if (period > 0) 'sampleRateFromPeriod': _wavRound(1e9 / period),
    'midiUnityNote': note,
    'midiUnityNoteName': note <= 127 ? '${names[note % 12]}${note ~/ 12 - 1}' : 'invalid',
    'midiPitchFractionCents': _wavRound(ctx.u(b, 16, 4) / 4294967296.0 * 100),
    'smpteFormat': smpteFormats[smpte] ?? 'invalid ($smpte)',
    'smpteOffset': '${smpteHours < 0 ? '-' : ''}${two(smpteHours.abs())}:${two((smpteOffset >> 16) & 0xFF)}:'
        '${two((smpteOffset >> 8) & 0xFF)}:${two(smpteOffset & 0xFF)}',
    'numberOfLoops': numLoops,
    'samplerDataBytes': samplerData,
    'loops': <Map<String, Object?>>[
      for (var i = 0, p = 36; i < numLoops && p + 24 <= b.length; i++, p += 24)
        <String, Object?>{
          'cuePointId': ctx.u(b, p, 4),
          'type': loopTypes[ctx.u(b, p + 4, 4)] ?? 'manufacturer specific (${ctx.u(b, p + 4, 4)})',
          'startSample': ctx.u(b, p + 8, 4),
          'endSample': ctx.u(b, p + 12, 4),
          'fraction': ctx.u(b, p + 16, 4),
          'playCount': ctx.u(b, p + 20, 4) == 0 ? 'infinite' : ctx.u(b, p + 20, 4),
        },
    ],
  };
}

Map<String, Object?> _wavBextContent(Uint8List b, _WavContext ctx, List<String> w) {
  if (b.length < 602) {
    w.add('bext chunk too short (${b.length} bytes, at least 602 required)');
    return _wavGenericContent(b);
  }
  final version = ctx.u(b, 346, 2);
  final timeReference = ctx.u64(b, 338);
  final rate = ctx.sampleRate;
  double? loudness(int o) {
    final v = ctx.s(b, o, 2);
    return v == 0x7FFF ? null : v / 100.0;
  }

  final umid = Uint8List.sublistView(b, 348, 412);
  final umidUsed = umid.any((x) => x != 0);
  return <String, Object?>{
    'description': _wavText(b, 0, 256),
    'originator': _wavText(b, 256, 288),
    'originatorReference': _wavText(b, 288, 320),
    'originationDate': _wavText(b, 320, 330),
    'originationTime': _wavText(b, 330, 338),
    'timeReferenceSamples': timeReference,
    if (rate != null && rate > 0) 'timeReference': _mp3FormatDuration(timeReference * 1000 / rate),
    'version': version,
    'umid': umidUsed ? _mp3Hex(umid).replaceAll(' ', '') : null,
    if (version >= 2) 'loudnessValueLufs': loudness(412),
    if (version >= 2) 'loudnessRangeLu': loudness(414),
    if (version >= 2) 'maxTruePeakLevelDbtp': loudness(416),
    if (version >= 2) 'maxMomentaryLoudnessLufs': loudness(418),
    if (version >= 2) 'maxShortTermLoudnessLufs': loudness(420),
    'codingHistory': _wavText(b, 602, b.length),
  };
}

Map<String, Object?> _wavCartContent(Uint8List b, _WavContext ctx) {
  String t(int s, int e) => _wavText(b, s, e);
  return <String, Object?>{
    'version': t(0, 4),
    'title': t(4, 68),
    'artist': t(68, 132),
    'cutId': t(132, 196),
    'clientId': t(196, 260),
    'category': t(260, 324),
    'classification': t(324, 388),
    'outCue': t(388, 452),
    'startDate': t(452, 462),
    'startTime': t(462, 470),
    'endDate': t(470, 480),
    'endTime': t(480, 488),
    'producerAppId': t(488, 552),
    'producerAppVersion': t(552, 616),
    'userDefined': t(616, 680),
    if (b.length >= 684) 'levelReference': ctx.s(b, 680, 4),
    if (b.length >= 748)
      'postTimers': <Map<String, Object?>>[
        for (var p = 684; p < 748; p += 8)
          if (_mp3Latin1(b, p, p + 4).trim().replaceAll('\u0000', '').isNotEmpty)
            <String, Object?>{'usage': _mp3Latin1(b, p, p + 4), 'value': ctx.u(b, p + 4, 4)},
      ],
    if (b.length >= 2048) 'url': t(1024, 2048),
    if (b.length > 2048) 'tagText': t(2048, b.length),
  };
}

Map<String, Object?> _wavId3Content(
    String id, Uint8List file, int fileOffset, Uint8List b, _WavContext ctx, List<String> w) {
  if (b.length >= 10 && _mp3StartsWith(b, 0, 'ID3')) {
    final tag = _mp3ParseId3v2Tag(b, 0, 'RIFF chunk "$id" at offset $fileOffset');
    if (tag != null) {
      // Offsets inside the tag are relative to the chunk; report file offsets.
      tag['offset'] = fileOffset;
      tag['offsetHex'] = _mp3HexOffset(fileOffset);
      final footer = tag['footer'];
      if (footer is Map<String, Object?> && footer['offset'] is int) {
        footer['offset'] = (footer['offset'] as int) + fileOffset;
      }
      ctx.id3v2.add(tag);
      final total = (tag['totalSize'] as int?) ?? 0;
      if (total > b.length) w.add('ID3 tag ($total bytes) is larger than the chunk (${b.length} bytes)');
      return <String, Object?>{
        'tagType': tag['version'],
        'id3v2Index': ctx.id3v2.length - 1,
        'note': 'the analysed tag is listed in "id3v2"',
        'tagSize': total,
        'frameCount': tag['frameCount'],
        if (total < b.length) 'bytesBehindTag': b.length - total,
      };
    }
  }
  if (b.length >= 128 && _mp3StartsWith(b, 0, 'TAG')) {
    final tag = _mp3ParseId3v1(file, fileOffset);
    tag['location'] = 'RIFF chunk "$id"';
    ctx.id3v1.add(tag);
    return <String, Object?>{
      'tagType': tag['version'],
      'id3v1Index': ctx.id3v1.length - 1,
      'note': 'the analysed tag is listed in "id3v1"',
    };
  }
  w.add('chunk does not contain an ID3 tag');
  return _wavGenericContent(b);
}

// --- audio data -----------------------------------------------------------------

Map<String, Object?> _wavDataContent(Uint8List d, int start, int end, _WavContext ctx) {
  final size = end - start;
  final out = <String, Object?>{
    'dataBytes': size,
    'hexPreview': _mp3HexPreview(Uint8List.sublistView(d, start, end), 16),
  };
  final fmt = ctx.fmt;
  if (fmt == null || fmt['formatTag'] == null) {
    out['note'] = 'no fmt chunk, audio data cannot be interpreted';
    return out;
  }
  final tag = fmt['effectiveFormatTag'] as int;
  final channels = fmt['channels'] as int;
  final sampleRate = fmt['sampleRate'] as int;
  final blockAlign = fmt['blockAlign'] as int;
  final byteRate = fmt['byteRate'] as int;
  final bits = (fmt['bitsPerSample'] as int?) ?? 0;
  final isPcmLike = tag == 1 || tag == 3 || tag == 6 || tag == 7;

  if (blockAlign > 0) {
    out[isPcmLike ? 'sampleFrames' : 'blocks'] = size ~/ blockAlign;
    if (size % blockAlign != 0) {
      out['incompleteBlockBytes'] = size % blockAlign;
      ctx.warnings.add('data size $size is not a multiple of blockAlign $blockAlign');
    }
  }
  double? seconds;
  String? durationSource;
  if (isPcmLike && blockAlign > 0 && sampleRate > 0) {
    seconds = (size ~/ blockAlign) / sampleRate;
    durationSource = 'sample frames / sample rate';
  } else if (ctx.factSamples != null && sampleRate > 0) {
    seconds = ctx.factSamples! / sampleRate;
    durationSource = 'fact chunk';
  } else if (byteRate > 0) {
    seconds = size / byteRate;
    durationSource = 'data bytes / byteRate';
  }
  if (seconds != null) {
    out['durationSeconds'] = seconds;
    out['duration'] = _mp3FormatDuration(seconds * 1000);
    out['durationSource'] = durationSource;
  }
  if (!isPcmLike && ctx.factSamples == null) {
    ctx.warnings.add('compressed format without fact chunk');
  }

  if ((tag == 1 || tag == 3) && channels > 0 && blockAlign > 0 && blockAlign % channels == 0) {
    final stats = _wavStatistics(d, start, end, channels, blockAlign ~/ channels, tag == 3, ctx.bigEndian,
        (fmt['channelLayout'] as List).cast<String>());
    if (stats != null) out['statistics'] = stats;
  } else if (tag == 6 || tag == 7) {
    out['note'] = '${tag == 6 ? 'A-law' : 'µ-law'} encoded, ${bits > 0 ? bits : 8} bits per sample';
  } else if (tag == 0x0050 || tag == 0x0055) {
    out['mpeg'] = _mp3AnalyzeMpegStream(d, start, end);
  }
  return out;
}

Map<String, Object?>? _wavStatistics(Uint8List d, int start, int end, int channels, int bytesPerSample, bool isFloat,
    bool bigEndian, List<String> layout) {
  if (isFloat ? (bytesPerSample != 4 && bytesPerSample != 8) : (bytesPerSample < 1 || bytesPerSample > 4)) return null;
  final frameBytes = channels * bytesPerSample;
  final frames = (end - start) ~/ frameBytes;
  final bd = ByteData.sublistView(d, start, start + frames * frameBytes);
  final endian = bigEndian ? Endian.big : Endian.little;
  final fullScale = isFloat
      ? 1.0
      : (bytesPerSample == 1 ? 128.0 : (bytesPerSample == 2 ? 32768.0 : (bytesPerSample == 3 ? 8388608.0 : 2147483648.0)));
  final mins = List<double>.filled(channels, double.infinity);
  final maxs = List<double>.filled(channels, double.negativeInfinity);
  final sums = List<double>.filled(channels, 0);
  final squares = List<double>.filled(channels, 0);
  final clipped = List<int>.filled(channels, 0);
  var p = 0;
  for (var f = 0; f < frames; f++) {
    for (var c = 0; c < channels; c++) {
      double v;
      switch (bytesPerSample) {
        case 1:
          v = (bd.getUint8(p) - 128).toDouble();
        case 2:
          v = bd.getInt16(p, endian).toDouble();
        case 3:
          var x = bigEndian
              ? (bd.getUint8(p) << 16) | (bd.getUint8(p + 1) << 8) | bd.getUint8(p + 2)
              : (bd.getUint8(p + 2) << 16) | (bd.getUint8(p + 1) << 8) | bd.getUint8(p);
          if (x >= 0x800000) x -= 0x1000000;
          v = x.toDouble();
        case 4:
          v = isFloat ? bd.getFloat32(p, endian) : bd.getInt32(p, endian).toDouble();
        default:
          v = bd.getFloat64(p, endian);
      }
      p += bytesPerSample;
      if (v < mins[c]) mins[c] = v;
      if (v > maxs[c]) maxs[c] = v;
      sums[c] += v;
      squares[c] += v * v;
      if (isFloat ? v.abs() >= 1.0 : (v >= fullScale - 1 || v <= -fullScale)) clipped[c]++;
    }
  }
  if (frames == 0) return <String, Object?>{'sampleFrames': 0, 'channels': const <Object?>[]};
  final perChannel = <Map<String, Object?>>[];
  for (var c = 0; c < channels; c++) {
    final peak = math.max(mins[c].abs(), maxs[c].abs()) / fullScale;
    final rms = math.sqrt(squares[c] / frames) / fullScale;
    perChannel.add(<String, Object?>{
      'channel': c + 1,
      'speaker': c < layout.length ? layout[c] : 'unassigned',
      'minSample': isFloat ? _wavRound(mins[c], 6) : mins[c].toInt(),
      'maxSample': isFloat ? _wavRound(maxs[c], 6) : maxs[c].toInt(),
      'peak': _wavRound(peak, 6),
      'peakDbfs': _wavDb(peak),
      'rmsDbfs': _wavDb(rms),
      'dcOffsetPercent': _wavRound(sums[c] / frames / fullScale * 100, 4),
      'clippedSamples': clipped[c],
      'silent': peak == 0,
    });
  }
  return <String, Object?>{
    'sampleFrames': frames,
    'sampleFormat': isFloat ? '${bytesPerSample * 8} bit float' : '${bytesPerSample * 8} bit ${bytesPerSample == 1 ? 'unsigned' : 'signed'} integer',
    'fullScale': fullScale,
    'channels': perChannel,
  };
}

Map<String, Object?> _wavSummary(String containerId, List<Map<String, Object?>> chunks, _WavContext ctx) {
  final fmt = ctx.fmt;
  final data = ctx.dataChunk?['content'];
  final dataMap = data is Map ? data : const <String, Object?>{};
  return <String, Object?>{
    'container': containerId,
    'format': fmt?['effectiveFormatName'],
    'formatTag': fmt?['formatTagHex'],
    'channels': fmt?['channels'],
    'channelLayout': fmt?['channelLayout'],
    'sampleRateHz': fmt?['sampleRate'],
    'bitsPerSample': fmt?['bitsPerSample'],
    if (fmt?['validBitsPerSample'] != null) 'validBitsPerSample': fmt?['validBitsPerSample'],
    'blockAlign': fmt?['blockAlign'],
    'byteRate': fmt?['byteRate'],
    'bitrateKbps': fmt?['bitrateKbps'],
    'dataBytes': dataMap['dataBytes'],
    'sampleFrames': dataMap['sampleFrames'] ?? ctx.factSamples,
    'durationSeconds': dataMap['durationSeconds'],
    'duration': dataMap['duration'],
    'broadcastWave': ctx.hasBext,
    'chunkIds': <Object?>[for (final c in chunks) c['id']],
  };
}
