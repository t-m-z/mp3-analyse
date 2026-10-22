/// Analysis of MP3 files.
///
/// The only public member of this library is [mp3Analyze]. All helpers live
/// in `part` files and are library private (prefixed with `_mp3` / `_Mp3`
/// so they do not clash when the parts are moved into another library).
///
/// Covered:
/// * MPEG audio frames (MPEG 1 / 2 / 2.5, Layer I / II / III) with a full
///   header bit analysis, CRC, side information, data bytes, free format,
///   Xing/Info (+ LAME tag) and VBRI headers, resynchronisation over junk.
/// * ID3v1, ID3v1.1 and the enhanced "TAG+" block.
/// * ID3v2.2, ID3v2.3 and ID3v2.4 (header, extended header incl. CRC check
///   and restrictions, unsynchronisation, footer, padding, frame headers and
///   flags, compression (own zlib inflater, no dart:io), encryption, grouping,
///   data length indicator and a content analysis for every defined frame,
///   including the CHAP/CTOC addendum with embedded sub frames).
/// * Detection of APEv1/APEv2 and Lyrics3 v1/v2 blocks, so they are not
///   misinterpreted as audio data.
library mp3_analyze;

import 'dart:convert';
import 'dart:typed_data';

part 'src/mp3_bytes.dart';
part 'src/mp3_inflate.dart';
part 'src/mp3_mpeg_frames.dart';
part 'src/mp3_id3v1.dart';
part 'src/mp3_trailing_tags.dart';
part 'src/mp3_id3v2.dart';
part 'src/mp3_id3v2_content.dart';
part 'src/mp3_id3v2_names.dart';

/// Analyses the bytes of an MP3 file.
///
/// The result is a JSON compatible map (only `String`, `num`, `bool`,
/// `null`, `List` and `Map<String, ...>` values), so it can be printed with
/// `JsonEncoder.withIndent('  ').convert(...)` or walked directly:
///
/// ```text
/// {
///   fileSize:      int
///   tagsFound:     [String]                  e.g. ["ID3v2.3.0", "ID3v1.1"]
///   id3v2:         [ tag ]                   all ID3v2 tags (start and end of file)
///       tag = { version, offset, header{hex, flags, size ...},
///               extendedHeader?, unsynchronisation?, footer?, padding?,
///               frameCount, frames: [ frame ], warnings }
///       frame = { id, name, header{hex, size, flags ...}, encryption{...},
///                 grouping?, compression?, unsynchronisation?,
///                 dataBytes, content{...}, warnings? }
///   id3v1:         { version, offset, frames: [ field ], values{...} } | null
///   id3v1Enhanced: { ... } | null            "TAG+" block
///   ape:           [ ... ]                   APE tags (only detected/listed)
///   lyrics3:       [ ... ]                   Lyrics3 blocks (only detected/listed)
///   mpeg: {
///     audioStart, audioEnd,
///     summary{ frameCount, durationSeconds, bitrateMode, ... },
///     frames: [ { index, offset, header{hex, bits, fields[...]},
///                 mpegVersion, layer, bitrateKbps, samplingRateHz, ...,
///                 frameLength, crcBytes, sideInfoBytes, dataBytes, ... } ],
///     unrecognizedRanges: [ { offset, length, ... } ]
///   }
///   warnings:      [String]
/// }
/// ```
Map<String, Object?> mp3Analyze(Uint8List data) {
  final warnings = <String>[];
  final id3v2Tags = <Map<String, Object?>>[];

  // ID3v2 tag(s) at the beginning of the file.
  var audioStart = 0;
  try {
    while (audioStart + 10 <= data.length &&
        _mp3StartsWith(data, audioStart, 'ID3')) {
      final tag = _mp3ParseId3v2Tag(data, audioStart,
          audioStart == 0 ? 'start of file' : 'directly after previous ID3v2 tag');
      if (tag == null) break;
      id3v2Tags.add(tag);
      final total = (tag['totalSize'] as int?) ?? 0;
      if (total <= 0) break;
      audioStart += total;
      if (audioStart > data.length) audioStart = data.length;
    }
  } catch (e) {
    warnings.add('ID3v2 analysis at start of file aborted: $e');
  }

  // Tags at the end of the file (ID3v1, TAG+, APE, Lyrics3, appended ID3v2).
  var audioEnd = data.length;
  Map<String, Object?> trailing = <String, Object?>{};
  try {
    trailing = _mp3AnalyzeTrailingTags(data, audioStart);
    audioEnd = (trailing['audioEnd'] as int?) ?? data.length;
    final appended = trailing['id3v2'];
    if (appended is List<Map<String, Object?>>) id3v2Tags.addAll(appended);
  } catch (e) {
    warnings.add('analysis of tags at end of file aborted: $e');
  }

  // MPEG audio frames between the tags.
  Map<String, Object?>? mpeg;
  try {
    mpeg = _mp3AnalyzeMpegStream(data, audioStart, audioEnd);
  } catch (e) {
    warnings.add('MPEG frame analysis aborted: $e');
  }

  final tagsFound = <String>[
    for (final t in id3v2Tags) '${t['version']}',
    if (trailing['id3v1'] is Map) '${(trailing['id3v1'] as Map)['version']}',
    if (trailing['id3v1Enhanced'] != null) 'ID3v1 enhanced (TAG+)',
    for (final a in (trailing['ape'] as List?) ?? const []) '${(a as Map)['version']}',
    for (final l in (trailing['lyrics3'] as List?) ?? const [])
      '${(l as Map)['version']}',
  ];

  for (final t in id3v2Tags) {
    final w = t['warnings'];
    if (w is List && w.isNotEmpty) {
      warnings.add('${t['version']} at offset ${t['offset']}: ${w.length} warning(s), see tag');
    }
  }

  return <String, Object?>{
    'fileSize': data.length,
    'tagsFound': tagsFound,
    'id3v2': id3v2Tags,
    'id3v1': trailing['id3v1'],
    'id3v1Enhanced': trailing['id3v1Enhanced'],
    'ape': trailing['ape'] ?? const <Object?>[],
    'lyrics3': trailing['lyrics3'] ?? const <Object?>[],
    'mpeg': mpeg,
    'warnings': warnings,
  };
}
