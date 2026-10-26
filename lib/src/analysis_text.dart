part of '../mp3_analyze.dart';

// ---------------------------------------------------------------------------
// Formatted text output of an analysis map.
// ---------------------------------------------------------------------------

class _TxtOptions {
  final int indent;
  final int maxLineWidth;
  final int? maxListItems;

  const _TxtOptions(this.indent, this.maxLineWidth, this.maxListItems);
}

/// Converts the result of [mp3Analyze], [wavAnalyze], [oggAnalyze],
/// [id3Analyze], [id3v2Analyze] or [id3v1Analyze] (or any other map of
/// `String`, `num`, `bool`, `null`, `List` and `Map` values) into a formatted
/// text.
///
/// * Every nesting level is indented by [indent] spaces.
/// * Within one map (one block) all keys are padded to the same width, so the
///   colons are exactly below each other.
/// * List entries are shown as `[0]`, `[1]`, ... and aligned the same way.
/// * Lists of simple values (numbers, strings ...) are written behind the
///   colon, separated by commas and wrapped at [maxLineWidth] characters;
///   continuation lines start in the value column.
/// * Multi-line strings continue in the value column as well.
/// * Binary data ([Uint8List] and other [TypedData]) is shown as
///   `<n bytes>` only.
/// * With [maxListItems] long lists (e.g. thousands of MPEG frames or Ogg
///   pages) are shortened to their first entries plus a line `... n more`.
///
/// ```text
/// fileSize : 33888
/// tagsFound: ID3v2.3.0, ID3v1.1
/// id3v2    :
///   [0]:
///     location: start of file
///     offset  : 0
///     version : ID3v2.3.0
/// ```
String analysisToText(Map<String, Object?> analysis, {int indent = 2, int maxLineWidth = 100, int? maxListItems}) {
  final out = StringBuffer();
  final o = _TxtOptions(indent < 0 ? 0 : indent, maxLineWidth < 20 ? 20 : maxLineWidth, maxListItems);
  _txtEntries(out, <MapEntry<String, Object?>>[for (final e in analysis.entries) MapEntry(e.key, e.value)], 0, o);
  return out.toString();
}

bool _txtIsScalar(Object? v) => v == null || v is num || v is bool || v is String;

String _txtScalar(Object? v) {
  if (v == null) return 'null';
  if (v is String) return v.isEmpty ? '""' : v.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (v is double) {
    if (v.isNaN || v.isInfinite) return v.toString();
    if (v == v.truncateToDouble() && v.abs() < 1e15) return v.toStringAsFixed(1);
    return v.toString();
  }
  return v.toString();
}

/// Text for a value that is written behind the colon, or null if the value
/// needs its own block (non-empty map, list with complex entries).
String? _txtInline(Object? v, int valueColumn, _TxtOptions o) {
  if (_txtIsScalar(v)) return _txtScalar(v);
  if (v is Map) return v.isEmpty ? '{}' : null;
  // Raw binary data (e.g. picture bytes) is not dumped number by number.
  if (v is TypedData) return '<${v.lengthInBytes} bytes>';
  if (v is List) {
    if (v.isEmpty) return '[]';
    if (!v.every(_txtIsScalar)) return null;
    final items = <String>[for (final x in v) _txtScalar(x)];
    if (items.any((s) => s.contains('\n'))) return null;
    final limit = o.maxListItems;
    final shown = limit != null && items.length > limit ? items.sublist(0, limit) : items;
    final rest = items.length - shown.length;
    final width = o.maxLineWidth - valueColumn < 20 ? 20 : o.maxLineWidth - valueColumn;
    final lines = <String>[];
    var line = StringBuffer();
    for (var i = 0; i < shown.length; i++) {
      final piece = i < shown.length - 1 || rest > 0 ? '${shown[i]},' : shown[i];
      if (line.isNotEmpty && line.length + 1 + piece.length > width) {
        lines.add(line.toString());
        line = StringBuffer();
      }
      if (line.isNotEmpty) line.write(' ');
      line.write(piece);
    }
    if (rest > 0) {
      final more = '... $rest more';
      if (line.isNotEmpty && line.length + 1 + more.length > width) {
        lines.add(line.toString());
        line = StringBuffer();
      }
      if (line.isNotEmpty) line.write(' ');
      line.write(more);
    }
    if (line.isNotEmpty) lines.add(line.toString());
    return lines.join('\n');
  }
  return v.toString();
}

void _txtEntries(StringBuffer out, List<MapEntry<String, Object?>> entries, int level, _TxtOptions o) {
  if (entries.isEmpty) return;
  var width = 0;
  for (final e in entries) {
    if (e.key.length > width) width = e.key.length;
  }
  final pad = ' ' * (level * o.indent);
  final valueColumn = pad.length + width + 2;
  final continuation = ' ' * valueColumn;
  for (final e in entries) {
    final key = '$pad${e.key.padRight(width)}:';
    final inline = _txtInline(e.value, valueColumn, o);
    if (inline == null) {
      out.writeln(key);
      _txtBlock(out, e.value, level + 1, o);
      continue;
    }
    final lines = inline.split('\n');
    out.writeln('$key ${lines.first}');
    for (var i = 1; i < lines.length; i++) {
      out.writeln(lines[i].isEmpty ? '' : '$continuation${lines[i]}');
    }
  }
}

void _txtBlock(StringBuffer out, Object? v, int level, _TxtOptions o) {
  if (v is Map) {
    _txtEntries(out, <MapEntry<String, Object?>>[for (final e in v.entries) MapEntry('${e.key}', e.value)], level, o);
  } else if (v is List) {
    final limit = o.maxListItems;
    final count = limit != null && v.length > limit ? limit : v.length;
    _txtEntries(out, <MapEntry<String, Object?>>[for (var i = 0; i < count; i++) MapEntry('[$i]', v[i])], level, o);
    if (count < v.length) out.writeln('${' ' * (level * o.indent)}... ${v.length - count} more');
  }
}
