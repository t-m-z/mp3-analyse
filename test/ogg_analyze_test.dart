import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mp3_analyse/mp3_analyze.dart';
import 'package:test/test.dart';

Map<String, Object?> analyze(String name) =>
    oggAnalyze(Uint8List.fromList(File('test/fixtures/$name').readAsBytesSync()));

List<Map<String, Object?>> streamsOf(Map<String, Object?> r) => (r['streams'] as List).cast<Map<String, Object?>>();

Map<String, Object?> summary(Map<String, Object?> r) => r['summary'] as Map<String, Object?>;

Map<String, Object?> headers(Map<String, Object?> stream) => stream['headers'] as Map<String, Object?>;

Map<String, Object?> stats(Map<String, Object?> stream) => stream['packetStatistics'] as Map<String, Object?>;

void main() {
  test('results are JSON encodable, odd input does not throw', () {
    for (final f in Directory('test/fixtures').listSync().whereType<File>()) {
      final r = oggAnalyze(Uint8List.fromList(f.readAsBytesSync()));
      expect(() => jsonEncode(r), returnsNormally, reason: f.path);
    }
    expect(() => oggAnalyze(Uint8List(0)), returnsNormally);
    expect(() => oggAnalyze(Uint8List.fromList('OggS\x00\x02'.codeUnits + List<int>.filled(30, 0xFF))),
        returnsNormally);
  });

  group('Ogg Vorbis', () {
    final r = analyze('ogg_vorbis.ogg');
    final s = streamsOf(r).single;

    test('pages', () {
      final pages = (r['pages'] as List).cast<Map<String, Object?>>();
      expect(pages.length, 5);
      expect(summary(r)['crcErrors'], 0);
      expect(pages.every((p) => p['crcValid'] == true), isTrue);
      final first = pages.first;
      expect(first['offset'], 0);
      expect((first['headerType'] as Map)['beginOfStream'], true);
      expect(first['granulePosition'], 0);
      expect(first['pageSequence'], 0);
      expect(first['segmentCount'], 1);
      expect(first['dataBytes'], 30);
      expect(((pages.last['headerType'] as Map)['endOfStream']), true);
      expect(pages.last['granulePosition'], 132300);
      expect(summary(r)['structure'], 'single logical stream');
      expect(r['warnings'], isEmpty);
    });

    test('identification header', () {
      final id = headers(s)['identification'] as Map;
      expect(id['vorbisVersion'], 0);
      expect(id['audioChannels'], 2);
      expect(id['audioSampleRate'], 44100);
      expect(id['bitrateNominal'], 112000);
      expect(id['blocksize0'], 256);
      expect(id['blocksize1'], 2048);
      expect(id['framingFlag'], 1);
      expect(s['codec'], 'vorbis');
    });

    test('comment header with picture', () {
      final values = r['comments'] as Map;
      expect(values['TITLE'], ['Testtitel Vorbis']);
      expect(values['ARTIST'], ['Künstler']);
      expect(values['TRACKNUMBER'], ['7']);
      final c = headers(s)['comment'] as Map;
      expect(c['vendor'], isNotEmpty);
      expect(c['framingBit'], 1);
      final pic = (c['comments'] as List).cast<Map>().firstWhere((e) => e['field'] == 'METADATA_BLOCK_PICTURE');
      final p = pic['picture'] as Map;
      expect((p['pictureType'] as Map)['name'], 'Cover (front)');
      expect(p['mimeType'], 'image/png');
      expect(p['description'], 'Cover');
      expect(p['width'], 2);
      expect(((p['picture'] as Map)['detectedFormat']), 'PNG');
      expect(r['tagsFound'], ['Vorbis comment (Vorbis comment format)']);
    });

    test('setup header', () {
      final setup = headers(s)['setup'] as Map;
      expect(setup['complete'], true);
      expect(setup['codebookCount'], 38);
      expect((setup['codebooks'] as List).length, 38);
      final modes = (setup['modes'] as List).cast<Map>();
      expect(modes.map((m) => m['blockflag']), [0, 1]);
      expect(modes.map((m) => m['blockSize']), [256, 2048]);
      expect(setup['framingFlag'], 1);
      expect((setup['floors'] as List), isNotEmpty);
      expect((setup['mappings'] as List), isNotEmpty);
    });

    test('audio packets, granule check, duration', () {
      expect(s['packetCount'], 134);
      final st = stats(s);
      expect(st['dataPackets'], 131);
      expect(st['shortBlocks'], 1);
      expect(st['longBlocks'], 130);
      expect(st['decodedSamples'], 132672);
      expect(st['granuleOffset'], 0);
      expect(st['samplesTrimmedAtEnd'], 372);
      expect(st['granuleMismatches'], 0);
      final packets = (s['packets'] as List).cast<Map>();
      expect(packets[0]['type'], 'identification header');
      expect(packets[1]['type'], 'comment header');
      expect(packets[2]['type'], 'setup header');
      expect(packets[3]['type'], 'audio');
      expect(packets[3]['samples'], 0);
      expect(s['durationSeconds'], 3.0);
      expect(summary(r)['duration'], '00:03.000');
      expect(s['endOfStream'], true);
    });
  });

  test('damaged file: CRC error and junk', () {
    final r = analyze('ogg_vorbis_damaged.ogg');
    expect(summary(r)['crcErrors'], 1);
    expect(summary(r)['unrecognizedBytes'], 8);
    final junk = (r['unrecognizedRanges'] as List).cast<Map>().single;
    expect(junk['length'], 8);
    expect(junk['asciiPreview'], 'JUNKJUNK');
    expect(summary(r)['pageCount'], 5);
    expect(r['warnings'], isNotEmpty);
  });

  test('chained Vorbis streams', () {
    final r = analyze('ogg_chained.ogg');
    expect(summary(r)['streamCount'], 2);
    expect(summary(r)['structure'], 'chained (streams one after another)');
    expect(summary(r)['durationSeconds'], 3.5);
    final s2 = streamsOf(r)[1];
    expect((headers(s2)['identification'] as Map)['audioChannels'], 1);
    expect(stats(s2)['granuleOffset'], -30);
  });

  test('Ogg Opus', () {
    final r = analyze('ogg_opus.opus');
    final s = streamsOf(r).single;
    expect(s['codec'], 'opus');
    final head = headers(s)['identification'] as Map;
    expect(head['channels'], 2);
    expect(head['preSkip'], 312);
    expect(head['inputSampleRate'], 48000);
    expect((r['comments'] as Map)['TITLE'], ['Opus Test']);
    final st = stats(s);
    expect(st['dataPackets'], 51);
    expect(st['decodedSamples'], 48960);
    expect(st['samplesTrimmedAtEnd'], 648);
    expect(s['durationSeconds'], 1.0);
    final audio = (s['packets'] as List).cast<Map>()[2];
    expect(audio['mode'], 'CELT');
    expect(audio['frameSizeMs'], 20.0);
  });

  test('FLAC in Ogg', () {
    final r = analyze('ogg_flac.oga');
    final s = streamsOf(r).single;
    expect(s['codec'], 'flac');
    final info = (headers(s)['identification'] as Map)['streamInfo'] as Map;
    expect(info['blockTypeName'], 'STREAMINFO');
    expect(info['sampleRate'], 44100);
    expect(info['channels'], 1);
    expect(info['bitsPerSample'], 16);
    expect((r['comments'] as Map)['TITLE'], ['FLAC in Ogg']);
    expect(stats(s)['decodedSamples'], 22050);
    expect(s['durationSeconds'], 0.5);
  });

  test('Speex', () {
    final r = analyze('ogg_speex.spx');
    final s = streamsOf(r).single;
    expect(s['codec'], 'speex');
    final h = headers(s)['identification'] as Map;
    expect(h['rate'], 16000);
    expect(h['mode'], 'wideband');
    expect(h['frameSize'], 320);
    expect(s['durationSeconds'] as double, closeTo(15857 / 16000, 1e-9));
  });

  test('Theora + Vorbis (grouped)', () {
    final r = analyze('ogg_theora_vorbis.ogv');
    expect(summary(r)['structure'], 'grouped (multiplexed)');
    expect(summary(r)['codecs'], containsAll(<String>['Theora (video)', 'Vorbis']));
    final theora = streamsOf(r).firstWhere((s) => s['codec'] == 'theora');
    final id = headers(theora)['identification'] as Map;
    expect(id['pictureWidth'], 64);
    expect(id['pictureHeight'], 48);
    expect(id['frameRate'], 10.0);
    expect(theora['durationSeconds'], 1.0);
    expect(summary(r)['durationSeconds'], 1.0);
  });
}
