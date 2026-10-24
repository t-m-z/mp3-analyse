# mp3-analyse

Analyse von MP3-, WAV- und Ogg/Vorbis-Dateien inkl. Tags – reines Dart, keine Abhängigkeiten
(nur `dart:convert` und `dart:typed_data`, läuft also auch im Web / in Flutter).

Öffentliche Funktionen:

```dart
Map<String, Object?>  mp3Analyze(Uint8List data)               // MPEG-Frames + alle Tags einer MP3-Datei
Map<String, Object?>  wavAnalyze(Uint8List data)               // WAV: Format, alle Chunks, ID3-Tags
Map<String, Object?>  oggAnalyze(Uint8List data)               // Ogg: Seiten, Streams, Vorbis-Header, Pakete
Map<String, Object?>  id3Analyze(Uint8List data)               // alle ID3-Tags (v1, v1.1, v2.2, v2.3, v2.4)
Map<String, Object?>? id3v2Analyze(Uint8List data, [int offset = 0])  // ein ID3v2-Tag ab offset
Map<String, Object?>? id3v1Analyze(Uint8List data, [int? offset])     // ein ID3v1-Tag (Standard: letzte 128 Bytes)
```

Alles andere steckt in `part`-Dateien und ist privat (Präfix `_mp3` / `_wav`,
damit es beim Einbau in eine andere Library nicht mit vorhandenen privaten
Namen kollidiert).

## Aufbau

```
lib/mp3_analyze.dart              library + mp3Analyze()
lib/src/id3_analyze.dart          öffentliche ID3-Analyse (id3Analyze, id3v2Analyze, id3v1Analyze)
lib/src/wav_analyze.dart          wavAnalyze()
lib/src/ogg_analyze.dart          oggAnalyze()
lib/src/mp3_bytes.dart            Byte-/Text-Helfer, Syncsafe, Unsynchronisation, CRC-32
lib/src/mp3_inflate.dart          eigener zlib/deflate-Decoder für komprimierte ID3v2-Frames
lib/src/mp3_mpeg_frames.dart      MPEG-Audio-Frames, Xing/Info/LAME, VBRI
lib/src/mp3_id3v1.dart            ID3v1, ID3v1.1, TAG+
lib/src/mp3_trailing_tags.dart    Blöcke am Dateiende: ID3v1, APE, Lyrics3, ID3v2.4 mit Footer
lib/src/mp3_id3v2.dart            ID3v2-Header, Extended Header, Frame-Header und -Flags
lib/src/mp3_id3v2_content.dart    Inhaltsanalyse aller Frames
lib/src/mp3_id3v2_names.dart      Frame-Namen, Versionszugehörigkeit, Genre-Tabelle
```

### In eine eigene Library einbauen

Die Dateien aus `lib/src/` übernehmen, in jeder Datei die Zeile
`part of '../mp3_analyze.dart';` auf die eigene Library anpassen und in der
eigenen Library ergänzen:

```dart
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
part 'src/id3_analyze.dart';
part 'src/wav_analyze.dart';
part 'src/ogg_analyze.dart';
```

(`dart:math` wird zusätzlich als `import 'dart:math' as math;` benötigt.)

plus die Funktion `mp3Analyze` aus `lib/mp3_analyze.dart`.
Die Imports also: `dart:convert`, `dart:math` (als `math`) und `dart:typed_data`.

## Was analysiert wird

**MPEG-Frames** – für jeden Frame: Offset, Header als Hex und Bits, alle 13
Header-Felder (Sync, Version, Layer, Protection, Bitrate, Samplingrate,
Padding, Private, Channel Mode, Mode Extension, Copyright, Original, Emphasis)
mit Bitposition, Wert und Bedeutung, dazu Framelänge, CRC, Side-Info-Größe,
Anzahl Datenbytes (`dataBytes` = Frame ohne Header/CRC, `mainDataBytes` =
zusätzlich ohne Side-Info), `main_data_begin`, Samples und Dauer.
MPEG 1/2/2.5, Layer I/II/III, Free Format, Xing-/Info-Header mit LAME-Tag
(Encoder-Delay, Padding, ReplayGain …), VBRI-Header, Resynchronisation über
Fremddaten (`unrecognizedRanges`) und eine Zusammenfassung (Dauer, CBR/VBR,
Bitratenverteilung, Durchschnittsbitrate).

**ID3v1 / ID3v1.1** – alle Felder als Liste mit Offset, Hex und Wert, Genre
(0–191 inkl. Winamp-Erweiterungen), zusätzlich der erweiterte `TAG+`-Block.

**ID3v2.2 / 2.3 / 2.4** – pro Tag: Header (Flags, Syncsafe-Größe), Extended
Header (Padding-Größe, CRC-32 inkl. Prüfung, Tag-Restrictions), Unsynchronisation
(tagweit bzw. pro Frame), Footer, Padding. Pro Frame:

* Header: ID, Name, Größe (inkl. Erkennung nicht-syncsafer Größen in v2.4),
  Status- und Format-Flags, zusätzliche Header-Bytes
* Verschlüsselung: Methodensymbol, Zuordnung zum `ENCR`-Frame, verschlüsselte Bytes
* Gruppierung (Zuordnung zum `GRID`-Frame), Kompression (zlib, wird entpackt),
  Data Length Indicator
