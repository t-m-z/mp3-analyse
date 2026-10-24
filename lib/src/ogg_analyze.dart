part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// Ogg container (RFC 3533) and Vorbis I analysis.
//
// * every Ogg page: header fields, header type flags, granule position,
//   serial number, sequence number, CRC check, lacing values, packets
// * logical streams (grouped / chained), packet reassembly across pages
// * Vorbis: identification, comment (incl. METADATA_BLOCK_PICTURE) and
//   setup header (codebooks, floors, residues, mappings, modes); every audio
//   packet with mode, block size, window flags and decoded sample count;
//   granule position check, duration and bitrate
// * also recognised: Opus, FLAC, Speex, Theora, Skeleton
// * ID3v2 in front of / ID3v1, APE, Lyrics3 behind the Ogg data
// ---------------------------------------------------------------------------

class _OggEndOfPacket implements Exception {
  @override
  String toString() => 'end of packet reached';
}

/// Vorbis bit packing: LSB first.
class _OggBits {
  final Uint8List d;
  int pos;
  int bit = 0;

  _OggBits(this.d, this.pos);

  int read(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      if (pos >= d.length) throw _OggEndOfPacket();
      if ((d[pos] >> bit) & 1 == 1) v += 1 << i;
      bit++;
      if (bit == 8) {
        bit = 0;
        pos++;
      }
    }
    return v;
  }

  void skip(int bits) {
    final total = bit + bits;
    pos += total ~/ 8;
    bit = total % 8;
    if (pos > d.length || (pos == d.length && bit > 0)) throw _OggEndOfPacket();
  }

  int get bitsRead => pos * 8 + bit;
}

class _OggStream {
  final int serial;
  final int firstPageIndex;
  final int firstPageOffset;
  String codec = 'unknown';
  String codecName = 'unknown codec';
  bool bos = false;
  bool eos = false;
  int pageCount = 0;
  int bytes = 0;
  int? lastSequence;
  int lostPages = 0;
  int? firstGranule;
  int? lastGranule;
  final List<int> partial = <int>[];
  int? partialStartPage;
  final List<Map<String, Object?>> packets = <Map<String, Object?>>[];
  final Map<String, Object?> headers = <String, Object?>{};
  final List<String> warnings = <String>[];
  Map<String, Object?>? comments;

  // decoding state
  int headerPackets = 3;
  int? sampleRate;
  int? blockSize0;
  int? blockSize1;
  List<int>? modeBlockFlags;
  int? previousBlock;
  int samples = 0;
  bool samplesKnown = false;
  int? granuleOffset;
  int? trimmedAtEnd;
  int granuleMismatches = 0;
  int preSkip = 0;
  int? speexFrameSize;
  int? speexFramesPerPacket;
  int? theoraShift;
  int? theoraFpsNum;
  int? theoraFpsDen;

  // audio packet statistics
  int audioPackets = 0;
  int audioBytes = 0;
  int? minPacket;
  int? maxPacket;
  int shortBlocks = 0;
  int longBlocks = 0;
  int keyFrames = 0;

  _OggStream(this.serial, this.firstPageIndex, this.firstPageOffset);
}

// --- helpers ------------------------------------------------------------------

final List<int> _oggCrcTable = () {
  final t = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var r = (i << 24) & 0xFFFFFFFF;
    for (var k = 0; k < 8; k++) {
      r = (r & 0x80000000) != 0 ? (((r << 1) & 0xFFFFFFFF) ^ 0x04C11DB7) : ((r << 1) & 0xFFFFFFFF);
    }
    t[i] = r;
  }
  return t;
}();

/// Ogg CRC-32 (polynomial 0x04C11DB7, not reflected, init 0); the CRC field
/// at [crcOffset] is treated as zero.
int _oggCrc(Uint8List d, int start, int end, int crcOffset) {
  var crc = 0;
  for (var i = start; i < end; i++) {
    final b = (i >= crcOffset && i < crcOffset + 4) ? 0 : d[i];
    crc = (((crc << 8) & 0xFFFFFFFF) ^ _oggCrcTable[((crc >> 24) ^ b) & 0xFF]) & 0xFFFFFFFF;
  }
  return crc;
}

/// Signed 64 bit little endian (exact up to 2^53 on the web).
int _oggInt64(Uint8List d, int o) {
  final lo = _mp3UIntLE(d, o, 4);
  final hi = _mp3UIntLE(d, o + 4, 4);
  if (hi >= 0x80000000) return (hi - 0x100000000) * 0x100000000 + lo;
  return hi * 0x100000000 + lo;
}

int _oggInt32(Uint8List d, int o) {
  final v = _mp3UIntLE(d, o, 4);
  return v >= 0x80000000 ? v - 0x100000000 : v;
}

int _oggIlog(int v) {
  var r = 0;
  while (v > 0) {
    r++;
    v >>= 1;
  }
  return r;
}

double _oggFloat32Unpack(int x) {
  final mantissa = x & 0x1FFFFF;
  final sign = x & 0x80000000;
  final exponent = (x & 0x7FE00000) >> 21;
  return (sign != 0 ? -mantissa : mantissa) * math.pow(2, exponent - 788).toDouble();
}

int _oggLookup1Values(int entries, int dimensions) {
  if (dimensions <= 0 || entries <= 0) return 0;
  var r = math.pow(entries, 1 / dimensions).floor();
  while (math.pow(r + 1, dimensions) <= entries) {
    r++;
  }
  while (r > 0 && math.pow(r, dimensions) > entries) {
    r--;
  }
  return r;
}

String _oggUtf8(Uint8List d, int start, int end) {
  if (end > d.length) end = d.length;
  if (start >= end) return '';
  return utf8.decode(Uint8List.sublistView(d, start, end), allowMalformed: true);
}

// --- comments (Vorbis comment format, shared by Vorbis/Opus/FLAC/Speex/Theora)

const _oggCommentFields = <String, String>{
  'TITLE': 'Track / work name',
  'VERSION': 'Version of the track (e.g. remix info)',
  'ALBUM': 'Album / collection name',
  'TRACKNUMBER': 'Track number',
  'TRACKTOTAL': 'Total number of tracks',
  'TOTALTRACKS': 'Total number of tracks',
  'DISCNUMBER': 'Disc number',
  'DISCTOTAL': 'Total number of discs',
  'ARTIST': 'Artist',
  'ALBUMARTIST': 'Album artist',
  'PERFORMER': 'Performer',
  'COMPOSER': 'Composer',
  'CONDUCTOR': 'Conductor',
  'COPYRIGHT': 'Copyright',
  'LICENSE': 'License',
  'ORGANIZATION': 'Organization / label',
  'DESCRIPTION': 'Description',
  'COMMENT': 'Comment',
  'GENRE': 'Genre',
  'DATE': 'Date',
  'LOCATION': 'Recording location',
  'CONTACT': 'Contact information',
  'ISRC': 'International Standard Recording Code',
  'ENCODER': 'Encoder software',
  'ENCODED_BY': 'Encoded by',
  'LYRICS': 'Lyrics',
  'LANGUAGE': 'Language',
  'BPM': 'Beats per minute',
  'REPLAYGAIN_TRACK_GAIN': 'ReplayGain track gain',
  'REPLAYGAIN_TRACK_PEAK': 'ReplayGain track peak',
  'REPLAYGAIN_ALBUM_GAIN': 'ReplayGain album gain',
  'REPLAYGAIN_ALBUM_PEAK': 'ReplayGain album peak',
  'R128_TRACK_GAIN': 'EBU R128 track gain (Q7.8 dB, Opus)',
  'R128_ALBUM_GAIN': 'EBU R128 album gain (Q7.8 dB, Opus)',
  'METADATA_BLOCK_PICTURE': 'Embedded picture (base64 encoded FLAC picture block)',
  'COVERART': 'Embedded picture (legacy, base64 encoded image)',
  'COVERARTMIME': 'MIME type of COVERART (legacy)',
  'MUSICBRAINZ_TRACKID': 'MusicBrainz recording ID',
  'MUSICBRAINZ_ALBUMID': 'MusicBrainz release ID',
  'MUSICBRAINZ_ARTISTID': 'MusicBrainz artist ID',
  'WAVEFORMATEXTENSIBLE_CHANNEL_MASK': 'Channel mask (FLAC)',
};

