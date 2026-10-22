part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// MPEG audio frames
//
// Header (32 bit):  AAAAAAAA AAABBCCD EEEEFFGH IIJJKLMM
//   A sync (11)  B version (2)  C layer (2)  D protection (1)
//   E bitrate index (4)  F sampling rate index (2)  G padding  H private
//   I channel mode (2)  J mode extension (2)  K copyright  L original
//   M emphasis (2)
// ---------------------------------------------------------------------------

const _mp3VersionNames = <String>[
  'MPEG Version 2.5 (unofficial extension)',
  'reserved',
  'MPEG Version 2 (ISO/IEC 13818-3)',
  'MPEG Version 1 (ISO/IEC 11172-3)',
];
const _mp3LayerNames = <String>['reserved', 'Layer III', 'Layer II', 'Layer I'];
const _mp3ChannelModes = <String>[
  'Stereo',
  'Joint stereo',
  'Dual channel (two mono channels)',
  'Single channel (mono)',
];
const _mp3EmphasisNames = <String>['none', '50/15 ms', 'reserved', 'CCIT J.17'];

const _mp3BitratesV1L1 = <int>[0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, -1];
const _mp3BitratesV1L2 = <int>[0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, -1];
const _mp3BitratesV1L3 = <int>[0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, -1];
const _mp3BitratesV2L1 = <int>[0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, -1];
const _mp3BitratesV2L23 = <int>[0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, -1];

/// Indexed by the version bits (0 = 2.5, 1 = reserved, 2 = 2, 3 = 1).
const _mp3SampleRates = <List<int>>[
  [11025, 12000, 8000],
  [0, 0, 0],
  [22050, 24000, 16000],
  [44100, 48000, 32000],
];

class _Mp3FrameHeader {
  final int raw;
  final int versionBits;
  final int layerBits;
  final int protectionBit;
  final int bitrateIndex;
  final int sampleRateIndex;
  final int paddingBit;
  final int privateBit;
  final int channelMode;
  final int modeExtension;
  final int copyright;
  final int original;
  final int emphasis;

  _Mp3FrameHeader._(
      this.raw,
      this.versionBits,
      this.layerBits,
      this.protectionBit,
      this.bitrateIndex,
      this.sampleRateIndex,
      this.paddingBit,
      this.privateBit,
      this.channelMode,
      this.modeExtension,
      this.copyright,
      this.original,
      this.emphasis);

  /// Returns null if there is no valid frame header at [off].
  static _Mp3FrameHeader? tryParse(Uint8List b, int off) {
    if (off < 0 || off + 4 > b.length) return null;
    final b1 = b[off + 1];
    final b2 = b[off + 2];
    final b3 = b[off + 3];
    if (b[off] != 0xFF || (b1 & 0xE0) != 0xE0) return null;
    final version = (b1 >> 3) & 0x03;
    final layer = (b1 >> 1) & 0x03;
    final bitrateIndex = (b2 >> 4) & 0x0F;
    final sampleRateIndex = (b2 >> 2) & 0x03;
    final emphasis = b3 & 0x03;
    if (version == 1 || layer == 0 || bitrateIndex == 0x0F || sampleRateIndex == 3 || emphasis == 2) {
      return null;
    }
    return _Mp3FrameHeader._(_mp3UInt(b, off, 4), version, layer, b1 & 0x01, bitrateIndex,
        sampleRateIndex, (b2 >> 1) & 0x01, b2 & 0x01, (b3 >> 6) & 0x03, (b3 >> 4) & 0x03,
        (b3 >> 3) & 0x01, (b3 >> 2) & 0x01, emphasis);
  }

  bool get isMpeg1 => versionBits == 3;

  String get versionShort => versionBits == 3 ? 'MPEG-1' : (versionBits == 2 ? 'MPEG-2' : 'MPEG-2.5');

  String get layerShort => layerBits == 3 ? 'Layer I' : (layerBits == 2 ? 'Layer II' : 'Layer III');

