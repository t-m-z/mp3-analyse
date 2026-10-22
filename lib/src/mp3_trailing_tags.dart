part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// Blocks at the end of the file: ID3v1 (+TAG+), APEv1/v2, Lyrics3 v1/v2 and
// ID3v2.4 tags appended at the end (located via their "3DI" footer).
// They are detected so that they are not scanned as MPEG audio.
// ---------------------------------------------------------------------------

Map<String, Object?> _mp3AnalyzeTrailingTags(Uint8List data, int audioStart) {
  final out = <String, Object?>{};
  final appended = <Map<String, Object?>>[];
  final ape = <Map<String, Object?>>[];
  final lyrics = <Map<String, Object?>>[];
  var end = data.length;
  var found = true;
  var guard = 0;
  while (found && guard++ < 16) {
    found = false;

    if (!out.containsKey('id3v1') && end - 128 >= audioStart && _mp3StartsWith(data, end - 128, 'TAG')) {
      out['id3v1'] = _mp3ParseId3v1(data, end - 128);
      end -= 128;
      if (end - 227 >= audioStart && _mp3StartsWith(data, end - 227, 'TAG+')) {
        out['id3v1Enhanced'] = _mp3ParseId3v1Enhanced(data, end - 227);
        end -= 227;
      }
      found = true;
      continue;
    }

    if (end - 32 >= audioStart && _mp3StartsWith(data, end - 32, 'APETAGEX')) {
      final a = _mp3ParseApeTag(data, end - 32, audioStart);
      if (a != null) {
        ape.add(a);
        end = a['offset'] as int;
        found = true;
        continue;
      }
    }

    if (end - 15 - 11 >= audioStart && _mp3StartsWith(data, end - 9, 'LYRICS200')) {
      final size = int.tryParse(_mp3Latin1(data, end - 15, end - 9));
      if (size != null) {
        final start = end - 15 - size;
        if (start >= audioStart && _mp3StartsWith(data, start, 'LYRICSBEGIN')) {
          lyrics.add(_mp3ParseLyrics3v2(data, start, end));
          end = start;
          found = true;
          continue;
        }
      }
    }

    if (end - 9 - 11 >= audioStart && _mp3StartsWith(data, end - 9, 'LYRICSEND')) {
      final limit = end - 9 - 5100 - 11;
      for (var p = end - 9 - 11; p >= audioStart && p >= limit; p--) {
        if (_mp3StartsWith(data, p, 'LYRICSBEGIN')) {
          final text = _mp3Latin1(data, p + 11, end - 9);
          lyrics.add(<String, Object?>{
            'version': 'Lyrics3 v1',
            'offset': p,
            'offsetHex': _mp3HexOffset(p),
            'size': end - p,
            'lyricsPreview': text.length > 200 ? '${text.substring(0, 200)}...' : text,
          });
          end = p;
          found = true;
          break;
        }
      }
      if (found) continue;
    }

    if (end - 20 >= audioStart && _mp3StartsWith(data, end - 10, '3DI')) {
      final size = _mp3Syncsafe(data, end - 4, 4);
      final start = end - 20 - size;
      if (start >= audioStart) {
        final tag = _mp3ParseId3v2Tag(data, start, 'end of file (located via ID3v2.4 footer)');
        if (tag != null) {
          appended.add(tag);
          end = start;
          found = true;
          continue;
        }
      }
    }
  }
  out['audioEnd'] = end;
  out['ape'] = ape;
  out['lyrics3'] = lyrics;
  out['id3v2'] = appended;
  return out;
}

Map<String, Object?> _mp3ParseLyrics3v2(Uint8List d, int start, int end) {
  final fields = <Map<String, Object?>>[];
  const names = <String, String>{
    'IND': 'Indications field',
    'LYR': 'Lyrics multi line text',
    'INF': 'Additional information multi line text',
    'AUT': 'Lyrics/Music author name',
    'EAL': 'Extended album name',
    'EAR': 'Extended artist name',
    'ETT': 'Extended track title',
    'IMG': 'Link to an image file',
  };
  var p = start + 11;
  final fieldsEnd = end - 15;
  while (p + 8 <= fieldsEnd) {
    final id = _mp3Latin1(d, p, p + 3);
    final len = int.tryParse(_mp3Latin1(d, p + 3, p + 8));
    if (len == null || p + 8 + len > fieldsEnd) break;
    final value = _mp3Latin1(d, p + 8, p + 8 + len);
    fields.add(<String, Object?>{
      'id': id,
      'name': names[id] ?? 'unknown field',
      'size': len,
      'value': value.length > 200 ? '${value.substring(0, 200)}...' : value,
    });
    p += 8 + len;
  }
  return <String, Object?>{
    'version': 'Lyrics3 v2.00',
    'offset': start,
    'offsetHex': _mp3HexOffset(start),
    'size': end - start,
    'fields': fields,
  };
}

Map<String, Object?>? _mp3ParseApeTag(Uint8List d, int footer, int minStart) {
  final version = _mp3UIntLE(d, footer + 8, 4);
  final size = _mp3UIntLE(d, footer + 12, 4);
  final count = _mp3UIntLE(d, footer + 16, 4);
  final flags = _mp3UIntLE(d, footer + 20, 4);
  final hasHeader = (flags & 0x80000000) != 0;
  final itemsStart = footer + 32 - size;
  final tagStart = itemsStart - (hasHeader ? 32 : 0);
  if (size < 32 || itemsStart < minStart || tagStart < minStart) return null;
  const types = <String>['UTF-8 text', 'binary', 'external locator (UTF-8 URL)', 'reserved'];
  final items = <Map<String, Object?>>[];
  var p = itemsStart;
  for (var i = 0; i < count && p + 8 < footer; i++) {
    final valueLength = _mp3UIntLE(d, p, 4);
    final itemFlags = _mp3UIntLE(d, p + 4, 4);
    p += 8;
    var keyEnd = p;
    while (keyEnd < footer && d[keyEnd] != 0) {
      keyEnd++;
    }
    final key = _mp3Latin1(d, p, keyEnd);
    p = keyEnd + 1;
    if (p + valueLength > footer) break;
    final type = (itemFlags >> 1) & 0x03;
    final value = Uint8List.sublistView(d, p, p + valueLength);
    items.add(<String, Object?>{
      'key': key,
      'type': types[type],
      'readOnly': (itemFlags & 1) != 0,
      'size': valueLength,
      'value': type == 1
          ? _mp3HexPreview(value)
          : utf8.decode(value, allowMalformed: true).split('\u0000').join(' / '),
    });
    p += valueLength;
  }
  return <String, Object?>{
    'version': version == 2000 ? 'APEv2' : (version == 1000 ? 'APEv1' : 'APE (version $version)'),
    'offset': tagStart,
    'offsetHex': _mp3HexOffset(tagStart),
    'size': footer + 32 - tagStart,
    'hasHeader': hasHeader,
    'itemCount': count,
    'items': items,
  };
}