/// FLAC PICTURE block (big endian), also used by METADATA_BLOCK_PICTURE.
Map<String, Object?> _oggPictureBlock(Uint8List b) {
  final type = _mp3UInt(b, 0, 4);
  final mimeLength = _mp3UInt(b, 4, 4);
  var p = 8;
  final mime = _mp3Latin1(b, p, p + mimeLength);
  p += mimeLength;
  final descriptionLength = _mp3UInt(b, p, 4);
  p += 4;
  final description = _oggUtf8(b, p, p + descriptionLength);
  p += descriptionLength;
  final out = <String, Object?>{
    'pictureType': <String, Object?>{
      'value': type,
      'name': type < _mp3PictureTypes.length ? _mp3PictureTypes[type] : 'undefined',
    },
    'mimeType': mime,
    'description': description,
    'width': _mp3UInt(b, p, 4),
    'height': _mp3UInt(b, p + 4, 4),
    'colorDepth': _mp3UInt(b, p + 8, 4),
    'indexedColors': _mp3UInt(b, p + 12, 4),
  };
  final length = _mp3UInt(b, p + 16, 4);
  p += 20;
  final end = p + length > b.length ? b.length : p + length;
  out['dataLength'] = length;
  out['picture'] = _mp3AnalyzeBinaryObject(Uint8List.sublistView(b, p, end));
  return out;
}

Map<String, Object?> _oggComments(Uint8List d, int start, List<String> w, {bool framing = false}) {
  var p = start;
  final vendorLength = _mp3UIntLE(d, p, 4);
  p += 4;
  final vendor = _oggUtf8(d, p, p + vendorLength);
  p += vendorLength;
  final count = _mp3UIntLE(d, p, 4);
  p += 4;
  final comments = <Map<String, Object?>>[];
  final values = <String, List<String>>{};
  for (var i = 0; i < count; i++) {
    if (p + 4 > d.length) {
      w.add('comment list truncated: $count comments declared, $i found');
      break;
    }
    final length = _mp3UIntLE(d, p, 4);
    p += 4;
    if (p + length > d.length) {
      w.add('comment $i is truncated');
      break;
    }
    final text = _oggUtf8(d, p, p + length);
    p += length;
    final eq = text.indexOf('=');
    final field = eq < 0 ? text : text.substring(0, eq);
    final upper = field.toUpperCase();
    final value = eq < 0 ? '' : text.substring(eq + 1);
    final entry = <String, Object?>{
      'index': i,
      'length': length,
      'field': field,
      if (_oggCommentFields[upper] != null) 'description': _oggCommentFields[upper],
    };
    if (eq < 0) {
      w.add('comment $i has no "=" separator');
    }
    final invalidName = field.codeUnits.any((c) => c < 0x20 || c > 0x7D || c == 0x3D);
    if (invalidName) w.add('comment $i: field name "$field" contains invalid characters');
    if (upper == 'METADATA_BLOCK_PICTURE') {
      try {
        entry['picture'] = _oggPictureBlock(base64.decode(value.trim()));
        entry['value'] = '(base64, ${value.length} characters)';
      } catch (e) {
        entry['value'] = value.length > 64 ? '${value.substring(0, 64)}...' : value;
        w.add('METADATA_BLOCK_PICTURE could not be decoded: $e');
      }
    } else if (upper == 'COVERART') {
      try {
        entry['picture'] = _mp3AnalyzeBinaryObject(base64.decode(value.trim()));
        entry['value'] = '(base64, ${value.length} characters)';
      } catch (e) {
        entry['value'] = value.length > 64 ? '${value.substring(0, 64)}...' : value;
      }
    } else {
      entry['value'] = value;
      if (upper == 'R128_TRACK_GAIN' || upper == 'R128_ALBUM_GAIN') {
        final q = int.tryParse(value.trim());
        if (q != null) entry['gainDb'] = q / 256.0;
      } else if (upper == 'GENRE') {
        final n = int.tryParse(value.trim());
        if (n != null) entry['genreName'] = _mp3GenreName(n);
      }
    }
    if (!upper.contains('PICTURE') && upper != 'COVERART') (values[upper] ??= <String>[]).add(value);
    comments.add(entry);
  }
  final out = <String, Object?>{
    'vendor': vendor,
    'commentCount': count,
    'comments': comments,
    'values': values,
  };
  if (framing) {
    final bit = p < d.length ? d[p] & 1 : 0;
    out['framingBit'] = bit;
    if (bit != 1) w.add('comment header: framing bit not set');
    p++;
  }
  if (p < d.length) out['bytesAfterComments'] = d.length - p;
  return out;
}

// --- Vorbis ---------------------------------------------------------------------

Map<String, Object?> _oggVorbisIdentification(Uint8List p, _OggStream s) {
  final w = s.warnings;
  final version = _mp3UIntLE(p, 7, 4);
  final channels = p[11];
  final rate = _mp3UIntLE(p, 12, 4);
  final bmax = _oggInt32(p, 16);
  final bnom = _oggInt32(p, 20);
  final bmin = _oggInt32(p, 24);
  final bs = p[28];
  final bs0 = 1 << (bs & 0x0F);
  final bs1 = 1 << (bs >> 4);
  final framing = p.length > 29 ? p[29] & 1 : 0;
  if (version != 0) w.add('vorbis_version is $version, only 0 is defined');
  if (channels == 0) w.add('audio_channels is 0');
  if (rate == 0) w.add('audio_sample_rate is 0');
  if (bs0 > bs1) w.add('blocksize_0 is larger than blocksize_1');
  if (bs0 < 64 || bs1 > 8192) w.add('block sizes must be between 64 and 8192');
  if (framing != 1) w.add('identification header: framing bit not set');
  s.sampleRate = rate;
  s.blockSize0 = bs0;
  s.blockSize1 = bs1;
  String br(int v) => v <= 0 ? 'not set' : '${v / 1000} kbps';
  return <String, Object?>{
    'packetType': 1,
    'packetTypeName': 'identification header',
    'hex': _mp3Hex(p, 0, p.length > 30 ? 30 : p.length),
    'vorbisVersion': version,
    'audioChannels': channels,
    'channelLayout': _oggVorbisChannelLayout(channels),
    'audioSampleRate': rate,
    'bitrateMaximum': bmax,
    'bitrateNominal': bnom,
    'bitrateMinimum': bmin,
    'bitrateMaximumText': br(bmax),
    'bitrateNominalText': br(bnom),
    'bitrateMinimumText': br(bmin),
    'bitrateHint': bmax > 0 && bmax == bnom && bnom == bmin
        ? 'constant bitrate (all three equal)'
        : (bnom > 0 && bmax <= 0 && bmin <= 0 ? 'average bitrate (nominal only)' : 'variable bitrate'),
    'blocksize0': bs0,
    'blocksize1': bs1,
    'framingFlag': framing,
  };
}

List<String> _oggVorbisChannelLayout(int channels) {
  const layouts = <int, List<String>>{
    1: ['mono'],
    2: ['left', 'right'],
    3: ['left', 'center', 'right'],
    4: ['front left', 'front right', 'rear left', 'rear right'],
    5: ['front left', 'center', 'front right', 'rear left', 'rear right'],
    6: ['front left', 'center', 'front right', 'rear left', 'rear right', 'LFE'],
    7: ['front left', 'center', 'front right', 'side left', 'side right', 'rear center', 'LFE'],
    8: ['front left', 'center', 'front right', 'side left', 'side right', 'rear left', 'rear right', 'LFE'],
  };
  return layouts[channels] ?? <String>[for (var i = 1; i <= channels; i++) 'channel $i (application defined)'];
}