  int get bitrateKbps {
    final List<int> table;
    if (layerBits == 3) {
      table = isMpeg1 ? _mp3BitratesV1L1 : _mp3BitratesV2L1;
    } else if (layerBits == 2) {
      table = isMpeg1 ? _mp3BitratesV1L2 : _mp3BitratesV2L23;
    } else {
      table = isMpeg1 ? _mp3BitratesV1L3 : _mp3BitratesV2L23;
    }
    return table[bitrateIndex];
  }

  int get sampleRate => _mp3SampleRates[versionBits][sampleRateIndex];

  int get samplesPerFrame => layerBits == 3 ? 384 : ((layerBits == 2 || isMpeg1) ? 1152 : 576);

  /// Size of a slot: 4 bytes for Layer I, 1 byte for Layer II/III.
  int get slotBytes => layerBits == 3 ? 4 : 1;

  int get crcBytes => protectionBit == 0 ? 2 : 0;

  bool get isMono => channelMode == 3;

  /// Size of the Layer III side information.
  int get sideInfoBytes {
    if (layerBits != 1) return 0;
    if (isMpeg1) return isMono ? 17 : 32;
    return isMono ? 9 : 17;
  }

  /// Frame length in bytes including the header; 0 for free format.
  int get frameLength {
    final br = bitrateKbps * 1000;
    if (br <= 0) return 0;
    if (layerBits == 3) return (12 * br ~/ sampleRate + paddingBit) * 4;
    final coefficient = (layerBits == 1 && !isMpeg1) ? 72 : 144;
    return coefficient * br ~/ sampleRate + paddingBit;
  }

  bool compatibleWith(_Mp3FrameHeader o) =>
      versionBits == o.versionBits && layerBits == o.layerBits && sampleRateIndex == o.sampleRateIndex;

  String get modeExtensionMeaning {
    if (channelMode != 1) return 'not used (only relevant for joint stereo)';
    if (layerBits == 1) {
      const l3 = <String>[
        'intensity stereo off, M/S stereo off',
        'intensity stereo on, M/S stereo off',
        'intensity stereo off, M/S stereo on',
        'intensity stereo on, M/S stereo on',
      ];
      return l3[modeExtension];
    }
    const l12 = <String>['bands 4 to 31', 'bands 8 to 31', 'bands 12 to 31', 'bands 16 to 31'];
    return '${l12[modeExtension]} in intensity stereo';
  }

  String get bitString {
    final s = _mp3Bin(raw, 32);
    return '${s.substring(0, 8)} ${s.substring(8, 16)} ${s.substring(16, 24)} ${s.substring(24, 32)}';
  }

  List<Map<String, Object?>> fields() {
    final bits = _mp3Bin(raw, 32);
    Map<String, Object?> f(String letter, String name, int from, int len, String meaning) {
      final slice = bits.substring(from, from + len);
      return <String, Object?>{
        'letter': letter,
        'field': name,
        'bitPosition': len == 1 ? '$from' : '$from-${from + len - 1}',
        'bits': slice,
        'value': int.parse(slice, radix: 2),
        'meaning': meaning,
      };
    }

    final br = bitrateKbps;
    return <Map<String, Object?>>[
      f('A', 'Frame sync', 0, 11, 'all 11 bits set'),
      f('B', 'MPEG audio version ID', 11, 2, _mp3VersionNames[versionBits]),
      f('C', 'Layer description', 13, 2, _mp3LayerNames[layerBits]),
      f('D', 'Protection bit', 15, 1,
          protectionBit == 0 ? 'protected by CRC (16 bit CRC follows the header)' : 'not protected'),
      f('E', 'Bitrate index', 16, 4, br == 0 ? 'free format' : '$br kbps'),
      f('F', 'Sampling rate frequency index', 20, 2, '$sampleRate Hz'),
      f('G', 'Padding bit', 22, 1,
          paddingBit == 1 ? 'frame is padded with one extra slot ($slotBytes byte(s))' : 'frame is not padded'),
      f('H', 'Private bit', 23, 1, 'free for application specific use'),
      f('I', 'Channel mode', 24, 2, _mp3ChannelModes[channelMode]),
      f('J', 'Mode extension', 26, 2, modeExtensionMeaning),
      f('K', 'Copyright', 28, 1, copyright == 1 ? 'audio is copyrighted' : 'audio is not copyrighted'),
      f('L', 'Original', 29, 1, original == 1 ? 'original media' : 'copy of original media'),
      f('M', 'Emphasis', 30, 2, _mp3EmphasisNames[emphasis]),
    ];
  }
}

