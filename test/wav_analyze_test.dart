import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mp3_analyse/mp3_analyze.dart';
import 'package:test/test.dart';

Uint8List bytes(String name) => Uint8List.fromList(File('test/fixtures/$name').readAsBytesSync());

List<Map<String, Object?>> chunksOf(Map<String, Object?> r, [String key = 'chunks']) =>
    (r[key] as List).cast<Map<String, Object?>>();

Map<String, Object?> chunk(Map<String, Object?> r, String id, [int n = 0]) =>
    chunksOf(r).where((c) => c['id'] == id).elementAt(n);

Map<String, Object?> contentOf(Map<String, Object?> c) => c['content'] as Map<String, Object?>;

void main() {
  test('results are JSON encodable, odd input does not throw', () {
    for (final f in Directory('test/fixtures').listSync().whereType<File>()) {
      final d = Uint8List.fromList(f.readAsBytesSync());
      expect(() => jsonEncode(wavAnalyze(d)), returnsNormally, reason: f.path);
      expect(() => jsonEncode(id3Analyze(d)), returnsNormally, reason: f.path);
    }
    expect(() => wavAnalyze(Uint8List(0)), returnsNormally);
    expect(() => wavAnalyze(Uint8List.fromList('RIFF\x10\x00\x00\x00WAVEfmt \xff\xff'.codeUnits)), returnsNormally);
  });

  group('public ID3 analysis', () {
    test('id3v2Analyze / id3v1Analyze / id3Analyze on an MP3 file', () {
      final d = bytes('v23_cbr_v11.mp3');
      final v2 = id3v2Analyze(d)!;
      expect(v2['version'], 'ID3v2.3.0');
      expect((v2['frames'] as List).length, greaterThan(10));
      expect(id3v2Analyze(d, 5), isNull);
      final v1 = id3v1Analyze(d)!;
      expect(v1['version'], 'ID3v1.1');
      final all = id3Analyze(d);
      expect(all['tagsFound'], ['ID3v2.3.0', 'ID3v1.1']);
    });

    test('ID3v2.4 with footer and appended tag detection', () {
      final all = id3Analyze(bytes('v24_vbr_ape_v10.mp3'));
      expect(all['tagsFound'], ['ID3v2.4.0', 'ID3v1.0']);
    });
  });

  group('PCM 16 bit with many chunks', () {
    final r = wavAnalyze(bytes('wav_pcm16_chunks.wav'));

    test('container and chunk list', () {
      final c = r['container'] as Map;
      expect(c['id'], 'RIFF');
      expect(c['formType'], 'WAVE');
      expect(c['byteOrder'], 'little endian');
      expect((r['summary'] as Map)['chunkIds'],
          ['JUNK', 'fmt ', 'LIST', 'bext', 'cue ', 'LIST', 'smpl', 'inst', 'acid', 'data', 'id3 ']);
      expect(contentOf(chunk(r, 'JUNK'))['allZero'], true);
      expect(chunk(r, 'bext')['paddingByte'], true);
      expect(r['trailingData'], isNull);
      expect(r['warnings'], isEmpty);
    });

    test('fmt and summary', () {
      final f = r['format'] as Map;
      expect(f['formatName'], 'PCM (integer)');
      expect(f['channels'], 2);
      expect(f['sampleRate'], 44100);
      expect(f['bitsPerSample'], 16);
      expect(f['blockAlign'], 4);
      expect(f['byteRate'], 176400);
      final s = r['summary'] as Map;
      expect(s['sampleFrames'], 11025);
      expect(s['duration'], '00:00.250');
      expect(s['bitrateKbps'], 1411.2);
      expect(s['broadcastWave'], true);
    });

    test('data statistics', () {
      final stats = contentOf(chunk(r, 'data'))['statistics'] as Map;
      final ch = (stats['channels'] as List).cast<Map>();
      expect(ch[0]['maxSample'], 16383);
      expect(ch[0]['peakDbfs'] as double, closeTo(-6.02, 0.01));
      expect(ch[0]['rmsDbfs'] as double, closeTo(-9.03, 0.01));
      expect(ch[1]['peakDbfs'] as double, closeTo(-18.06, 0.01));
      expect(ch[0]['clippedSamples'], 0);
    });

    test('LIST INFO and adtl', () {
      expect(r['info'], {'INAM': 'Testton', 'IART': 'Künstler', 'ICMT': 'ungerade'});
      final info = chunk(r, 'LIST');
      expect(contentOf(info)['listType'], 'INFO');
      final sub = (info['subChunks'] as List).cast<Map<String, Object?>>();
      expect(sub[2]['name'], 'Comment');
      expect(sub[2]['paddingByte'], true);
      final adtl = chunk(r, 'LIST', 1);
      expect(contentOf(adtl)['listType'], 'adtl');
      final labels = (adtl['subChunks'] as List).cast<Map<String, Object?>>();
      expect(contentOf(labels[0])['text'], 'Anfang');
      expect(contentOf(labels[1])['cuePointId'], 2);
      expect(contentOf(labels[2])['purposeMeaning'], 'region');
      expect(contentOf(labels[2])['text'], 'Region');
    });

    test('bext, cue, smpl, inst, acid', () {
      final b = contentOf(chunk(r, 'bext'));
      expect(b['description'], 'BWF Beschreibung');
      expect(b['originationDate'], '2026-10-24');
      expect(b['timeReference'], '1:00:00.000');
      expect(b['version'], 2);
      expect(b['loudnessValueLufs'], -23.0);
      expect(b['maxMomentaryLoudnessLufs'], isNull);
      expect(b['codingHistory'], startsWith('A=PCM'));
      final cue = contentOf(chunk(r, 'cue '));
      expect(cue['cuePointCount'], 2);
      expect(((cue['cuePoints'] as List)[1] as Map)['sampleOffset'], 5512);
      final smpl = contentOf(chunk(r, 'smpl'));
      expect(smpl['midiUnityNoteName'], 'C4');
      expect(smpl['midiPitchFractionCents'], 50.0);
      expect(smpl['smpteFormat'], '25 fps');
      expect(smpl['smpteOffset'], '01:02:03:04');
      expect(((smpl['loops'] as List).first as Map)['endSample'], 5000);
      final inst = contentOf(chunk(r, 'inst'));
      expect(inst['fineTuneCents'], -5);
      expect(inst['gainDb'], -3);
      final acid = contentOf(chunk(r, 'acid'));
      expect(acid['tempoBpm'], 120.0);
      expect(acid['meter'], '4/4');
    });

    test('ID3 tags in the id3 chunk and behind the RIFF container', () {
      expect(r['tagsFound'], ['ID3v2.3.0', 'ID3v1.1', 'RIFF LIST/INFO', 'BWF bext']);
      final tag = (r['id3v2'] as List).first as Map<String, Object?>;
      expect(tag['offset'], 45174);
      final title = (tag['frames'] as List).cast<Map>().firstWhere((f) => f['id'] == 'TIT2');
      expect((title['content'] as Map)['text'], 'Testtitel v2.3');
      expect(contentOf(chunk(r, 'id3 '))['id3v2Index'], 0);
      final v1 = (r['id3v1'] as List).first as Map;
      expect((v1['values'] as Map)['title'], 'WAV v1');
      expect((v1['values'] as Map)['track'], 9);
    });
  });

  group('other formats', () {
    test('IEEE float with fact and PEAK', () {
      final r = wavAnalyze(bytes('wav_float32_peak.wav'));
      final f = r['format'] as Map;
      expect(f['formatName'], 'IEEE float');
      expect(f['extensionSize'], 0);
      expect(contentOf(chunk(r, 'fact'))['sampleLength'], 4800);
      final peak = (contentOf(chunk(r, 'PEAK'))['channels'] as List).cast<Map>();
      expect(peak[0]['peak'], 1.25);
      expect(peak[1]['positionSampleFrame'], 1200);
      final ch = ((contentOf(chunk(r, 'data'))['statistics'] as Map)['channels'] as List).cast<Map>();
      expect(ch[0]['maxSample'], 1.25);
      expect(ch[0]['clippedSamples'], 1);
      expect(ch[1]['peakDbfs'] as double, closeTo(-18.06, 0.01));
    });

    test('RIFX (big endian)', () {
      final r = wavAnalyze(bytes('wav_rifx_mono.wav'));
      expect((r['container'] as Map)['byteOrder'], 'big endian');
      expect((r['format'] as Map)['sampleRate'], 8000);
      final ch = ((contentOf(chunk(r, 'data'))['statistics'] as Map)['channels'] as List).cast<Map>();
      expect(ch.single['maxSample'], 16384);
      expect(ch.single['minSample'], -16384);
      expect((r['summary'] as Map)['duration'], '00:00.100');
    });

    test('RF64, 24 bit, 5.1, WAVE_FORMAT_EXTENSIBLE', () {
      final r = wavAnalyze(bytes('wav_rf64_24bit_5_1.wav'));
      expect((r['container'] as Map)['id'], 'RF64');
      expect((r['container'] as Map)['sizeSource'], 'ds64 chunk');
      expect(contentOf(chunk(r, 'ds64'))['dataSize'], 86400);
      final data = chunk(r, 'data');
      expect(data['size'], 86400);
      expect(data['sizeSource'], 'ds64 chunk');
      final f = r['format'] as Map;
      expect(f['formatName'], 'WAVE_FORMAT_EXTENSIBLE');
      expect(f['effectiveFormatName'], 'PCM (integer)');
      expect(f['channelMask'], 0x3F);
      expect((f['channelLayout'] as List).length, 6);
      expect((f['extensible'] as Map)['validBitsPerSample'], 24);
      expect((r['summary'] as Map)['sampleFrames'], 4800);
      final stats = contentOf(data)['statistics'] as Map;
      expect(stats['sampleFormat'], '24 bit signed integer');
      expect((stats['channels'] as List).length, 6);
    });

    test('MP3 inside WAV', () {
      final r = wavAnalyze(bytes('wav_mp3.wav'));
      final f = r['format'] as Map;
      expect(f['formatTag'], 0x55);
      expect((f['mpegLayer3'] as Map)['blockSize'], greaterThan(0));
      expect(contentOf(chunk(r, 'fact'))['sampleLength'], 45205);
      final mpeg = contentOf(chunk(r, 'data'))['mpeg'] as Map;
      final frames = (mpeg['frames'] as List).cast<Map>();
      expect(frames, isNotEmpty);
      expect(frames.first['layer'], 'Layer III');
      expect(frames.first['samplingRateHz'], 44100);
      expect(r['info'], contains('ISFT'));
    });
  });
}