Map<String, Object?> _oggVorbisSetup(Uint8List p, _OggStream s, int channels) {
  final out = <String, Object?>{'packetType': 5, 'packetTypeName': 'setup header', 'size': p.length};
  final br = _OggBits(p, 7);
  final codebooks = <Map<String, Object?>>[];
  final floors = <Map<String, Object?>>[];
  final residues = <Map<String, Object?>>[];
  final mappings = <Map<String, Object?>>[];
  final modes = <Map<String, Object?>>[];
  out['codebooks'] = codebooks;
  out['floors'] = floors;
  out['residues'] = residues;
  out['mappings'] = mappings;
  out['modes'] = modes;
  try {
    final codebookCount = br.read(8) + 1;
    out['codebookCount'] = codebookCount;
    for (var i = 0; i < codebookCount; i++) {
      final cbStart = br.bitsRead;
      final sync = br.read(24);
      if (sync != 0x564342) throw FormatException('codebook $i: invalid sync pattern 0x${sync.toRadixString(16)}');
      final dimensions = br.read(16);
      final entries = br.read(24);
      final ordered = br.read(1) == 1;
      var used = 0;
      var minLength = 99;
      var maxLength = 0;
      var sparse = false;
      if (!ordered) {
        sparse = br.read(1) == 1;
        for (var e = 0; e < entries; e++) {
          if (sparse && br.read(1) == 0) continue;
          final l = br.read(5) + 1;
          used++;
          if (l < minLength) minLength = l;
          if (l > maxLength) maxLength = l;
        }
      } else {
        var current = 0;
        var length = br.read(5) + 1;
        while (current < entries) {
          final number = br.read(_oggIlog(entries - current));
          if (number > 0) {
            if (length < minLength) minLength = length;
            if (length > maxLength) maxLength = length;
          }
          current += number;
          used += number;
          length++;
          if (current > entries) throw FormatException('codebook $i: too many ordered entries');
        }
      }
      final lookupType = br.read(4);
      final cb = <String, Object?>{
        'index': i,
        'dimensions': dimensions,
        'entries': entries,
        'ordered': ordered,
        'sparse': sparse,
        'usedEntries': used,
        if (used > 0) 'minCodewordLength': minLength,
        if (used > 0) 'maxCodewordLength': maxLength,
        'lookupType': lookupType,
        'lookupTypeName': const <int, String>{
              0: 'no lookup (scalar context)',
              1: 'lattice (implicitly populated value mapping)',
              2: 'tessellated (explicitly populated value mapping)',
            }[lookupType] ??
            'reserved',
      };
      if (lookupType == 1 || lookupType == 2) {
        final minimum = _oggFloat32Unpack(br.read(32));
        final delta = _oggFloat32Unpack(br.read(32));
        final valueBits = br.read(4) + 1;
        final sequenceP = br.read(1) == 1;
        final values = lookupType == 1 ? _oggLookup1Values(entries, dimensions) : entries * dimensions;
        br.skip(values * valueBits);
        cb['minimumValue'] = minimum;
        cb['deltaValue'] = delta;
        cb['valueBits'] = valueBits;
        cb['sequenceP'] = sequenceP;
        cb['lookupValues'] = values;
      } else if (lookupType != 0) {
        throw FormatException('codebook $i: reserved lookup type $lookupType');
      }
      cb['sizeBits'] = br.bitsRead - cbStart;
      codebooks.add(cb);
    }

    final timeCount = br.read(6) + 1;
    for (var i = 0; i < timeCount; i++) {
      if (br.read(16) != 0) throw FormatException('time domain transform $i is not 0');
    }
    out['timeDomainTransforms'] = timeCount;

    final floorCount = br.read(6) + 1;
    for (var i = 0; i < floorCount; i++) {
      final type = br.read(16);
      if (type == 0) {
        final order = br.read(8);
        final rate = br.read(16);
        final barkMapSize = br.read(16);
        final amplitudeBits = br.read(6);
        final amplitudeOffset = br.read(8);
        final books = br.read(4) + 1;
        floors.add(<String, Object?>{
          'index': i,
          'type': 0,
          'typeName': 'floor 0 (LSP)',
          'order': order,
          'rate': rate,
          'barkMapSize': barkMapSize,
          'amplitudeBits': amplitudeBits,
          'amplitudeOffset': amplitudeOffset,
          'books': <int>[for (var b = 0; b < books; b++) br.read(8)],
        });
      } else if (type == 1) {
        final partitions = br.read(5);
        final classList = <int>[for (var j = 0; j < partitions; j++) br.read(4)];
        final maxClass = classList.isEmpty ? -1 : classList.reduce(math.max);
        final classes = <Map<String, Object?>>[];
        final dims = <int>[];
        for (var c = 0; c <= maxClass; c++) {
          final dim = br.read(3) + 1;
          final sub = br.read(2);
          int? master;
          if (sub != 0) master = br.read(8);
          final subBooks = <int>[for (var j = 0; j < (1 << sub); j++) br.read(8) - 1];
          dims.add(dim);
          classes.add(<String, Object?>{
            'dimensions': dim,
            'subclasses': sub,
            if (master != null) 'masterbook': master,
            'subclassBooks': subBooks,
          });
        }
        final multiplier = br.read(2) + 1;
        final rangeBits = br.read(4);
        var values = 2;
        for (final c in classList) {
          for (var j = 0; j < dims[c]; j++) {
            br.read(rangeBits);
            values++;
          }
        }
        floors.add(<String, Object?>{
          'index': i,
          'type': 1,
          'typeName': 'floor 1 (piecewise linear)',
          'partitions': partitions,
          'partitionClassList': classList,
          'classes': classes,
          'multiplier': multiplier,
          'rangeBits': rangeBits,
          'xListValues': values,
        });
      } else {
        throw FormatException('floor $i: invalid floor type $type');
      }
    }

    final residueCount = br.read(6) + 1;
    for (var i = 0; i < residueCount; i++) {
      final type = br.read(16);
      if (type > 2) throw FormatException('residue $i: invalid residue type $type');
      final begin = br.read(24);
      final end = br.read(24);
      final partitionSize = br.read(24) + 1;
      final classifications = br.read(6) + 1;
      final classbook = br.read(8);
      final cascades = <int>[];
      for (var c = 0; c < classifications; c++) {
        final low = br.read(3);
        final flag = br.read(1);
        final high = flag == 1 ? br.read(5) : 0;
        cascades.add(high * 8 + low);
      }
      var books = 0;
      for (final c in cascades) {
        for (var j = 0; j < 8; j++) {
          if ((c >> j) & 1 == 1) {
            br.read(8);
            books++;
          }
        }
      }
      residues.add(<String, Object?>{
        'index': i,
        'type': type,
        'begin': begin,
        'end': end,
        'partitionSize': partitionSize,
        'classifications': classifications,
        'classbook': classbook,
        'cascadeBooks': books,
      });
    }

    final mappingCount = br.read(6) + 1;
    final channelBits = _oggIlog(channels - 1);
    for (var i = 0; i < mappingCount; i++) {
      final type = br.read(16);
      if (type != 0) throw FormatException('mapping $i: invalid mapping type $type');
      final submaps = br.read(1) == 1 ? br.read(4) + 1 : 1;
      final coupling = <Map<String, int>>[];
      if (br.read(1) == 1) {
        final steps = br.read(8) + 1;
        for (var c = 0; c < steps; c++) {
          coupling.add(<String, int>{'magnitude': br.read(channelBits), 'angle': br.read(channelBits)});
        }
      }
      if (br.read(2) != 0) throw FormatException('mapping $i: reserved field is not 0');
      final mux = <int>[];
      if (submaps > 1) {
        for (var c = 0; c < channels; c++) {
          mux.add(br.read(4));
        }
      }
      final subs = <Map<String, int>>[];
      for (var j = 0; j < submaps; j++) {
        br.read(8);
        subs.add(<String, int>{'floor': br.read(8), 'residue': br.read(8)});
      }
      mappings.add(<String, Object?>{
        'index': i,
        'type': 0,
        'submaps': submaps,
        'couplingSteps': coupling,
        if (mux.isNotEmpty) 'channelMux': mux,
        'submapConfig': subs,
      });
    }

    final modeCount = br.read(6) + 1;
    final flags = <int>[];
    for (var i = 0; i < modeCount; i++) {
      final blockflag = br.read(1);
      final window = br.read(16);
      final transform = br.read(16);
      final mapping = br.read(8);
      flags.add(blockflag);
      modes.add(<String, Object?>{
        'index': i,
        'blockflag': blockflag,
        'blockSize': blockflag == 1 ? s.blockSize1 : s.blockSize0,
        'windowType': window,
        'transformType': transform,
        'mapping': mapping,
      });
      if (window != 0 || transform != 0) s.warnings.add('mode $i: window/transform type must be 0');
      if (mapping >= mappingCount) s.warnings.add('mode $i: mapping $mapping does not exist');
    }
    final framing = br.read(1);
    out['framingFlag'] = framing;
    if (framing != 1) s.warnings.add('setup header: framing bit not set');
    s.modeBlockFlags = flags;
    out['parsedBits'] = br.bitsRead;
    out['codebookBytes'] = codebooks.fold<int>(0, (a, c) => a + (c['sizeBits'] as int)) ~/ 8;
    out['complete'] = true;
  } catch (e) {
    out['complete'] = false;
    out['error'] = e.toString();
    s.warnings.add('setup header could not be parsed completely: $e');
  }
  return out;
}

