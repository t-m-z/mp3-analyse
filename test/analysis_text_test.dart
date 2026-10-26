import 'dart:io';
import 'dart:typed_data';

import 'package:mp3_analyse/mp3_analyze.dart';
import 'package:test/test.dart';

void main() {
  test('colons aligned per block, nested blocks indented', () {
    final text = analysisToText(<String, Object?>{
      'name': 'Test',
      'size': 42,
      'ratio': 2.0,
      'ok': true,
      'nothing': null,
      'list': [1, 2, 3],
      'empty': <Object?>[],
      'nested': {'a': 1, 'longKey': 'x\ny'},
      'items': [
        {'id': 'A'},
        {
          'id': 'BB',
          'v': [1, 2]
        },
      ],
    });
    expect(
        text,
        'name   : Test\n'
        'size   : 42\n'
        'ratio  : 2.0\n'
        'ok     : true\n'
        'nothing: null\n'
        'list   : 1, 2, 3\n'
        'empty  : []\n'
        'nested :\n'
        '  a      : 1\n'
        '  longKey: x\n'
        '           y\n'
        'items  :\n'
        '  [0]:\n'
        '    id: A\n'
        '  [1]:\n'
        '    id: BB\n'
        '    v : 1, 2\n');
  });

  test('long value lists are wrapped in the value column', () {
    expect(analysisToText({'n': List<int>.generate(12, (i) => i + 1)}, maxLineWidth: 20),
        'n: 1, 2, 3, 4, 5, 6, 7,\n'
        '   8, 9, 10, 11, 12\n');
  });

  test('binary data is shown as byte count', () {
    expect(analysisToText({'bytes': Uint8List.fromList(List<int>.filled(70, 1))}), 'bytes: <70 bytes>\n');
  });

  test('maxListItems shortens lists', () {
    expect(
        analysisToText({
          'v': [1, 2, 3, 4],
          'm': [
            {'a': 1},
            {'a': 2},
            {'a': 3}
          ],
        }, maxListItems: 2),
        'v: 1, 2, ... 2 more\n'
        'm:\n'
        '  [0]:\n'
        '    a: 1\n'
        '  [1]:\n'
        '    a: 2\n'
        '  ... 1 more\n');
  });

  test('custom indent', () {
    expect(
        analysisToText({
          'a': {'b': 1}
        }, indent: 4),
        'a:\n    b: 1\n');
  });

  test('works for all analysis results', () {
    for (final f in Directory('test/fixtures').listSync().whereType<File>()) {
      final d = Uint8List.fromList(f.readAsBytesSync());
      final name = f.path.toLowerCase();
      final result = name.endsWith('.wav')
          ? wavAnalyze(d)
          : (name.endsWith('.mp3') || name.endsWith('.mp2') ? mp3Analyze(d) : oggAnalyze(d));
      final text = analysisToText(result, maxListItems: 5);
      expect(text, startsWith('fileSize'), reason: f.path);
      // every line of the top level block has its colon in the same column
      final top = text.split('\n').where((l) => l.isNotEmpty && !l.startsWith(' ') && !l.startsWith('.')).toList();
      final columns = top.map((l) => l.indexOf(':')).toSet();
      expect(columns.length, 1, reason: f.path);
    }
    final id3 = analysisToText(id3Analyze(Uint8List.fromList(File('test/fixtures/v23_cbr_v11.mp3').readAsBytesSync())));
    expect(id3, contains('Testtitel v2.3'));
  });
}
