part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// ID3v2.2 / ID3v2.3 / ID3v2.4: tag header, extended header, footer, padding,
// frame headers, frame flags, unsynchronisation, compression, encryption,
// grouping and data length indicator.
// ---------------------------------------------------------------------------

class _Mp3Id3Context {
  final int major;

  /// Tag level unsynchronisation flag (for ID3v2.4 it applies to every frame).
  final bool tagUnsync;
  final List<String> warnings;

  _Mp3Id3Context(this.major, this.tagUnsync, this.warnings);
}

Map<String, Object?> _mp3Id3v2TagFlags(int major, int f, List<String> warnings) {
  final m = <String, Object?>{'unsynchronisation': (f & 0x80) != 0};
  int known;
  if (major == 2) {
    m['compression'] = (f & 0x40) != 0;
    known = 0xC0;
  } else if (major == 3) {
    m['extendedHeader'] = (f & 0x40) != 0;
    m['experimental'] = (f & 0x20) != 0;
    known = 0xE0;
  } else {
    m['extendedHeader'] = (f & 0x40) != 0;
    m['experimental'] = (f & 0x20) != 0;
    m['footerPresent'] = (f & 0x10) != 0;
    known = 0xF0;
  }
  final unknown = f & (0xFF - known);
  if (unknown != 0) warnings.add('undefined tag header flag bits set: ${_mp3Bin(unknown, 8)}');
  return m;
}