void _oggVorbisPacket(_OggStream s, Uint8List p, Map<String, Object?> entry) {
  if (p[0] & 1 == 1) {
    final type = p[0];
    if (p.length < 7 || !_mp3StartsWith(p, 1, 'vorbis')) {
      entry['type'] = 'invalid header packet';
      s.warnings.add('packet ${entry['index']}: header packet without "vorbis" signature');
      return;
    }
    final expected = s.packets.length - 1; // index of this packet
    if (type == 1) {
      entry['type'] = 'identification header';
      if (expected != 0) s.warnings.add('identification header is not the first packet');
      s.headers['identification'] = _oggVorbisIdentification(p, s);
    } else if (type == 3) {
      entry['type'] = 'comment header';
      if (expected != 1) s.warnings.add('comment header is not the second packet');
      final c = <String, Object?>{
        'packetType': 3,
        'packetTypeName': 'comment header',
        'size': p.length,
        ..._oggComments(p, 7, s.warnings, framing: true),
      };
      s.headers['comment'] = c;
      s.comments ??= c;
    } else if (type == 5) {
      entry['type'] = 'setup header';
      if (expected != 2) s.warnings.add('setup header is not the third packet');
      final ident = s.headers['identification'];
      final channels = ident is Map ? (ident['audioChannels'] as int? ?? 1) : 1;
      s.headers['setup'] = _oggVorbisSetup(p, s, channels);
    } else {
      entry['type'] = 'unknown header packet type $type';
      s.warnings.add('packet ${entry['index']}: unknown header packet type $type');
    }
    return;
  }

  entry['type'] = 'audio';
  _oggCountAudio(s, p.length);
  final flags = s.modeBlockFlags;
  if (flags == null || s.blockSize0 == null) return;
  try {
    final br = _OggBits(p, 0);
    br.read(1);
    final mode = br.read(_oggIlog(flags.length - 1));
    if (mode >= flags.length) {
      entry['warning'] = 'invalid mode number $mode';
      return;
    }
    final blockflag = flags[mode];
    entry['mode'] = mode;
    if (blockflag == 1) {
      entry['previousWindowFlag'] = br.read(1);
      entry['nextWindowFlag'] = br.read(1);
      s.longBlocks++;
    } else {
      s.shortBlocks++;
    }
    final size = blockflag == 1 ? s.blockSize1! : s.blockSize0!;
    entry['blockSize'] = size;
    final prev = s.previousBlock;
    final n = prev == null ? 0 : prev ~/ 4 + size ~/ 4;
    s.previousBlock = size;
    s.samples += n;
    s.samplesKnown = true;
    entry['samples'] = n;
    entry['cumulativeSamples'] = s.samples;
  } on _OggEndOfPacket {
    entry['warning'] = 'packet too short for the packet header';
  }
}

void _oggCountAudio(_OggStream s, int size) {
  s.audioPackets++;
  s.audioBytes += size;
  if (s.minPacket == null || size < s.minPacket!) s.minPacket = size;
  if (s.maxPacket == null || size > s.maxPacket!) s.maxPacket = size;
}

// --- Opus -----------------------------------------------------------------------

void _oggOpusPacket(_OggStream s, Uint8List p, Map<String, Object?> entry, int index) {
  if (index == 0) {
    entry['type'] = 'identification header (OpusHead)';
    final channels = p[9];
    final family = p[18];
    s.preSkip = _mp3UIntLE(p, 10, 2);
    s.sampleRate = 48000;
    final gain = _mp3UIntLE(p, 16, 2);
    final head = <String, Object?>{
      'hex': _mp3HexPreview(p, 32),
      'version': p[8],
      'channels': channels,
      'preSkip': s.preSkip,
      'inputSampleRate': _mp3UIntLE(p, 12, 4),
      'outputGainDb': (gain >= 0x8000 ? gain - 0x10000 : gain) / 256.0,
      'channelMappingFamily': family,
      'channelMappingFamilyName': const <int, String>{
            0: 'mono/stereo (RTP mapping)',
            1: 'Vorbis channel order',
            2: 'ambisonics',
            3: 'ambisonics with demixing matrix',
            255: 'no defined channel meaning',
          }[family] ??
          'reserved',
      'decodingSampleRate': 48000,
    };
    if (family != 0 && p.length >= 21) {
      head['streamCount'] = p[19];
      head['coupledStreamCount'] = p[20];
      head['channelMapping'] = <int>[for (var i = 0; i < channels && 21 + i < p.length; i++) p[21 + i]];
    }
    if ((p[8] >> 4) != 0) s.warnings.add('OpusHead: incompatible major version ${p[8]}');
    s.headers['identification'] = head;
    return;
  }
  if (index == 1) {
    entry['type'] = 'comment header (OpusTags)';
    if (!_mp3StartsWith(p, 0, 'OpusTags')) s.warnings.add('second packet is not OpusTags');
    final c = <String, Object?>{'size': p.length, ..._oggComments(p, 8, s.warnings)};
    s.headers['comment'] = c;
    s.comments ??= c;
    return;
  }
  entry['type'] = 'audio';
  _oggCountAudio(s, p.length);
  final toc = p[0];
  final config = toc >> 3;
  final String mode;
  final String bandwidth;
  final double frameMs;
  if (config < 12) {
    mode = 'SILK';
    bandwidth = const <String>['narrowband', 'mediumband', 'wideband'][config ~/ 4];
    frameMs = const <double>[10.0, 20.0, 40.0, 60.0][config % 4];
  } else if (config < 16) {
    mode = 'Hybrid';
    bandwidth = config < 14 ? 'super-wideband' : 'fullband';
    frameMs = config.isEven ? 10.0 : 20.0;
  } else {
    mode = 'CELT';
    bandwidth = const <String>['narrowband', 'wideband', 'super-wideband', 'fullband'][(config - 16) ~/ 4];
    frameMs = const <double>[2.5, 5.0, 10.0, 20.0][config % 4];
  }
  final code = toc & 3;
  final frames = code == 0 ? 1 : (code == 3 ? (p.length > 1 ? p[1] & 0x3F : 0) : 2);
  final n = (frames * frameMs * 48).round();
  s.samples += n;
  s.samplesKnown = true;
  entry.addAll(<String, Object?>{
    'toc': _mp3Bin(toc, 8),
    'config': config,
    'mode': mode,
    'bandwidth': bandwidth,
    'frameSizeMs': frameMs,
    'stereo': (toc >> 2) & 1 == 1,
    'frameCountCode': code,
    'frames': frames,
    'samples': n,
    'cumulativeSamples': s.samples,
  });
}