/// Free format: the frame ends where the next compatible header starts.
int _mp3FreeFormatLength(Uint8List d, int pos, int end, _Mp3FrameHeader h) {
  final limit = pos + 8192 < end ? pos + 8192 : end;
  for (var p = pos + 4 + h.crcBytes + h.sideInfoBytes; p + 4 <= limit; p++) {
    final n = _Mp3FrameHeader.tryParse(d, p);
    if (n != null && n.bitrateIndex == 0 && n.compatibleWith(h)) return p - pos;
  }
  return end - pos;
}

Map<String, Object?>? _mp3ReplayGain(int v) {
  if (v == 0) return null;
  const names = <String>['not set', 'radio (track)', 'audiophile (album)'];
  const originators = <String>[
    'not set',
    'set by artist',
    'set by user',
    'set by automatic analysis',
  ];
  final name = (v >> 13) & 7;
  final originator = (v >> 10) & 7;
  final value = (v & 0x1FF) / 10.0;
  return <String, Object?>{
    'raw': _mp3Bin(v, 16),
    'name': name < names.length ? names[name] : 'reserved',
    'originator': originator < originators.length ? originators[originator] : 'reserved',
    'gainDb': (v & 0x200) != 0 ? -value : value,
  };
}

Map<String, Object?>? _mp3ParseLameTag(Uint8List d, int p) {
  for (var i = 0; i < 9; i++) {
    final c = d[p + i];
    if (c != 0 && (c < 0x20 || c > 0x7E)) return null;
  }
  final encoder = String.fromCharCodes(d, p, p + 9).replaceAll('\u0000', '').trim();
  if (encoder.isEmpty) return null;
  const vbrMethods = <int, String>{
    0: 'unknown',
    1: 'constant bitrate (CBR)',
    2: 'average bitrate (ABR)',
    3: 'variable bitrate, method 1 (--vbr-old / --vbr-rh)',
    4: 'variable bitrate, method 2 (--vbr-mtrh)',
    5: 'variable bitrate, method 3 (--vbr-mt)',
    6: 'variable bitrate, method 4',
    8: 'constant bitrate, 2 pass',
    9: 'average bitrate, 2 pass',
    15: 'reserved',
  };
  const stereoModes = <String>['Mono', 'Stereo', 'Dual', 'Joint', 'Force', 'Auto', 'Intensity', 'undefined'];
  const sourceRates = <String>['32 kHz or less', '44.1 kHz', '48 kHz', 'higher than 48 kHz'];
  final revMethod = d[p + 9];
  final peak = ByteData.sublistView(d, p + 11, p + 15).getFloat32(0, Endian.big);
  final flagsAth = d[p + 19];
  final delayPadding = _mp3UInt(d, p + 21, 3);
  final misc = d[p + 24];
  final gain = d[p + 25];
  final presetSurround = _mp3UInt(d, p + 26, 2);
  return <String, Object?>{
    'hex': _mp3Hex(d, p, p + 36),
    'encoder': encoder,
    'tagRevision': revMethod >> 4,
    'vbrMethod': vbrMethods[revMethod & 0x0F] ?? 'undefined (${revMethod & 0x0F})',
    'lowpassHz': d[p + 10] * 100,
    'peakSignalAmplitude': peak.isFinite ? peak : null,
    'radioReplayGain': _mp3ReplayGain(_mp3UInt(d, p + 15, 2)),
    'audiophileReplayGain': _mp3ReplayGain(_mp3UInt(d, p + 17, 2)),
    'encodingFlags': <String, Object?>{
      'nspsytune': (flagsAth & 0x10) != 0,
      'nssafejoint': (flagsAth & 0x20) != 0,
      'nogapContinuedByNext': (flagsAth & 0x40) != 0,
      'nogapContinuationOfPrevious': (flagsAth & 0x80) != 0,
    },
    'athType': flagsAth & 0x0F,
    'bitrateKbps': d[p + 20],
    'encoderDelaySamples': delayPadding >> 12,
    'paddingSamples': delayPadding & 0xFFF,
    'noiseShaping': misc & 0x03,
    'stereoMode': stereoModes[(misc >> 2) & 0x07],
    'unwiseSettings': (misc & 0x20) != 0,
    'sourceSampleRate': sourceRates[(misc >> 6) & 0x03],
    'mp3GainDb': (gain >= 128 ? gain - 256 : gain) * 1.5,
    'surroundInfo': (presetSurround >> 11) & 0x07,
    'preset': presetSurround & 0x7FF,
    'musicLengthBytes': _mp3UInt(d, p + 28, 4),
    'musicCrc': _mp3Hex(d, p + 32, p + 34),
    'infoTagCrc': _mp3Hex(d, p + 34, p + 36),
  };
}

