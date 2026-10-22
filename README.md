# mp3-analyse

Analyse von MP3-Dateien inkl. ID3-Tags – reines Dart, keine Abhängigkeiten
(nur `dart:convert` und `dart:typed_data`, läuft also auch im Web / in Flutter).

```dart
Map<String, Object?> mp3Analyze(Uint8List data)
```

ist das einzige öffentliche Element. Alles andere steckt in `part`-Dateien und
ist privat (Präfix `_mp3` / `_Mp3`, damit es beim Einbau in eine andere Library
nicht mit vorhandenen privaten Namen kollidiert).

## Aufbau

```
lib/mp3_analyze.dart              library + mp3Analyze()
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
```

plus die Funktion `mp3Analyze` aus `lib/mp3_analyze.dart`.

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
ffmpeg, die ID3-Tags werden von Hand gebaut, um alle Sonderfälle abzudecken).