* Inhalt: Textframes (alle Encodings, Mehrfachwerte, Genre-Auflösung, Track
  „n/m“, TLEN, TIPL/TMCL/IPLS), TXXX, URL-Frames, WXXX, COMM, USLT, USER,
  APIC/PIC (Bildformat und -größe), GEOB, UFID, PRIV, PCNT, POPM, ENCR, GRID,
  AENC, CRM, LINK, MCDI, ETCO, SYLT, SYTC, MLLT, RVA2, RVAD, EQU2, EQUA, RVRB,
  RBUF, POSS, SEEK, ASPI, SIGN, OWNE, COMR, CHAP und CTOC (mit Unterframes);
  unbekannte Frames als Hex/ASCII-Vorschau

Außerdem werden APEv1/v2- und Lyrics3-Blöcke erkannt, damit sie nicht als
Audiodaten gelten.

**WAV** (`wavAnalyze`) – Container RIFF, RIFX (Big Endian), RF64 und BW64
(64-Bit-Größen aus `ds64`), Liste aller Chunks mit Offset, Header-Hex, Größe,
Pad-Byte und Inhaltsanalyse, LIST-Chunks mit Unterchunks:

* `fmt `: Formattag (PCM, Float, A-law, µ-law, ADPCM, MP3 …), Kanäle,
  Samplerate, Byterate, BlockAlign, Bits; WAVE_FORMAT_EXTENSIBLE mit
  validBits, Kanalmaske/Lautsprecherbelegung und SubFormat-GUID; ADPCM-,
  IMA-, MPEG- und MP3-Erweiterungen; Konsistenzprüfungen
* `data`: Anzahl Sample-Frames, Dauer; bei PCM/Float pro Kanal Min/Max,
  Peak und RMS in dBFS, DC-Offset, geclippte Samples; MP3/MPEG in WAV
  wird Frame für Frame wie bei `mp3Analyze` zerlegt
* `fact`, `LIST/INFO` (INAM, IART, ICMT …), `LIST/adtl` (labl, note, ltxt,
  file), `cue `, `plst`, `smpl` (Loops, MIDI-Note, SMPTE), `inst`, `acid`,
  `bext` (BWF inkl. Loudness, Coding History), `cart`, `ds64`, `PEAK`,
  `iXML`, `axml`, `_PMX` (XMP), `chna`, `DISP`, `afsp`, `umid`, `MD5 `,
  `JUNK`/`PAD `/`FLLR`; unbekannte Chunks als Hex/ASCII-Vorschau
* ID3: `id3 `/`ID3 `-Chunks, ID3v2 vor dem RIFF-Header und ID3v1/ID3v2 hinter
  dem RIFF-Container – analysiert mit derselben ID3-Analyse wie bei MP3
* Chunks hinter dem deklarierten RIFF-Ende, nicht finalisierte Dateien
  (data-Größe 0 / 0xFFFFFFFF), fehlende Pad-Bytes, abgeschnittene Dateien

**Ogg** (`oggAnalyze`) – Ogg Vorbis, außerdem Opus, FLAC, Speex und Theora in Ogg:

* jede Seite: Capture Pattern, Version, Header-Type-Flags (continued, BOS, EOS),
  Granule Position, Serial Number, Sequence Number, CRC mit Prüfung,
  Lacing-Werte, Header-/Datenbytes und welche Pakete auf der Seite liegen
* logische Streams (einzeln, gruppiert/gemultiplext, verkettet), Pakete über
  Seitengrenzen hinweg zusammengesetzt, Lücken in der Sequenz, fehlendes EOS
* Vorbis Identification Header (Version, Kanäle, Samplerate, Bitraten,
  Blockgrößen), Comment Header (Vendor, alle Felder, METADATA_BLOCK_PICTURE
  wird dekodiert), Setup Header komplett zerlegt (Codebooks, Floors,
  Residues, Mappings, Modes)
* jedes Audiopaket: Mode, Blockgröße, Fensterflags und Anzahl dekodierter
  Samples; Abgleich mit der Granule Position (Offset am Anfang, am Ende
  abgeschnittene Samples), Dauer und Bitrate
* Opus (OpusHead, OpusTags, TOC jedes Pakets), FLAC (STREAMINFO und alle
  Metadatenblöcke), Speex-, Theora- und Skeleton-Header
* Fremddaten zwischen den Seiten, ID3v2 davor, ID3v1/APE/Lyrics3 dahinter

## Ausgabe

Eine JSON-taugliche `Map` (Struktur siehe Doku-Kommentar von `mp3Analyze`):

```dart
final result = mp3Analyze(bytes);
print(const JsonEncoder.withIndent('  ').convert(result));
```

Beispiel-Programm:

```
dart run example/mp3_analyze_example.dart datei.mp3 [--frames]
```

## Tests

```
dart pub get
dart test
```

Die Testdateien in `test/fixtures` erzeugt `tool/make_fixtures.py` (Audio mit
ffmpeg, die ID3-Tags werden von Hand gebaut, um alle Sonderfälle abzudecken),
die WAV-Testdateien `tool/make_wav_fixtures.py`, die Ogg-Testdateien
`tool/make_ogg_fixtures.py`.