/// Xing / Info (+ LAME) or VBRI header inside the first frame.
Map<String, Object?>? _mp3ParseVbrHeader(Uint8List d, int pos, int available, _Mp3FrameHeader h) {
  final frameEnd = pos + available;
  final xing = pos + 4 + h.crcBytes + h.sideInfoBytes;
  if (xing + 8 <= frameEnd && (_mp3StartsWith(d, xing, 'Xing') || _mp3StartsWith(d, xing, 'Info'))) {
    final id = _mp3Latin1(d, xing, xing + 4);
    final flags = _mp3UInt(d, xing + 4, 4);
    final out = <String, Object?>{
      'type': id,
      'meaning': id == 'Xing'
          ? 'Xing header (variable bitrate info, frame contains no audio)'
          : 'Info header (constant bitrate info, frame contains no audio)',
      'offsetInFrame': xing - pos,
      'flags': _mp3Bin(flags, 32),
      'fieldsPresent': <String>[
        if ((flags & 1) != 0) 'frames',
        if ((flags & 2) != 0) 'bytes',
        if ((flags & 4) != 0) 'toc',
        if ((flags & 8) != 0) 'quality',
      ],
    };
    var p = xing + 8;
    if ((flags & 1) != 0 && p + 4 <= frameEnd) {
      out['frames'] = _mp3UInt(d, p, 4);
      p += 4;
    }
    if ((flags & 2) != 0 && p + 4 <= frameEnd) {
      out['bytes'] = _mp3UInt(d, p, 4);
      p += 4;
    }
    if ((flags & 4) != 0 && p + 100 <= frameEnd) {
      out['toc'] = List<int>.of(Uint8List.sublistView(d, p, p + 100));
      p += 100;
    }
    if ((flags & 8) != 0 && p + 4 <= frameEnd) {
      out['quality'] = _mp3UInt(d, p, 4);
      p += 4;
    }
    if (p + 36 <= frameEnd) {
      final lame = _mp3ParseLameTag(d, p);
      if (lame != null) out['lameTag'] = lame;
    }
    return out;
  }
  final vbri = pos + 4 + 32;
  if (vbri + 26 <= frameEnd && _mp3StartsWith(d, vbri, 'VBRI')) {
    return <String, Object?>{
      'type': 'VBRI',
      'meaning': 'Fraunhofer VBRI header (frame contains no audio)',
      'offsetInFrame': 36,
      'version': _mp3UInt(d, vbri + 4, 2),
      'delayRaw': _mp3UInt(d, vbri + 6, 2),
      'quality': _mp3UInt(d, vbri + 8, 2),
      'bytes': _mp3UInt(d, vbri + 10, 4),
      'frames': _mp3UInt(d, vbri + 14, 4),
      'tocEntries': _mp3UInt(d, vbri + 18, 2),
      'tocScaleFactor': _mp3UInt(d, vbri + 20, 2),
      'tocEntrySize': _mp3UInt(d, vbri + 22, 2),
      'framesPerTocEntry': _mp3UInt(d, vbri + 24, 2),
    };
  }
  return null;
}