/// Parses an ID3v2 tag starting at [offset]; null if there is no "ID3" header.
Map<String, Object?>? _mp3ParseId3v2Tag(Uint8List data, int offset, String location) {
  if (offset < 0 || offset + 10 > data.length || !_mp3StartsWith(data, offset, 'ID3')) return null;
  final major = data[offset + 3];
  final revision = data[offset + 4];
  final flags = data[offset + 5];
  final size = _mp3Syncsafe(data, offset + 6, 4);
  final warnings = <String>[];
  final hasFooter = major == 4 && (flags & 0x10) != 0;
  final tag = <String, Object?>{
    'location': location,
    'offset': offset,
    'offsetHex': _mp3HexOffset(offset),
    'version': 'ID3v2.$major.$revision',
    'totalSize': 10 + size + (hasFooter ? 10 : 0),
    'header': <String, Object?>{
      'hex': _mp3Hex(data, offset, offset + 10),
      'identifier': 'ID3',
      'majorVersion': major,
      'revision': revision,
      'flagsByte': _mp3Bin(flags, 8),
      'flags': _mp3Id3v2TagFlags(major, flags, warnings),
      'sizeHex': _mp3Hex(data, offset + 6, offset + 10),
      'size': size,
      'sizeNote': 'syncsafe integer (4 x 7 bit); size of the tag after the 10 byte header'
          '${hasFooter ? ', without the 10 byte footer' : ''}',
    },
  };
  if (!_mp3IsSyncsafe(data, offset + 6, 4)) {
    warnings.add('tag size bytes are not syncsafe (bit 7 set)');
  }
  final frames = <Map<String, Object?>>[];
  tag['frames'] = frames;
  tag['warnings'] = warnings;
  if (major < 2 || major > 4) {
    warnings.add('unsupported ID3v2 major version $major - frames are not analysed');
    tag['frameCount'] = 0;
    return tag;
  }
  if (revision == 0xFF) warnings.add('revision byte 0xFF is not allowed');

  try {
    var tagEnd = offset + 10 + size;
    if (tagEnd > data.length) {
      warnings.add('tag is truncated: declared end $tagEnd is beyond the file size ${data.length}');
      tagEnd = data.length;
    }
    final unsync = (flags & 0x80) != 0;
    var body = Uint8List.sublistView(data, offset + 10, tagEnd);
    if (unsync && major < 4) {
      final before = body.length;
      body = _mp3RemoveUnsync(body);
      tag['unsynchronisation'] = <String, Object?>{
        'appliedTo': 'whole tag (ID3v2.${major})',
        'removedBytes': before - body.length,
        'sizeAfterResynchronisation': body.length,
      };
    } else if (unsync) {
      tag['unsynchronisation'] = <String, Object?>{
        'appliedTo': 'every frame (ID3v2.4 tag flag, undone per frame)',
      };
    }
    if (major == 2 && (flags & 0x40) != 0) {
      warnings.add('ID3v2.2 compression flag set: no compression scheme is defined, tag must be ignored');
      tag['frameCount'] = 0;
      return tag;
    }

    var pos = 0;
    Map<String, Object?>? ext;
    if (major >= 3 && (flags & 0x40) != 0) {
      ext = _mp3ParseExtendedHeader(body, major, warnings);
      tag['extendedHeader'] = ext;
      pos = (ext['totalSize'] as int?) ?? 0;
      if (pos > body.length) pos = body.length;
    }

    final ctx = _Mp3Id3Context(major, unsync, warnings);
    final area = <String, Object?>{};
    frames.addAll(_mp3ParseId3v2Frames(body, pos, body.length, ctx, area, 0));
    tag['frameCount'] = frames.length;
    if (area.containsKey('paddingSize')) {
      tag['padding'] = <String, Object?>{
        'offsetInTagBody': area['paddingOffset'],
        'size': area['paddingSize'],
        'allZero': area['paddingAllZero'],
      };
      if (hasFooter) warnings.add('padding must not be used together with a footer (ID3v2.4)');
    }
    if (area.containsKey('unparsedBytes')) {
      tag['unparsedData'] = <String, Object?>{
        'offsetInTagBody': area['unparsedOffset'],
        'size': area['unparsedBytes'],
        'hexPreview': area['unparsedHexPreview'],
      };
    }

    // CRC check of the extended header.
    final crc = ext?['crc'];
    if (crc is int) {
      final crcEnd = major == 3 ? ((area['paddingOffset'] as int?) ?? body.length) : body.length;
      final computed = _mp3Crc32(body, pos, crcEnd);
      ext!['crcComputed'] = '0x${computed.toRadixString(16).toUpperCase().padLeft(8, '0')}';
      ext!['crcValid'] = computed == crc;
      if (computed != crc) warnings.add('extended header CRC-32 does not match the frame data');
    }

    if (hasFooter) {
      final f = offset + 10 + size;
      if (f + 10 <= data.length && _mp3StartsWith(data, f, '3DI')) {
        final same = _mp3Hex(data, f + 3, f + 10) == _mp3Hex(data, offset + 3, offset + 10);
        tag['footer'] = <String, Object?>{
          'offset': f,
          'hex': _mp3Hex(data, f, f + 10),
          'identifier': '3DI',
          'matchesHeader': same,
        };
        if (!same) warnings.add('footer does not repeat version, flags and size of the header');
      } else {
        warnings.add('footer flag set, but no "3DI" footer found after the tag');
      }
    }
    _mp3LinkRegistrations(frames);
  } catch (e) {
    warnings.add('tag analysis aborted: $e');
    tag['frameCount'] = frames.length;
  }
  return tag;
}