// --- FLAC in Ogg ----------------------------------------------------------------

const _oggFlacBlockTypes = <int, String>{
  0: 'STREAMINFO',
  1: 'PADDING',
  2: 'APPLICATION',
  3: 'SEEKTABLE',
  4: 'VORBIS_COMMENT',
  5: 'CUESHEET',
  6: 'PICTURE',
  127: 'invalid',
};

Map<String, Object?> _oggFlacMetadataBlock(Uint8List p, int o, _OggStream s) {
  final type = p[o] & 0x7F;
  final length = _mp3UInt(p, o + 1, 3);
  final b = Uint8List.sublistView(p, o + 4, o + 4 + length > p.length ? p.length : o + 4 + length);
  final out = <String, Object?>{
    'blockType': type,
    'blockTypeName': _oggFlacBlockTypes[type] ?? 'reserved',
    'lastMetadataBlock': p[o] & 0x80 != 0,
    'length': length,
  };
  if (type == 0 && b.length >= 34) {
    final hi = _mp3UInt(b, 10, 4);
    final lo = _mp3UInt(b, 14, 4);
    final rate = hi >> 12;
    s.sampleRate = rate;
    out.addAll(<String, Object?>{
      'minBlockSize': _mp3UInt(b, 0, 2),
      'maxBlockSize': _mp3UInt(b, 2, 2),
      'minFrameSize': _mp3UInt(b, 4, 3),
      'maxFrameSize': _mp3UInt(b, 7, 3),
      'sampleRate': rate,
      'channels': ((hi >> 9) & 7) + 1,
      'bitsPerSample': ((hi >> 4) & 0x1F) + 1,
      'totalSamples': (hi & 0xF) * 0x100000000 + lo,
      'md5': _mp3Hex(b, 18, 34).replaceAll(' ', ''),
    });
  } else if (type == 4) {
    final c = _oggComments(b, 0, s.warnings);
    out.addAll(c);
    s.headers['comment'] = c;
    s.comments ??= c;
  } else if (type == 6) {
    out.addAll(_oggPictureBlock(b));
  } else if (type == 3) {
    out['seekPoints'] = b.length ~/ 18;
  } else if (type == 2 && b.length >= 4) {
    out['applicationId'] = _mp3Latin1(b, 0, 4);
  } else if (type == 1) {
    out.addAll(_wavPaddingContent(b));
  }
  return out;
}

void _oggFlacPacket(_OggStream s, Uint8List p, Map<String, Object?> entry, int index) {
  if (index == 0) {
    entry['type'] = 'FLAC mapping header + STREAMINFO';
    s.headerPackets = 1 + _mp3UInt(p, 7, 2);
    s.headers['identification'] = <String, Object?>{
      'mappingVersion': '${p[5]}.${p[6]}',
      'headerPackets': _mp3UInt(p, 7, 2),
      'flacSignature': _mp3Latin1(p, 9, 13),
      'streamInfo': _oggFlacMetadataBlock(p, 13, s),
    };
    return;
  }
  if (index < s.headerPackets) {
    final block = _oggFlacMetadataBlock(p, 0, s);
    entry['type'] = 'metadata block ${block['blockTypeName']}';
    ((s.headers['metadataBlocks'] ??= <Map<String, Object?>>[]) as List<Map<String, Object?>>).add(block);
    return;
  }
  entry['type'] = 'audio frame';
  _oggCountAudio(s, p.length);
  if (p.length < 5 || p[0] != 0xFF || (p[1] & 0xFE) != 0xF8) {
    entry['warning'] = 'no FLAC frame sync';
    return;
  }
  final code = p[2] >> 4;
  var utfLength = 1;
  final first = p[4];
  if (first >= 0xC0) {
    var mask = 0x80;
    utfLength = 0;
    while (first & mask != 0) {
      utfLength++;
      mask >>= 1;
    }
  }
  final x = 4 + utfLength;
  int? blockSize;
  if (code == 1) {
    blockSize = 192;
  } else if (code >= 2 && code <= 5) {
    blockSize = 576 << (code - 2);
  } else if (code == 6 && x < p.length) {
    blockSize = p[x] + 1;
  } else if (code == 7 && x + 1 < p.length) {
    blockSize = _mp3UInt(p, x, 2) + 1;
  } else if (code >= 8) {
    blockSize = 256 << (code - 8);
  }
  entry['blockingStrategy'] = p[1] & 1 == 0 ? 'fixed block size' : 'variable block size';
  if (blockSize != null) {
    entry['samples'] = blockSize;
    s.samples += blockSize;
    s.samplesKnown = true;
    entry['cumulativeSamples'] = s.samples;
  }
}

// --- Speex / Theora / Skeleton ----------------------------------------------------

void _oggSpeexPacket(_OggStream s, Uint8List p, Map<String, Object?> entry, int index) {
  if (index == 0) {
    entry['type'] = 'Speex header';
    final rate = _mp3UIntLE(p, 36, 4);
    final mode = _mp3UIntLE(p, 40, 4);
    s.sampleRate = rate;
    s.speexFrameSize = _mp3UIntLE(p, 56, 4);
    s.speexFramesPerPacket = _mp3UIntLE(p, 64, 4);
    s.headerPackets = 2 + _mp3UIntLE(p, 68, 4);
    s.headers['identification'] = <String, Object?>{
      'version': _wavText(p, 8, 28),
      'versionId': _mp3UIntLE(p, 28, 4),
      'headerSize': _mp3UIntLE(p, 32, 4),
      'rate': rate,
      'mode': const <int, String>{0: 'narrowband', 1: 'wideband', 2: 'ultra-wideband'}[mode] ?? 'unknown ($mode)',
      'modeBitstreamVersion': _mp3UIntLE(p, 44, 4),
      'channels': _mp3UIntLE(p, 48, 4),
      'bitrate': _oggInt32(p, 52),
      'frameSize': s.speexFrameSize,
      'vbr': _mp3UIntLE(p, 60, 4) != 0,
      'framesPerPacket': s.speexFramesPerPacket,
      'extraHeaders': _mp3UIntLE(p, 68, 4),
    };
    return;
  }
  if (index == 1) {
    entry['type'] = 'comment header';
    final c = <String, Object?>{'size': p.length, ..._oggComments(p, 0, s.warnings)};
    s.headers['comment'] = c;
    s.comments ??= c;
    return;
  }
  if (index < s.headerPackets) {
    entry['type'] = 'extra header';
    return;
  }
  entry['type'] = 'audio';
  _oggCountAudio(s, p.length);
  final frameSize = s.speexFrameSize;
  final perPacket = s.speexFramesPerPacket;
  if (frameSize != null && perPacket != null && frameSize > 0) {
    final n = frameSize * (perPacket == 0 ? 1 : perPacket);
    s.samples += n;
    s.samplesKnown = true;
    entry['samples'] = n;
    entry['cumulativeSamples'] = s.samples;
  }
}

