// Usage: dart run example/mp3_analyze_example.dart <file.mp3|file.wav> [--frames]
//
// Prints the analysis as JSON. Without --frames the (long) list of MPEG
// frames is shortened to the first three frames.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mp3_analyse/mp3_analyze.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/mp3_analyze_example.dart <file.mp3|file.wav> [--frames]');
    exit(64);
  }
  final bytes = Uint8List.fromList(File(args.first).readAsBytesSync());
  final isWav = args.first.toLowerCase().endsWith('.wav');
  final result = isWav ? wavAnalyze(bytes) : mp3Analyze(bytes);
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
  print(const JsonEncoder.withIndent('  ').convert(result));
}