Map<String, Object?> _mp3ParseExtendedHeader(Uint8List body, int major, List<String> warnings) {
  final ext = <String, Object?>{};
  try {
    if (major == 3) {
      final size = _mp3UInt(body, 0, 4);
      final flags = _mp3UInt(body, 4, 2);
      ext['hex'] = _mp3Hex(body, 0, 4 + size);
      ext['size'] = size;
      ext['sizeNote'] = '32 bit integer, excludes the 4 size bytes (6 or 10)';
      ext['flags'] = _mp3Bin(flags, 16);
      final crcPresent = (flags & 0x8000) != 0;
      ext['crcDataPresent'] = crcPresent;
      ext['paddingSize'] = _mp3UInt(body, 6, 4);
      if (crcPresent) {
        final crc = _mp3UInt(body, 10, 4);
        ext['crc'] = crc;
        ext['crcHex'] = _mp3Hex(body, 10, 14);
      }
      if ((flags & 0x7FFF) != 0) warnings.add('undefined extended header flag bits set');
      if (size != 6 && size != 10) warnings.add('unusual ID3v2.3 extended header size $size');
      ext['totalSize'] = 4 + size;
    } else {
      final size = _mp3Syncsafe(body, 0, 4);
      final flagBytes = body[4];
      final flags = body[5];
      ext['hex'] = _mp3Hex(body, 0, size);
      ext['size'] = size;
      ext['sizeNote'] = 'syncsafe integer, includes the size bytes';
      ext['numberOfFlagBytes'] = flagBytes;
      ext['flags'] = _mp3Bin(flags, 8);
      if (flagBytes != 1) warnings.add('ID3v2.4 extended header should have exactly 1 flag byte');
      var p = 5 + flagBytes;
      ext['tagIsUpdate'] = (flags & 0x40) != 0;
      if ((flags & 0x40) != 0) {
        p += 1 + body[p];
      }
      ext['crcDataPresent'] = (flags & 0x20) != 0;
      if ((flags & 0x20) != 0) {
        final len = body[p];
        if (len == 5) {
          ext['crc'] = _mp3Syncsafe(body, p + 1, 5);
          ext['crcHex'] = _mp3Hex(body, p + 1, p + 6);
        }
        p += 1 + len;
      }
      ext['tagRestrictionsPresent'] = (flags & 0x10) != 0;
      if ((flags & 0x10) != 0) {
        final len = body[p];
        final r = body[p + 1];
        const tagSizes = <String>[
          'no more than 128 frames and 1 MB total tag size',
          'no more than 64 frames and 128 KB total tag size',
          'no more than 32 frames and 40 KB total tag size',
          'no more than 32 frames and 4 KB total tag size',
        ];
        const textSizes = <String>[
          'no restrictions',
          'no string is longer than 1024 characters',
          'no string is longer than 128 characters',
          'no string is longer than 30 characters',
        ];
        const imageSizes = <String>[
          'no restrictions',
          'all images are 256x256 pixels or smaller',
          'all images are 64x64 pixels or smaller',
          'all images are exactly 64x64 pixels, unless required otherwise',
        ];
        ext['restrictions'] = <String, Object?>{
          'bits': _mp3Bin(r, 8),
          'tagSize': tagSizes[(r >> 6) & 3],
          'textEncoding': (r & 0x20) == 0 ? 'no restrictions' : 'only ISO-8859-1 or UTF-8',
          'textFieldsSize': textSizes[(r >> 3) & 3],
          'imageEncoding': (r & 0x04) == 0 ? 'no restrictions' : 'only PNG or JPEG',
          'imageSize': imageSizes[r & 3],
        };
        p += 1 + len;
      }
      if ((flags & 0x8F) != 0) warnings.add('undefined extended header flag bits set');
      ext['totalSize'] = size;
    }
  } catch (e) {
    warnings.add('extended header could not be analysed: $e');
    ext['totalSize'] ??= 0;
  }
  return ext;
}

bool _mp3IsFrameId(Uint8List b, int offset, int length) {
  if (offset + length > b.length) return false;
  for (var i = 0; i < length; i++) {
    final c = b[offset + i];
    if (!((c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39))) return false;
  }
  return true;
}

bool _mp3PlausibleNextFrame(Uint8List b, int p, int end, int idLength) {
  if (p == end) return true;
  if (p > end) return false;
  if (b[p] == 0) return true;
  return _mp3IsFrameId(b, p, idLength);
}