void _oggTheoraPacket(_OggStream s, Uint8List p, Map<String, Object?> entry, int index) {
  if (p[0] & 0x80 != 0) {
    final type = p[0];
    if (type == 0x80) {
      entry['type'] = 'identification header';
      final fpsNum = _mp3UInt(p, 22, 4);
      final fpsDen = _mp3UInt(p, 26, 4);
      final last = _mp3UInt(p, 40, 2);
      s.theoraFpsNum = fpsNum;
      s.theoraFpsDen = fpsDen;
      s.theoraShift = (last >> 5) & 0x1F;
      s.headers['identification'] = <String, Object?>{
        'version': '${p[7]}.${p[8]}.${p[9]}',
        'frameWidth': _mp3UInt(p, 10, 2) * 16,
        'frameHeight': _mp3UInt(p, 12, 2) * 16,
        'pictureWidth': _mp3UInt(p, 14, 3),
        'pictureHeight': _mp3UInt(p, 17, 3),
        'pictureX': p[20],
        'pictureY': p[21],
        'frameRate': fpsDen == 0 ? null : fpsNum / fpsDen,
        'frameRateFraction': '$fpsNum/$fpsDen',
        'pixelAspectRatio': '${_mp3UInt(p, 30, 3)}:${_mp3UInt(p, 33, 3)}',
        'colorSpace': const <int, String>{0: 'undefined', 1: 'Rec. 470M', 2: 'Rec. 470BG'}[p[36]] ?? 'reserved',
        'nominalBitrate': _mp3UInt(p, 37, 3),
        'quality': (last >> 10) & 0x3F,
        'keyframeGranuleShift': s.theoraShift,
        'pixelFormat': const <int, String>{0: '4:2:0', 2: '4:2:2', 3: '4:4:4'}[(last >> 3) & 3] ?? 'reserved',
      };
    } else if (type == 0x81) {
      entry['type'] = 'comment header';
      final c = <String, Object?>{'size': p.length, ..._oggComments(p, 7, s.warnings)};
      s.headers['comment'] = c;
      s.comments ??= c;
    } else if (type == 0x82) {
      entry['type'] = 'setup header';
      s.headers['setup'] = <String, Object?>{'size': p.length};
    } else {
      entry['type'] = 'unknown header';
    }
    return;
  }
  entry['type'] = 'video frame';
  final key = p.length > 0 && (p[0] & 0x40) == 0;
  entry['frameType'] = key ? 'intra (key frame)' : 'inter';
  if (key) s.keyFrames++;
  _oggCountAudio(s, p.length);
}

void _oggSkeletonPacket(_OggStream s, Uint8List p, Map<String, Object?> entry) {
  if (_mp3StartsWith(p, 0, 'fishead')) {
    entry['type'] = 'fishead';
    s.headers['fishead'] = <String, Object?>{
      'version': '${_mp3UIntLE(p, 8, 2)}.${_mp3UIntLE(p, 10, 2)}',
      'presentationTime': '${_oggInt64(p, 12)}/${_oggInt64(p, 20)}',
      'baseTime': '${_oggInt64(p, 28)}/${_oggInt64(p, 36)}',
    };
  } else if (_mp3StartsWith(p, 0, 'fisbone')) {
    entry['type'] = 'fisbone';
    final offset = _mp3UIntLE(p, 8, 4);
    ((s.headers['fisbones'] ??= <Map<String, Object?>>[]) as List<Map<String, Object?>>).add(<String, Object?>{
      'serialNumber': _mp3UIntLE(p, 12, 4),
      'headerPackets': _mp3UIntLE(p, 16, 4),
      'granuleRate': '${_oggInt64(p, 20)}/${_oggInt64(p, 28)}',
      'baseGranule': _oggInt64(p, 36),
      'preroll': _mp3UIntLE(p, 44, 4),
      'granuleShift': p[48],
      'messageHeaders': _oggUtf8(p, 8 + offset, p.length).split('\r\n').where((l) => l.isNotEmpty).toList(),
    });
  } else if (_mp3StartsWith(p, 0, 'index')) {
    entry['type'] = 'keyframe index';
  } else {
    entry['type'] = p.isEmpty ? 'end of skeleton (empty packet)' : 'unknown';
  }
}

// --- stream / packet handling -----------------------------------------------------

void _oggDetectCodec(_OggStream s, Uint8List p) {
  if (p.length >= 7 && p[0] == 1 && _mp3StartsWith(p, 1, 'vorbis')) {
    s.codec = 'vorbis';
    s.codecName = 'Vorbis';
  } else if (_mp3StartsWith(p, 0, 'OpusHead')) {
    s.codec = 'opus';
    s.codecName = 'Opus';
    s.headerPackets = 2;
  } else if (p.length >= 13 && p[0] == 0x7F && _mp3StartsWith(p, 1, 'FLAC')) {
    s.codec = 'flac';
    s.codecName = 'FLAC';
  } else if (_mp3StartsWith(p, 0, 'Speex   ')) {
    s.codec = 'speex';
    s.codecName = 'Speex';
  } else if (p.length >= 7 && p[0] == 0x80 && _mp3StartsWith(p, 1, 'theora')) {
    s.codec = 'theora';
    s.codecName = 'Theora (video)';
  } else if (_mp3StartsWith(p, 0, 'fishead\u0000')) {
    s.codec = 'skeleton';
    s.codecName = 'Ogg Skeleton (metadata)';
  } else if (p.length >= 5 && p[0] == 0x7F && _mp3StartsWith(p, 1, 'PCM ')) {
    s.codec = 'pcm';
    s.codecName = 'Ogg PCM';
  } else if (_mp3StartsWith(p, 0, 'CELT    ')) {
    s.codec = 'celt';
    s.codecName = 'CELT';
  } else if (p.length >= 8 && p[0] == 0x80 && _mp3StartsWith(p, 1, 'kate')) {
    s.codec = 'kate';
    s.codecName = 'Kate (text / subtitles)';
  } else {
    s.warnings.add('unknown codec in first packet');
  }
}

void _oggHandlePacket(_OggStream s, Uint8List p, int startPage, int endPage) {
  final index = s.packets.length;
  final entry = <String, Object?>{
    'index': index,
    'size': p.length,
    'startPage': startPage,
    if (endPage != startPage) 'endPage': endPage,
  };
  s.packets.add(entry);
  if (index == 0) _oggDetectCodec(s, p);
  if (p.isEmpty) {
    entry['type'] = 'empty packet';
    return;
  }
  try {
    switch (s.codec) {
      case 'vorbis':
        _oggVorbisPacket(s, p, entry);
      case 'opus':
        _oggOpusPacket(s, p, entry, index);
      case 'flac':
        _oggFlacPacket(s, p, entry, index);
      case 'speex':
        _oggSpeexPacket(s, p, entry, index);
      case 'theora':
        _oggTheoraPacket(s, p, entry, index);
      case 'skeleton':
        _oggSkeletonPacket(s, p, entry);
      default:
        entry['type'] = index == 0 ? 'first packet (unknown codec)' : 'data';
        if (index == 0) {
          entry['hexPreview'] = _mp3HexPreview(p, 32);
          entry['asciiPreview'] = _mp3AsciiPreview(p);
        }
    }
  } catch (e) {
    entry['warning'] = 'packet analysis failed: $e';
    s.warnings.add('packet $index: analysis failed: $e');
  }
}

/// Checks the granule position at the end of a page against the decoded samples.
void _oggCheckGranule(_OggStream s, int granule, bool eos) {
  if (!s.samplesKnown || s.codec == 'theora' || s.codec == 'skeleton') return;
  final offset = s.granuleOffset;
  if (offset == null) {
    s.granuleOffset = granule - s.samples;
    return;
  }
  final expected = s.samples + offset;
  if (granule == expected) return;
  if (eos && granule < expected) {
    s.trimmedAtEnd = expected - granule;
  } else {
    s.granuleMismatches++;
  }
}

// --- public entry -------------------------------------------------------------

