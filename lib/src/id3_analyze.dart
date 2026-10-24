part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// Public ID3 analysis (usable for any file type: MP3, WAV "id3 " chunks,
// AIFF "ID3 " chunks, raw tag dumps ...).
// ---------------------------------------------------------------------------

/// Analyses the ID3v2 tag (v2.2, v2.3 or v2.4) that starts at [offset].
///
/// Returns `null` if there is no `ID3` identifier at [offset]. The result
/// contains the tag header, extended header, unsynchronisation, footer,
/// padding and the list of all frames with a detailed analysis of each
/// frame (header, flags, encryption, grouping, compression and content).
/// All offsets in the result are relative to [data].
Map<String, Object?>? id3v2Analyze(Uint8List data, [int offset = 0]) {
  try {
    return _mp3ParseId3v2Tag(data, offset, 'offset $offset');
  } catch (e) {
    return <String, Object?>{
      'offset': offset,
      'warnings': <String>['ID3v2 analysis aborted: $e'],
      'frames': const <Object?>[],
    };
  }
}

/// Analyses the ID3v1 / ID3v1.1 tag (128 bytes, starting with `TAG`).
///
/// Without [offset] the last 128 bytes of [data] are examined. If an
/// enhanced `TAG+` block (227 bytes) precedes the tag, it is returned as
/// `enhanced`. Returns `null` if there is no ID3v1 tag.
Map<String, Object?>? id3v1Analyze(Uint8List data, [int? offset]) {
  final off = offset ?? data.length - 128;
  if (off < 0 || off + 128 > data.length || !_mp3StartsWith(data, off, 'TAG')) return null;
  final tag = _mp3ParseId3v1(data, off);
  if (off - 227 >= 0 && _mp3StartsWith(data, off - 227, 'TAG+')) {
    tag['enhanced'] = _mp3ParseId3v1Enhanced(data, off - 227);
  }
  return tag;
}

/// Finds and analyses all ID3 tags in [data]:
/// ID3v2 tags at the beginning (also several in a row), ID3v2.4 tags appended
/// at the end (located via their footer), ID3v1/ID3v1.1 and `TAG+` at the end.
/// APE and Lyrics3 blocks between audio and ID3v1 are skipped.
///
/// ```text
/// { tagsFound: [String], id3v2: [tag], id3v1: tag | null,
///   id3v1Enhanced: tag | null, warnings: [String] }
/// ```
Map<String, Object?> id3Analyze(Uint8List data) {
  final warnings = <String>[];
  final id3v2 = <Map<String, Object?>>[];
  var start = 0;
  try {
    while (start + 10 <= data.length && _mp3StartsWith(data, start, 'ID3')) {
      final tag = _mp3ParseId3v2Tag(
          data, start, start == 0 ? 'start of data' : 'directly after previous ID3v2 tag');
      if (tag == null) break;
      id3v2.add(tag);
      final total = (tag['totalSize'] as int?) ?? 0;
      if (total <= 0) break;
      start += total;
    }
  } catch (e) {
    warnings.add('ID3v2 analysis at start aborted: $e');
  }
  if (start > data.length) start = data.length;

  Map<String, Object?> trailing = const <String, Object?>{};
  try {
    trailing = _mp3AnalyzeTrailingTags(data, start);
    final appended = trailing['id3v2'];
    if (appended is List<Map<String, Object?>>) id3v2.addAll(appended);
  } catch (e) {
    warnings.add('analysis of tags at the end aborted: $e');
  }

  final v1 = trailing['id3v1'];
  return <String, Object?>{
    'tagsFound': <String>[
      for (final t in id3v2) '${t['version']}',
      if (v1 is Map) '${v1['version']}',
      if (trailing['id3v1Enhanced'] != null) 'ID3v1 enhanced (TAG+)',
    ],
    'id3v2': id3v2,
    'id3v1': v1,
    'id3v1Enhanced': trailing['id3v1Enhanced'],
    'warnings': warnings,
  };
}