/// Parses the frames in body[start, end). Also used for CHAP/CTOC sub frames.
List<Map<String, Object?>> _mp3ParseId3v2Frames(
    Uint8List body, int start, int end, _Mp3Id3Context ctx, Map<String, Object?>? area, int depth) {
  final frames = <Map<String, Object?>>[];
  final idLength = ctx.major == 2 ? 3 : 4;
  final headerLength = ctx.major == 2 ? 6 : 10;
  var pos = start;
  while (pos < end) {
    if (body[pos] == 0) {
      var allZero = true;
      for (var i = pos; i < end; i++) {
        if (body[i] != 0) {
          allZero = false;
          break;
        }
      }
      if (area != null) {
        area['paddingOffset'] = pos;
        area['paddingSize'] = end - pos;
        area['paddingAllZero'] = allZero;
      }
      if (!allZero) ctx.warnings.add('padding starting at offset $pos contains non-zero bytes');
      break;
    }
    if (pos + headerLength > end || !_mp3IsFrameId(body, pos, idLength)) {
      final reason = pos + headerLength > end
          ? '${end - pos} byte(s) left, too short for a frame header'
          : 'invalid frame ID "${_mp3AsciiPreview(Uint8List.sublistView(body, pos, pos + idLength))}"';
      ctx.warnings.add('frame parsing stopped at offset $pos: $reason');
      if (area != null) {
        area['unparsedOffset'] = pos;
        area['unparsedBytes'] = end - pos;
        area['unparsedHexPreview'] = _mp3HexPreview(Uint8List.sublistView(body, pos, end));
      }
      break;
    }
    final id = String.fromCharCodes(body, pos, pos + idLength);
    final frameWarnings = <String>[];
    int size;
    String sizeEncoding;
    if (ctx.major == 2) {
      size = _mp3UInt(body, pos + 3, 3);
      sizeEncoding = '24 bit big endian integer';
    } else if (ctx.major == 3) {
      size = _mp3UInt(body, pos + 4, 4);
      sizeEncoding = '32 bit big endian integer';
    } else {
      size = _mp3Syncsafe(body, pos + 4, 4);
      sizeEncoding = 'syncsafe integer (4 x 7 bit)';
      final plain = _mp3UInt(body, pos + 4, 4);
      if (plain != size) {
        final syncsafeOk = _mp3IsSyncsafe(body, pos + 4, 4) &&
            _mp3PlausibleNextFrame(body, pos + headerLength + size, end, idLength);
        if (!syncsafeOk && _mp3PlausibleNextFrame(body, pos + headerLength + plain, end, idLength)) {
          size = plain;
          sizeEncoding = '32 bit big endian integer (non-conforming, ID3v2.4 requires syncsafe)';
          frameWarnings.add('frame size is not syncsafe (written like ID3v2.3), interpreted as plain integer');
        }
      }
    }
    final dataStart = pos + headerLength;
    var dataEnd = dataStart + size;
    if (dataEnd > end) {
      frameWarnings.add('frame truncated: $size data bytes declared, ${end - dataStart} available');
      dataEnd = end;
    }
    frames.add(_mp3AnalyzeId3v2Frame(
        body, pos, id, size, sizeEncoding, headerLength, dataEnd, ctx, frameWarnings, depth));
    pos = dataStart + size;
  }
  return frames;
}