/// Analyses an Ogg file (Ogg Vorbis, and Opus / FLAC / Speex / Theora in Ogg).
///
/// The result is a JSON compatible map:
///
/// ```text
/// {
///   fileSize:  int
///   summary:   { streamCount, structure, codecs, pageCount, crcErrors,
///                durationSeconds, duration, averageBitrateKbps, ... }
///   streams:   [ { serialNumber, codec, codecName, pageCount, packetCount,
///                  headers{identification, comment, setup ...},
///                  comments, firstGranulePosition, lastGranulePosition,
///                  durationSeconds, duration, averageBitrateKbps,
///                  packetStatistics{...}, packets[...], warnings } ]
///   pages:     [ { index, offset, headerHex, version, headerType{...},
///                  granulePosition, serialNumber, pageSequence, crc,
///                  crcComputed, crcValid, segmentCount, lacingValues,
///                  headerBytes, dataBytes, pageSize, packets[...] } ]
///   comments:  values of the first comment header (FIELD: [values])
///   unrecognizedRanges: [ { offset, length, ... } ]
///   tagsFound, id3v2, id3v1, ape, lyrics3
///   warnings:  [String]
/// }
/// ```
Map<String, Object?> oggAnalyze(Uint8List data) {
  final warnings = <String>[];
  final id3v2 = <Map<String, Object?>>[];

  var start = 0;
  try {
    while (start + 10 <= data.length && _mp3StartsWith(data, start, 'ID3')) {
      final tag = _mp3ParseId3v2Tag(data, start, 'in front of the Ogg data (non-standard)');
      if (tag == null) break;
      id3v2.add(tag);
      final total = (tag['totalSize'] as int?) ?? 0;
      if (total <= 0) break;
      start += total;
    }
  } catch (e) {
    warnings.add('ID3v2 analysis aborted: $e');
  }
  if (start > data.length) start = data.length;
  if (id3v2.isNotEmpty) warnings.add('ID3v2 tag in front of Ogg data is not standard');

  var end = data.length;
  Map<String, Object?> trailing = const <String, Object?>{};
  try {
    trailing = _mp3AnalyzeTrailingTags(data, start);
    end = (trailing['audioEnd'] as int?) ?? data.length;
    final appended = trailing['id3v2'];
    if (appended is List<Map<String, Object?>>) id3v2.addAll(appended);
  } catch (e) {
    warnings.add('analysis of tags at the end aborted: $e');
  }

  final pages = <Map<String, Object?>>[];
  final streams = <int, _OggStream>{};
  final streamOrder = <_OggStream>[];
  final unrecognized = <Map<String, Object?>>[];
  var crcErrors = 0;
  var unrecognizedBytes = 0;
  var sawNonBosPage = false;
  var chained = false;
  var grouped = false;
  int? junkStart;

  void flushJunk(int upTo) {
    final js = junkStart;
    junkStart = null;
    if (js == null || upTo <= js) return;
    final rest = Uint8List.sublistView(data, js, upTo);
    unrecognized.add(<String, Object?>{
      'offset': js,
      'offsetHex': _mp3HexOffset(js),
      'length': upTo - js,
      ..._wavPaddingContent(rest),
    });
    unrecognizedBytes += upTo - js;
  }

  var pos = start;
  while (pos + 27 <= end) {
    if (!_mp3StartsWith(data, pos, 'OggS') || data[pos + 4] != 0 || pos + 27 + data[pos + 26] > end) {
      junkStart ??= pos;
      pos++;
      continue;
    }
    flushJunk(pos);
    final pageIndex = pages.length;
    final headerType = data[pos + 5];
    final granule = _oggInt64(data, pos + 6);
    final serial = _mp3UIntLE(data, pos + 14, 4);
    final sequence = _mp3UIntLE(data, pos + 18, 4);
    final crc = _mp3UIntLE(data, pos + 22, 4);
    final segments = data[pos + 26];
    final lacing = <int>[for (var i = 0; i < segments; i++) data[pos + 27 + i]];
    final headerSize = 27 + segments;
    final bodySize = lacing.fold<int>(0, (a, b) => a + b);
    final pageEnd = pos + headerSize + bodySize;
    final truncated = pageEnd > end;
    final continued = headerType & 0x01 != 0;
    final isBos = headerType & 0x02 != 0;
    final isEos = headerType & 0x04 != 0;
    final pageWarnings = <String>[];

    int? computed;
    if (!truncated) {
      computed = _oggCrc(data, pos, pageEnd, pos + 22);
      if (computed != crc) {
        crcErrors++;
        pageWarnings.add('CRC mismatch');
      }
    } else {
      pageWarnings.add('page truncated: ${pageEnd - end} byte(s) missing');
    }
    if (headerType & 0xF8 != 0) pageWarnings.add('undefined header type flag bits set');

    var stream = streams[serial];
    if (stream == null) {
      stream = _OggStream(serial, pageIndex, pos);
      streams[serial] = stream;
      streamOrder.add(stream);
      if (!isBos) pageWarnings.add('first page of the stream has no BOS flag');
      if (isBos && sawNonBosPage) chained = true;
      if (isBos && !sawNonBosPage && streamOrder.length > 1) grouped = true;
    } else if (isBos) {
      pageWarnings.add('BOS flag on a page that is not the first page of the stream');
    }
    if (!isBos) sawNonBosPage = true;
    final s = stream;
    if (isBos) s.bos = true;
    if (s.eos) pageWarnings.add('page after the EOS page of this stream');
    if (isEos) s.eos = true;
    final last = s.lastSequence;
    if (last != null && sequence != (last + 1) & 0xFFFFFFFF) {
      final lost = sequence - last - 1;
      pageWarnings.add('page sequence gap: expected ${last + 1}, found $sequence');
      if (lost > 0) s.lostPages += lost;
      s.partial.clear();
      s.partialStartPage = null;
    }
    s.lastSequence = sequence;
    s.pageCount++;
    s.bytes += (truncated ? end : pageEnd) - pos;

    if (continued && s.partial.isEmpty && s.packets.isNotEmpty) {
      pageWarnings.add('continued packet flag set, but no packet is pending (data lost)');
    }
    if (!continued && s.partial.isNotEmpty) {
      pageWarnings.add('previous packet was not finished, but this page does not continue it');
      s.partial.clear();
      s.partialStartPage = null;
    }

    // Segments -> packets.
    final pagePackets = <Map<String, Object?>>[];
    var seg = pos + headerSize;
    var completed = 0;
    var bytesOnPage = 0;
    var firstOnPageIsContinuation = continued && s.partial.isNotEmpty;
    // A continued packet whose beginning is missing cannot be reassembled.
    var skipContinuation = continued && s.partial.isEmpty;
    var skippedBytes = 0;
    for (var i = 0; i < segments; i++) {
      final l = lacing[i];
      if (skipContinuation) {
        skippedBytes += l;
        seg += l;
        if (l < 255) skipContinuation = false;
        continue;
      }
      final segEnd = seg + l > end ? end : seg + l;
      if (s.partial.isEmpty) s.partialStartPage = pageIndex;
      s.partial.addAll(Uint8List.sublistView(data, seg, segEnd));
      bytesOnPage += segEnd - seg;
      seg += l;
      if (l < 255) {
        final packet = Uint8List.fromList(s.partial);
        final startPage = s.partialStartPage ?? pageIndex;
        s.partial.clear();
        s.partialStartPage = null;
        if (!truncated || seg <= end) {
          _oggHandlePacket(s, packet, startPage, pageIndex);
          pagePackets.add(<String, Object?>{
            'packetIndex': s.packets.length - 1,
            'bytesOnPage': bytesOnPage,
            'complete': true,
            if (firstOnPageIsContinuation) 'continuedFromPreviousPage': true,
          });
          completed++;
        }
        bytesOnPage = 0;
        firstOnPageIsContinuation = false;
      }
    }
    if (skippedBytes > 0) {
      pagePackets.insert(0, <String, Object?>{
        'packetIndex': null,
        'bytesOnPage': skippedBytes,
        'complete': false,
        'note': 'end of a packet whose beginning is missing (skipped)',
      });
    }
    if (segments > 0 && lacing.last == 255 && !skipContinuation) {
      pagePackets.add(<String, Object?>{
        'packetIndex': s.packets.length,
        'bytesOnPage': bytesOnPage,
        'complete': false,
        'continuesOnNextPage': true,
        if (firstOnPageIsContinuation) 'continuedFromPreviousPage': true,
      });
    }

    if (granule != -1) {
      s.firstGranule ??= granule;
      s.lastGranule = granule;
      if (completed == 0) pageWarnings.add('granule position set, but no packet ends on this page');
      _oggCheckGranule(s, granule, isEos);
    } else if (completed > 0) {
      pageWarnings.add('packets end on this page, but granule position is -1');
    }

    pages.add(<String, Object?>{
      'index': pageIndex,
      'offset': pos,
      'offsetHex': _mp3HexOffset(pos),
      'headerHex': _mp3Hex(data, pos, pos + 27),
      'capturePattern': 'OggS',
      'version': 0,
      'headerType': <String, Object?>{
        'bits': _mp3Bin(headerType, 8),
        'continuedPacket': continued,
        'beginOfStream': isBos,
        'endOfStream': isEos,
      },
      'granulePosition': granule,
      if (granule == -1) 'granuleNote': 'no packet finishes on this page',
      'serialNumber': serial,
      'serialHex': '0x${serial.toRadixString(16).toUpperCase().padLeft(8, '0')}',
      'streamCodec': s.codec,
      'pageSequence': sequence,
      'crc': '0x${crc.toRadixString(16).toUpperCase().padLeft(8, '0')}',
      if (computed != null) 'crcComputed': '0x${computed.toRadixString(16).toUpperCase().padLeft(8, '0')}',
      'crcValid': computed == crc,
      'segmentCount': segments,
      'lacingValues': lacing,
      'headerBytes': headerSize,
      'dataBytes': bodySize,
      'pageSize': headerSize + bodySize,
      'packetsCompleted': completed,
      'packets': pagePackets,
      if (pageWarnings.isNotEmpty) 'warnings': pageWarnings,
    });
    for (final w in pageWarnings) {
      s.warnings.add('page $pageIndex: $w');
    }
    pos = truncated ? end : pageEnd;
  }
  if (pos < end) junkStart ??= pos;
  flushJunk(end);

  // Streams.
  final streamMaps = <Map<String, Object?>>[];
  var totalDuration = 0.0;
  var maxDuration = 0.0;
  var anyDuration = false;
  for (final s in streamOrder) {
    if (s.partial.isNotEmpty) s.warnings.add('last packet is incomplete (${s.partial.length} bytes)');
    if (!s.eos) s.warnings.add('stream has no EOS page (file truncated or stream not finished)');
    double? seconds;
    final g = s.lastGranule;
    if (g != null && g >= 0) {
      if (s.codec == 'opus') {
        seconds = (g - s.preSkip) / 48000;
      } else if (s.codec == 'theora') {
        final shift = s.theoraShift;
        final fpsNum = s.theoraFpsNum;
        final fpsDen = s.theoraFpsDen;
        if (shift != null && fpsNum != null && fpsDen != null && fpsNum > 0) {
          final frames = (g >> shift) + (g & ((1 << shift) - 1));
          seconds = frames * fpsDen / fpsNum;
        }
      } else if (s.codec != 'skeleton' && (s.sampleRate ?? 0) > 0) {
        seconds = g / s.sampleRate!;
      }
    }
    if (seconds != null && seconds < 0) seconds = 0;
    if (seconds != null) {
      anyDuration = true;
      totalDuration += seconds;
      if (seconds > maxDuration) maxDuration = seconds;
    }
    final stats = <String, Object?>{
      'dataPackets': s.audioPackets,
      'dataBytes': s.audioBytes,
      if (s.minPacket != null) 'minPacketSize': s.minPacket,
      if (s.maxPacket != null) 'maxPacketSize': s.maxPacket,
      if (s.audioPackets > 0) 'averagePacketSize': _wavRound(s.audioBytes / s.audioPackets, 1),
      if (s.codec == 'vorbis') 'shortBlocks': s.shortBlocks,
      if (s.codec == 'vorbis') 'longBlocks': s.longBlocks,
      if (s.codec == 'theora') 'keyFrames': s.keyFrames,
      if (s.samplesKnown) 'decodedSamples': s.samples,
      if (s.granuleOffset != null) 'granuleOffset': s.granuleOffset,
      if (s.granuleOffset != null)
        'granuleOffsetNote': s.granuleOffset! < 0
            ? '${-s.granuleOffset!} samples are discarded at the beginning'
            : (s.granuleOffset! > 0 ? 'stream starts at sample ${s.granuleOffset}' : 'granule positions match'),
      if (s.trimmedAtEnd != null) 'samplesTrimmedAtEnd': s.trimmedAtEnd,
      if (s.samplesKnown) 'granuleMismatches': s.granuleMismatches,
      'lostPages': s.lostPages,
    };
    if (s.granuleMismatches > 0) s.warnings.add('${s.granuleMismatches} page(s) with unexpected granule position');
    streamMaps.add(<String, Object?>{
      'serialNumber': s.serial,
      'serialHex': '0x${s.serial.toRadixString(16).toUpperCase().padLeft(8, '0')}',
      'codec': s.codec,
      'codecName': s.codecName,
      'firstPageIndex': s.firstPageIndex,
      'firstPageOffset': s.firstPageOffset,
      'pageCount': s.pageCount,
      'packetCount': s.packets.length,
      'bytes': s.bytes,
      'beginOfStream': s.bos,
      'endOfStream': s.eos,
      'headers': s.headers,
      'comments': s.comments?['values'],
      'firstGranulePosition': s.firstGranule,
      'lastGranulePosition': s.lastGranule,
      if (s.sampleRate != null) 'sampleRate': s.sampleRate,
      if (s.codec == 'opus') 'preSkip': s.preSkip,
      'durationSeconds': seconds,
      'duration': seconds == null ? null : _mp3FormatDuration(seconds * 1000),
      'averageBitrateKbps': seconds == null || seconds <= 0 ? null : _wavRound(s.bytes * 8 / seconds / 1000),
      'packetStatistics': stats,
      'packets': s.packets,
      'warnings': s.warnings,
    });
  }

  final firstComments = streamOrder.map((s) => s.comments).whereType<Map<String, Object?>>().firstOrNull;
  if (pages.isEmpty) warnings.add('no Ogg page found');
  if (crcErrors > 0) warnings.add('$crcErrors page(s) with CRC errors');
  if (unrecognizedBytes > 0) warnings.add('$unrecognizedBytes byte(s) outside of Ogg pages');
  for (final s in streamMaps) {
    final w = s['warnings'] as List<String>;
    if (w.isNotEmpty) warnings.add('stream ${s['serialHex']} (${s['codecName']}): ${w.length} warning(s), see stream');
  }

  final duration = chained ? totalDuration : maxDuration;
  final v1 = trailing['id3v1'];
  return <String, Object?>{
    'fileSize': data.length,
    'oggStart': start,
    'oggEnd': end,
    'summary': <String, Object?>{
      'streamCount': streamOrder.length,
      'structure': streamOrder.length <= 1
          ? 'single logical stream'
          : (chained ? (grouped ? 'grouped and chained' : 'chained (streams one after another)') : 'grouped (multiplexed)'),
      'codecs': <String>[for (final s in streamOrder) s.codecName],
      'pageCount': pages.length,
      'crcErrors': crcErrors,
      'unrecognizedBytes': unrecognizedBytes,
      'durationSeconds': anyDuration ? duration : null,
      'duration': anyDuration ? _mp3FormatDuration(duration * 1000) : null,
      'averageBitrateKbps': anyDuration && duration > 0 ? _wavRound((end - start) * 8 / duration / 1000) : null,
    },
    'streams': streamMaps,
    'pages': pages,
    'comments': firstComments?['values'],
    'unrecognizedRanges': unrecognized,
    'tagsFound': <String>[
      for (final s in streamOrder)
        if (s.comments != null) '${s.codecName} comment (Vorbis comment format)',
      for (final t in id3v2) '${t['version']}',
      if (v1 is Map) '${v1['version']}',
      for (final a in (trailing['ape'] as List?) ?? const []) '${(a as Map)['version']}',
      for (final l in (trailing['lyrics3'] as List?) ?? const []) '${(l as Map)['version']}',
    ],
    'id3v2': id3v2,
    'id3v1': v1,
    'ape': trailing['ape'] ?? const <Object?>[],
    'lyrics3': trailing['lyrics3'] ?? const <Object?>[],
    'warnings': warnings,
  };
}
