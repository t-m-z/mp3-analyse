import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mp3_analyse/mp3_analyze.dart';
import 'package:test/test.dart';

Map<String, Object?> analyze(String name) =>
    mp3Analyze(Uint8List.fromList(File('test/fixtures/$name').readAsBytesSync()));

List<Map<String, Object?>> framesOf(Map<String, Object?> tag) =>
    (tag['frames'] as List).cast<Map<String, Object?>>();

Map<String, Object?> frame(Map<String, Object?> tag, String id) =>
    framesOf(tag).firstWhere((f) => f['id'] == id);

Map<String, Object?> content(Map<String, Object?> tag, String id) =>
    frame(tag, id)['content'] as Map<String, Object?>;

Map<String, Object?> summary(Map<String, Object?> r) =>
    (r['mpeg'] as Map<String, Object?>)['summary'] as Map<String, Object?>;

void main() {
  test('result is JSON encodable', () {
    for (final f in Directory('test/fixtures').listSync().whereType<File>()) {
      final r = mp3Analyze(Uint8List.fromList(f.readAsBytesSync()));
      expect(() => jsonEncode(r), returnsNormally, reason: f.path);
    }
  });

  test('empty and random input do not throw', () {
    expect(() => mp3Analyze(Uint8List(0)), returnsNormally);
    expect(() => mp3Analyze(Uint8List.fromList(List<int>.generate(5000, (i) => (i * 37) & 0xFF))),
        returnsNormally);
    expect(() => mp3Analyze(Uint8List.fromList([0x49, 0x44, 0x33, 3, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F])),
        returnsNormally);
  });

  group('ID3v2.3 + CBR + ID3v1.1', () {
    final r = analyze('v23_cbr_v11.mp3');
    final tag = (r['id3v2'] as List).first as Map<String, Object?>;

    test('tag header', () {
      expect(tag['version'], 'ID3v2.3.0');
      final flags = (tag['header'] as Map)['flags'] as Map;
      expect(flags['unsynchronisation'], true);
      expect(flags['extendedHeader'], true);
      expect(tag['totalSize'], 743);
      expect((tag['unsynchronisation'] as Map)['removedBytes'], greaterThan(0));
    });

    test('extended header with valid CRC', () {
      final ext = tag['extendedHeader'] as Map;
      expect(ext['crcDataPresent'], true);
      expect(ext['paddingSize'], 64);
      expect(ext['crcValid'], true);
      expect((tag['padding'] as Map)['size'], 64);
    });

    test('text frames', () {
      expect(content(tag, 'TIT2')['text'], 'Testtitel v2.3');
      expect(content(tag, 'TPE1')['text'], 'Künstler Ä');
      expect(content(tag, 'TRCK')['number'], 3);
      expect(content(tag, 'TRCK')['total'], 12);
      expect(content(tag, 'TCON')['genres'], ['Rock', 'Remix']);
      expect(content(tag, 'TLEN')['length'], '00:02.034');
      expect(content(tag, 'TXXX')['description'], 'MyKey');
      expect(content(tag, 'TXXX')['value'], 'MyValue');
    });

    test('comment, urls, picture, counters', () {
      final comm = content(tag, 'COMM');
      expect(comm['language'], 'deu');
      expect(comm['contentDescriptor'], 'Beschreibung');
      expect(comm['text'], 'Ein Kommentar');
      expect(content(tag, 'WXXX')['url'], 'https://example.com');
      expect(content(tag, 'WOAR')['url'], 'https://artist.example.com');
      final apic = content(tag, 'APIC');
      expect(apic['mimeType'], 'image/png');
      expect((apic['pictureType'] as Map)['name'], 'Cover (front)');
      final pic = apic['picture'] as Map;
      expect(pic['detectedFormat'], 'PNG');
      expect(pic['width'], 2);
      expect(pic['height'], 3);
      expect(content(tag, 'POPM')['rating'], 196);
      expect(content(tag, 'POPM')['counter'], 42);
      expect(content(tag, 'PCNT')['counter'], 7);
      expect(content(tag, 'UFID')['ownerIdentifier'], 'http://musicbrainz.org');
      expect(content(tag, 'PRIV')['dataBytes'], 4);
    });

    test('encryption, grouping, compression, status flags', () {
      final talb = frame(tag, 'TALB');
      final enc = talb['encryption'] as Map;
      expect(enc['encrypted'], true);
      expect(enc['methodSymbol'], 0x80);
      expect(enc['registeredBy'], 'mailto:crypto@example.com');
      expect(enc['encryptedBytes'], 7);
      expect((content(tag, 'ENCR'))['methodSymbol'], 0x80);

      final tcom = frame(tag, 'TCOM');
      expect((tcom['grouping'] as Map)['groupSymbol'], 0x90);
      expect((tcom['grouping'] as Map)['registeredBy'], 'http://group.example.com');
      expect((tcom['content'] as Map)['text'], 'Komponist');

      final tit3 = frame(tag, 'TIT3');
      expect((tit3['compression'] as Map)['success'], true);
      expect((tit3['content'] as Map)['text'], startsWith('Komprimierter Untertitel'));

      final flags = (frame(tag, 'TENC')['header'] as Map)['flags'] as Map;
      expect(flags['readOnly'], true);
      expect(flags['tagAlterPreservation'], contains('discarded'));
    });

    test('ID3v1.1', () {
      final v1 = r['id3v1'] as Map;
      expect(v1['version'], 'ID3v1.1');
      final values = v1['values'] as Map;
      expect(values['title'], 'Titel v1');
      expect(values['track'], 5);
      expect(values['genre'], 'Rock');
      expect((v1['frames'] as List).length, 9);
    });

    test('MPEG frames', () {
      final mpeg = r['mpeg'] as Map;
      final frames = (mpeg['frames'] as List).cast<Map>();
      expect(frames.length, 79);
      final first = frames.first;
      expect(first['offset'], 743);
      expect(first['mpegVersion'], 'MPEG-1');
      expect(first['layer'], 'Layer III');
      expect(first['samplingRateHz'], 44100);
      expect((first['vbrHeader'] as Map)['type'], 'Info');
      expect(((first['vbrHeader'] as Map)['lameTag'] as Map)['encoder'], startsWith('L'));
      final second = frames[1];
      expect(second['bitrateKbps'], 128);
      expect(second['sideInfoBytes'], 32);
      expect(second['dataBytes'], (second['frameLength'] as int) - 4);
      expect(((second['header'] as Map)['fields'] as List).length, 13);
      final s = summary(r);
      expect(s['bitrateMode'], 'CBR');
      expect(s['audioFrameCount'], 78);
      expect(s['unrecognizedBytes'], 0);
      expect(mpeg['audioEnd'], 33760);
    });
  });

  group('ID3v2.4 + VBR + APE + ID3v1.0', () {
    final r = analyze('v24_vbr_ape_v10.mp3');
    final tag = (r['id3v2'] as List).first as Map<String, Object?>;

    test('header, extended header, footer', () {
      expect(tag['version'], 'ID3v2.4.0');
      expect(tag['totalSize'], 597);
      final ext = tag['extendedHeader'] as Map;
      expect(ext['crcValid'], true);
      final restrictions = ext['restrictions'] as Map;
      expect(restrictions['tagSize'], contains('64 frames'));
      expect(restrictions['textEncoding'], 'only ISO-8859-1 or UTF-8');
      expect(restrictions['imageEncoding'], 'only PNG or JPEG');
      expect((tag['footer'] as Map)['matchesHeader'], true);
    });

    test('text frames with UTF-8, UTF-16BE and multiple values', () {
      expect(content(tag, 'TIT2')['text'], 'Grüße aus Bonn');
      expect(content(tag, 'TPE1')['values'], ['Artist A', 'Artist B']);
      expect(content(tag, 'TCON')['genres'], ['Rock', 'Eigenes Genre']);
      expect((content(tag, 'TIPL')['pairs'] as List).length, 2);
      expect(content(tag, 'USLT')['text'], 'La la la');
    });

    test('frame unsynchronisation, data length indicator, compression', () {
      final tope = frame(tag, 'TOPE');
      expect((tope['unsynchronisation'] as Map)['removedBytes'], 1);
      expect(((tope['header'] as Map)['additionalData'] as Map)['dataLengthIndicator'], 15);
      expect(tope['dataBytes'], 15);
      final tit3 = frame(tag, 'TIT3');
      expect((tit3['compression'] as Map)['success'], true);
      expect((tit3['content'] as Map)['text'], startsWith('Komprimiert v2.4'));
    });

    test('RVA2, chapters, non-syncsafe size', () {
      final rva2 = content(tag, 'RVA2');
      expect(((rva2['channels'] as List).first as Map)['volumeAdjustmentDb'], -2.5);
      final chap = content(tag, 'CHAP');
      expect(chap['elementId'], 'chp1');
      expect(chap['endTimeMs'], 1000);
      expect((((chap['subFrames'] as List).first as Map)['content'] as Map)['text'], 'Kapitel 1');
      final ctoc = content(tag, 'CTOC');
      expect(ctoc['childElementIds'], ['chp1']);
      expect(ctoc['topLevel'], true);
      final tcop = frame(tag, 'TCOP');
      expect((tcop['header'] as Map)['size'], 201);
      expect(tag['frameCount'], 12);
    });

    test('APE and ID3v1.0', () {
      final ape = (r['ape'] as List).first as Map;
      expect(ape['version'], 'APEv2');
      expect(((ape['items'] as List).first as Map)['value'], 'APE Titel');
      final v1 = r['id3v1'] as Map;
      expect(v1['version'], 'ID3v1.0');
      expect((v1['values'] as Map)['genre'], 'none (255)');
    });

    test('VBR stream', () {
      final s = summary(r);
      expect(s['frameCount'], 79);
      expect(s['bitrateMode'], 'VBR');
      final first = ((r['mpeg'] as Map)['frames'] as List).first as Map;
      expect((first['vbrHeader'] as Map)['type'], 'Xing');
      expect((first['vbrHeader'] as Map)['frames'], isNotNull);
      expect((r['mpeg'] as Map)['audioEnd'], 9857);
    });
  });

  group('ID3v2.2 + MPEG-2 mono', () {
    final r = analyze('v22_mpeg2_mono.mp3');
    final tag = (r['id3v2'] as List).first as Map<String, Object?>;

    test('frames', () {
      expect(tag['version'], 'ID3v2.2.0');
      expect(content(tag, 'TT2')['text'], 'Titel v2.2');
      expect(content(tag, 'TP1')['text'], 'Interpret');
      expect(content(tag, 'TCO')['genres'], ['Pop']);
      expect(content(tag, 'COM')['text'], 'Kommentar 2.2');
      final pic = content(tag, 'PIC');
      expect(pic['imageFormat'], 'JPG');
      expect((pic['picture'] as Map)['detectedFormat'], 'JPEG');
      expect((pic['picture'] as Map)['width'], 48);
      expect((pic['picture'] as Map)['height'], 64);
      expect(frame(tag, 'TCP')['warnings'], isNotEmpty);
      expect((tag['padding'] as Map)['size'], 32);
    });

    test('MPEG-2 Layer III', () {
      final frames = ((r['mpeg'] as Map)['frames'] as List).cast<Map>();
      expect(frames.length, 42);
      expect(frames.first['offset'], 199);
      expect(frames[1]['mpegVersion'], 'MPEG-2');
      expect(frames[1]['samplingRateHz'], 22050);
      expect(frames[1]['samplesPerFrame'], 576);
      expect(frames[1]['sideInfoBytes'], 9);
      expect(frames[1]['channelMode'], 'Single channel (mono)');
    });
  });

  group('Layer II with CRC and junk', () {
    final r = analyze('layer2_crc_junk.mp2');

    test('frames and resynchronisation', () {
      final mpeg = r['mpeg'] as Map;
      final frames = (mpeg['frames'] as List).cast<Map>();
      expect(frames.length, 42);
      expect(frames.first['layer'], 'Layer II');
      expect(frames.first['crcProtected'], true);
      expect(frames.first['crcBytes'], 2);
      expect(frames.first['crc'], isNotNull);
      expect(frames.first['frameLength'], 576);
      expect(frames.first['dataBytes'], 570);
      final junk = (mpeg['unrecognizedRanges'] as List).cast<Map>();
      expect(junk.length, 1);
      expect(junk.first['offset'], 5760);
      expect(junk.first['length'], 100);
      expect(r['id3v2'], isEmpty);
      expect(r['id3v1'], isNull);
    });
  });
}
