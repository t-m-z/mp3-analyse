// Usage: dart run example/mp3_analyze_example.dart <file.mp3|file.wav|file.ogg> [--frames] [--text]
//
// Prints the analysis as JSON (or with --text as formatted text). Without --frames the (long) list of MPEG
// frames is shortened to the first three frames.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mp3_analyse/mp3_analyze.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/mp3_analyze_example.dart <file.mp3|file.wav|file.ogg> [--frames] [--text]');
    exit(64);
  }
  final bytes = Uint8List.fromList(File(args.first).readAsBytesSync());
  final name = args.first.toLowerCase();
  final isWav = name.endsWith('.wav');
  final isOgg = const ['.ogg', '.oga', '.ogv', '.opus', '.spx'].any(name.endsWith);
  final result = isWav ? wavAnalyze(bytes) : (isOgg ? oggAnalyze(bytes) : mp3Analyze(bytes));
  if (isOgg && !args.contains('--frames')) {
    final pages = result['pages'] as List;
    if (pages.length > 3) result['pages'] = [...pages.take(3), '... ${pages.length - 3} more pages (use --frames)'];
    for (final s in (result['streams'] as List).cast<Map<String, Object?>>()) {
      final packets = s['packets'] as List;
      if (packets.length > 6) s['packets'] = [...packets.take(6), '... ${packets.length - 6} more packets (use --frames)'];
    }
  }
  final dataChunk = isWav
      ? ((result['chunks'] as List?) ?? const []).cast<Map<String, Object?>>().where((c) => c['id'] == 'data').firstOrNull
      : null;
  final dataContent = dataChunk?['content'];
  final mpeg = isWav ? (dataContent is Map ? dataContent['mpeg'] : null) : result['mpeg'];
  if (!args.contains('--frames') && mpeg is Map<String, Object?>) {
    final frames = mpeg['frames'] as List;
    if (frames.length > 3) {
      mpeg['frames'] = [...frames.take(3), '... ${frames.length - 3} more frames (use --frames)'];
    }
  }
  print(args.contains('--text') ? analysisToText(result) : const JsonEncoder.withIndent('  ').convert(result));
}