Map<String, Object?> _mp3AnalyzeMpegStream(Uint8List data, int start, int end) {
  final frames = <Map<String, Object?>>[];
  final unrecognized = <Map<String, Object?>>[];
  final bitrateCounts = <String, int>{};
  final versions = <String>{};
  final layers = <String>{};
  final sampleRates = <int>{};
  final channelModes = <String>{};
  var totalSamples = 0;
  var durationSeconds = 0.0;
  var audioFrameBytes = 0;
  var totalFrameBytes = 0;
  var totalDataBytes = 0;
  var unrecognizedBytes = 0;
  var truncatedFrames = 0;
  Map<String, Object?>? vbrHeader;
  int? junkStart;
  _Mp3FrameHeader? reference;
  var needConfirm = true;
  var pos = start;

  void flushJunk(int upTo) {
    final js = junkStart;
    if (js == null || upTo <= js) {
      junkStart = null;
      return;
    }
    var allZero = true;
    for (var i = js; i < upTo; i++) {
      if (data[i] != 0) {
        allZero = false;
        break;
      }
    }
    unrecognized.add(<String, Object?>{
      'offset': js,
      'offsetHex': _mp3HexOffset(js),
      'length': upTo - js,
      'allZero': allZero,
      'hexPreview': _mp3HexPreview(Uint8List.sublistView(data, js, upTo), 16),
    });
    unrecognizedBytes += upTo - js;
    junkStart = null;
  }

  while (pos + 4 <= end) {
    final h = _Mp3FrameHeader.tryParse(data, pos);
    var ok = h != null;
    var length = 0;
    var freeFormat = false;
    if (h != null) {
      length = h.frameLength;
      if (length == 0) {
        freeFormat = true;
        length = _mp3FreeFormatLength(data, pos, end, h);
      }
      if (length < 4 + h.crcBytes + h.sideInfoBytes) ok = false;
      final ref = reference;
      // After junk, at the start, or when the format changes, the next
      // header must confirm the frame (protects against false syncs).
      if (ok && (needConfirm || ref == null || !h.compatibleWith(ref))) {
        final next = pos + length;
        if (next + 4 <= end) {
          final h2 = _Mp3FrameHeader.tryParse(data, next);
          ok = h2 != null && h2.compatibleWith(h);
        } else {
          ok = next <= end && (ref == null || h.compatibleWith(ref));
        }
      }
    }
    if (h == null || !ok) {
      junkStart ??= pos;
      needConfirm = true;
      pos++;
      continue;
    }
    flushJunk(pos);

    final truncated = pos + length > end;
    final available = truncated ? end - pos : length;
    final crcBytes = h.crcBytes;
    final sideInfo = h.sideInfoBytes;
    final warnings = <String>[];
    final frame = <String, Object?>{
      'index': frames.length,
      'offset': pos,
      'offsetHex': _mp3HexOffset(pos),
      'header': <String, Object?>{
        'hex': _mp3Hex(data, pos, pos + 4),
        'bits': h.bitString,
        'fields': h.fields(),
      },
      'mpegVersion': h.versionShort,
      'layer': h.layerShort,
      'crcProtected': h.protectionBit == 0,
      'bitrateKbps': freeFormat ? null : h.bitrateKbps,
      'freeFormat': freeFormat,
      'samplingRateHz': h.sampleRate,
      'padding': h.paddingBit == 1,
      'privateBit': h.privateBit,
      'channelMode': _mp3ChannelModes[h.channelMode],
      'modeExtension': h.modeExtensionMeaning,
      'copyright': h.copyright == 1,
      'original': h.original == 1,
      'emphasis': _mp3EmphasisNames[h.emphasis],
      'samplesPerFrame': h.samplesPerFrame,
      'durationMs': h.samplesPerFrame * 1000 / h.sampleRate,
      'frameLength': length,
      'headerBytes': 4,
      'crcBytes': crcBytes,
      'sideInfoBytes': sideInfo,
      'dataBytes': length - 4 - crcBytes,
      if (h.layerBits == 1) 'mainDataBytes': length - 4 - crcBytes - sideInfo,
    };
    if (crcBytes == 2 && pos + 6 <= end) frame['crc'] = _mp3Hex(data, pos + 4, pos + 6);
    if (h.layerBits == 1 && pos + 4 + crcBytes + 2 <= end) {
      final s = pos + 4 + crcBytes;
      // main_data_begin: negative offset (bytes) into the bit reservoir
      frame['mainDataBegin'] = h.isMpeg1 ? ((data[s] << 1) | (data[s + 1] >> 7)) : data[s];
    }
    if (truncated) {
      frame['truncated'] = true;
      frame['availableBytes'] = available;
      warnings.add('frame truncated: $length bytes expected, $available available');
      truncatedFrames++;
    }
    if (h.layerBits == 2 && h.isMpeg1 && !freeFormat) {
      final br = h.bitrateKbps;
      if (h.isMono && br >= 224) warnings.add('Layer II: $br kbps is not allowed for single channel');
      if (!h.isMono && (br == 32 || br == 48 || br == 56 || br == 80)) {
        warnings.add('Layer II: $br kbps is only allowed for single channel');
      }
    }
    var isInfoFrame = false;
    if (frames.isEmpty) {
      final vbr = _mp3ParseVbrHeader(data, pos, available, h);
      if (vbr != null) {
        frame['vbrHeader'] = vbr;
        vbrHeader = vbr;
        isInfoFrame = true;
      }
    }
    if (warnings.isNotEmpty) frame['warnings'] = warnings;
    frames.add(frame);

    totalFrameBytes += available;
    totalDataBytes += length - 4 - crcBytes;
    versions.add(h.versionShort);
    layers.add(h.layerShort);
    sampleRates.add(h.sampleRate);
    channelModes.add(_mp3ChannelModes[h.channelMode]);
    if (!isInfoFrame) {
      final key = freeFormat ? 'free' : '${h.bitrateKbps}';
      bitrateCounts[key] = (bitrateCounts[key] ?? 0) + 1;
      totalSamples += h.samplesPerFrame;
      durationSeconds += h.samplesPerFrame / h.sampleRate;
      audioFrameBytes += available;
    }

    reference = h;
    needConfirm = false;
    pos += length;
  }
  if (pos < end) junkStart ??= pos;
  flushJunk(end);

  final audioFrameCount = frames.length - (vbrHeader != null ? 1 : 0);
  final summary = <String, Object?>{
    'frameCount': frames.length,
    'audioFrameCount': audioFrameCount,
    'firstFrameOffset': frames.isEmpty ? null : frames.first['offset'],
    'mpegVersions': versions.toList(),
    'layers': layers.toList(),
    'samplingRatesHz': sampleRates.toList(),
    'channelModes': channelModes.toList(),
    'bitrateDistributionKbps': bitrateCounts,
    'bitrateMode': bitrateCounts.isEmpty ? null : (bitrateCounts.length > 1 ? 'VBR' : 'CBR'),
    'totalSamples': totalSamples,
    'durationSeconds': durationSeconds,
    'duration': _mp3FormatDuration(durationSeconds * 1000),
    'averageBitrateKbps': durationSeconds > 0 ? audioFrameBytes * 8 / durationSeconds / 1000 : null,
    'totalFrameBytes': totalFrameBytes,
    'totalDataBytes': totalDataBytes,
    'truncatedFrames': truncatedFrames,
    'unrecognizedRanges': unrecognized.length,
    'unrecognizedBytes': unrecognizedBytes,
  };
  final lame = vbrHeader?['lameTag'];
  if (lame is Map<String, Object?> && sampleRates.length == 1) {
    final delay = (lame['encoderDelaySamples'] as int?) ?? 0;
    final padding = (lame['paddingSamples'] as int?) ?? 0;
    final playable = totalSamples - delay - padding;
    if (playable > 0) {
      summary['playbackSamples'] = playable;
      summary['playbackDurationSeconds'] = playable / sampleRates.first;
    }
  }
  if (vbrHeader != null) {
    final declaredFrames = vbrHeader['frames'];
    if (declaredFrames is int) summary['vbrHeaderFrames'] = declaredFrames;
  }

  return <String, Object?>{
    'audioStart': start,
    'audioEnd': end,
    'summary': summary,
    'frames': frames,
    'unrecognizedRanges': unrecognized,
  };
}