Map<String, Object?> _mp3AnalyzeId3v2Frame(Uint8List body, int pos, String id, int size, String sizeEncoding,
    int headerLength, int dataEnd, _Mp3Id3Context ctx, List<String> warnings, int depth) {
  final header = <String, Object?>{
    'hex': _mp3Hex(body, pos, pos + headerLength),
    'frameId': id,
    'size': size,
    'sizeEncoding': sizeEncoding,
  };
  final encryption = <String, Object?>{'encrypted': false};
  final frame = <String, Object?>{
    'id': id,
    'name': _mp3FrameName(id, ctx.major),
    'offsetInTagBody': pos,
    'header': header,
    'encryption': encryption,
  };
  final standard = _mp3FrameStandardInfo(id, ctx.major);
  if (standard != null) warnings.add(standard);

  final raw = Uint8List.sublistView(body, pos + headerLength, dataEnd);
  var content = raw;

  if (ctx.major >= 3) {
    final status = body[pos + 8];
    final format = body[pos + 9];
    final bool tagAlter, fileAlter, readOnly, compressed, encrypted, grouped;
    var frameUnsync = false;
    var dataLengthFlag = false;
    if (ctx.major == 3) {
      tagAlter = (status & 0x80) != 0;
      fileAlter = (status & 0x40) != 0;
      readOnly = (status & 0x20) != 0;
      compressed = (format & 0x80) != 0;
      encrypted = (format & 0x40) != 0;
      grouped = (format & 0x20) != 0;
      if ((status & 0x1F) != 0 || (format & 0x1F) != 0) warnings.add('undefined frame flag bits set');
    } else {
      tagAlter = (status & 0x40) != 0;
      fileAlter = (status & 0x20) != 0;
      readOnly = (status & 0x10) != 0;
      grouped = (format & 0x40) != 0;
      compressed = (format & 0x08) != 0;
      encrypted = (format & 0x04) != 0;
      frameUnsync = (format & 0x02) != 0;
      dataLengthFlag = (format & 0x01) != 0;
      if ((status & 0x8F) != 0 || (format & 0xB0) != 0) warnings.add('undefined frame flag bits set');
      if (compressed && !dataLengthFlag) {
        warnings.add('compression flag set without data length indicator (required by ID3v2.4)');
      }
    }
    header['flagsHex'] = _mp3Hex(body, pos + 8, pos + 10);
    header['statusFlags'] = _mp3Bin(status, 8);
    header['formatFlags'] = _mp3Bin(format, 8);
    header['flags'] = <String, Object?>{
      'tagAlterPreservation': tagAlter
          ? 'frame should be discarded when the tag is altered'
          : 'frame should be preserved when the tag is altered',
      'fileAlterPreservation': fileAlter
          ? 'frame should be discarded when the audio is altered'
          : 'frame should be preserved when the audio is altered',
      'readOnly': readOnly,
      'groupingIdentity': grouped,
      'compression': compressed,
      'encryption': encrypted,
      if (ctx.major == 4) 'unsynchronisation': frameUnsync,
      if (ctx.major == 4) 'dataLengthIndicator': dataLengthFlag,
    };

    // Additional bytes behind the frame header (order as defined per version).
    var p = 0;
    int? decompressedSize;
    int? method;
    int? group;
    int? dataLength;
    if (ctx.major == 3) {
      if (compressed) {
        if (p + 4 <= raw.length) decompressedSize = _mp3UInt(raw, p, 4);
        p += 4;
      }
      if (encrypted) {
        if (p < raw.length) method = raw[p];
        p += 1;
      }
      if (grouped) {
        if (p < raw.length) group = raw[p];
        p += 1;
      }
    } else {
      if (grouped) {
        if (p < raw.length) group = raw[p];
        p += 1;
      }
      if (encrypted) {
        if (p < raw.length) method = raw[p];
        p += 1;
      }
      if (dataLengthFlag) {
        if (p + 4 <= raw.length) dataLength = _mp3Syncsafe(raw, p, 4);
        p += 4;
      }
    }
    if (p > raw.length) {
      warnings.add('frame is too short for the additional data announced by its flags');
      p = raw.length;
    }
    if (p > 0) {
      header['additionalData'] = <String, Object?>{
        'hex': _mp3Hex(raw, 0, p),
        if (decompressedSize != null) 'decompressedSize': decompressedSize,
        if (method != null) 'encryptionMethod': method,
        if (group != null) 'groupSymbol': group,
        if (dataLength != null) 'dataLengthIndicator': dataLength,
      };
    }
    content = Uint8List.sublistView(raw, p);

    if (ctx.major == 4 && (frameUnsync || ctx.tagUnsync)) {
      final before = content.length;
      content = _mp3RemoveUnsync(content);
      frame['unsynchronisation'] = <String, Object?>{
        'source': frameUnsync ? 'frame flag' : 'tag flag',
        'removedBytes': before - content.length,
      };
    }
    if (grouped) {
      frame['grouping'] = <String, Object?>{
        'groupSymbol': group,
        if (group != null) 'groupSymbolHex': _mp3HexByte(group),
      };
    }
    if (encrypted) {
      encryption['encrypted'] = true;
      encryption['methodSymbol'] = method;
      if (method != null) encryption['methodSymbolHex'] = _mp3HexByte(method);
      encryption['encryptedBytes'] = content.length;
      encryption['dataHexPreview'] = _mp3HexPreview(content);
      encryption['note'] =
          'the method is registered by an ENCR frame with the same method symbol; without the key the content cannot be decoded';
      if (compressed) encryption['compressedBeforeEncryption'] = true;
      frame['dataBytes'] = content.length;
      frame['content'] = <String, Object?>{'decoded': false, 'reason': 'frame is encrypted'};
      if (warnings.isNotEmpty) frame['warnings'] = warnings;
      return frame;
    }
    if (compressed) {
      final compression = <String, Object?>{
        'method': 'zlib (deflate)',
        'compressedBytes': content.length,
        'declaredDecompressedSize': decompressedSize ?? dataLength,
      };
      frame['compression'] = compression;
      try {
        final out = _mp3ZlibInflate(content);
        compression['decompressedBytes'] = out.length;
        compression['success'] = true;
        final declared = decompressedSize ?? dataLength;
        if (declared != null && declared != out.length) {
          warnings.add('decompressed size ${out.length} differs from declared size $declared');
        }
        content = out;
      } catch (e) {
        compression['success'] = false;
        compression['error'] = e.toString();
        frame['dataBytes'] = content.length;
        frame['content'] = <String, Object?>{
          'decoded': false,
          'reason': 'decompression failed',
          'hexPreview': _mp3HexPreview(content),
        };
        warnings.add('decompression failed: $e');
        frame['warnings'] = warnings;
        return frame;
      }
    } else if (ctx.major == 4 && dataLength != null && dataLength != content.length) {
      warnings.add('data length indicator $dataLength differs from actual data length ${content.length}');
    }
  }

  frame['dataBytes'] = content.length;
  try {
    frame['content'] = _mp3ParseFrameContent(id, content, ctx, warnings, depth);
  } catch (e) {
    warnings.add('content analysis failed: $e');
    frame['content'] = <String, Object?>{'decoded': false, 'hexPreview': _mp3HexPreview(content)};
  }
  if (warnings.isNotEmpty) frame['warnings'] = warnings;
  return frame;
}

/// Connects encrypted / grouped frames with their ENCR / GRID registrations.
void _mp3LinkRegistrations(List<Map<String, Object?>> frames) {
  final encr = <int, String>{};
  final grid = <int, String>{};
  for (final f in frames) {
    final c = f['content'];
    if (c is! Map) continue;
    final id = f['id'];
    if (id == 'ENCR') {
      final s = c['methodSymbol'];
      if (s is int) encr[s] = '${c['ownerIdentifier']}';
    } else if (id == 'GRID') {
      final s = c['groupSymbol'];
      if (s is int) grid[s] = '${c['ownerIdentifier']}';
    }
  }
  for (final f in frames) {
    final e = f['encryption'];
    if (e is Map<String, Object?> && e['encrypted'] == true) {
      final s = e['methodSymbol'];
      e['registeredBy'] = s is int ? (encr[s] ?? 'no matching ENCR frame in this tag') : null;
    }
    final g = f['grouping'];
    if (g is Map<String, Object?>) {
      final s = g['groupSymbol'];
      g['registeredBy'] = s is int ? (grid[s] ?? 'no matching GRID frame in this tag') : null;
    }
  }
}
