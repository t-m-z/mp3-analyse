#!/usr/bin/env python3
"""Builds the test fixtures in test/fixtures.

Audio payloads are generated with ffmpeg (libmp3lame / libtwolame) beforehand:

  ffmpeg -f lavfi -i "sine=frequency=440:duration=2" -ac 2 -ar 44100 -c:a libmp3lame -b:a 128k -id3v2_version 0 -write_id3v1 0 cbr.mp3
  ffmpeg -f lavfi -i "sine=frequency=660:duration=2" -ac 2 -ar 44100 -c:a libmp3lame -q:a 4   -id3v2_version 0 -write_id3v1 0 vbr.mp3
  ffmpeg -f lavfi -i "sine=frequency=330:duration=1" -ac 1 -ar 22050 -c:a libmp3lame -b:a 32k -id3v2_version 0 -write_id3v1 0 mono22.mp3
  ffmpeg -f lavfi -i "sine=frequency=550:duration=1" -ac 2 -ar 48000 -c:a libtwolame -b:a 192k -error_protection 1 -f mp2 l2crc.mp2

Usage: make_fixtures.py <dir with the four audio files> <output dir>
The ID3 tags are written by hand (not with a library) so that every version
and every special case (unsynchronisation, compression, encryption, grouping,
extended header with CRC, footer, chapters ...) is exercised.
"""
import struct
import sys
import zlib
from pathlib import Path


def syncsafe(n, length=4):
    out = []
    for _ in range(length):
        out.append(n & 0x7F)
        n >>= 7
    return bytes(reversed(out))


def unsync(data):
    out = bytearray()
    for i, b in enumerate(data):
        out.append(b)
        if b == 0xFF and (i + 1 == len(data) or data[i + 1] == 0x00 or data[i + 1] & 0xE0 == 0xE0):
            out.append(0x00)
    return bytes(out)


def latin1(s):
    return s.encode('latin-1')


def utf16(s):
    return b'\xff\xfe' + s.encode('utf-16-le')


# valid 2x3 RGBA PNG (black), decodable by browsers / image libraries
PNG_2x3 = bytes.fromhex(
    '89504E470D0A1A0A0000000D4948445200000002000000030806000000B9EADE'
    '81000000104944415478DA63606060F80FC5680C0047D305FB7877591D000000'
    '0049454E44AE426082')
JPEG_HEAD = bytes.fromhex('FFD8FFE000104A46494600010100000100010000FFC00011080040003003012200021101031101FFD9')


# --------------------------------------------------------------------------- v2.3

def frame23(fid, data, status=0, fmt=0, extra=b''):
    payload = extra + data
    return latin1(fid) + struct.pack('>I', len(payload)) + bytes([status, fmt]) + payload


def tag_v23():
    frames = b''
    frames += frame23('TIT2', b'\x00' + latin1('Testtitel v2.3'))
    frames += frame23('TPE1', b'\x01' + utf16('Künstler Ä') + b'\x00\x00')
    frames += frame23('TRCK', b'\x00' + latin1('3/12'))
    frames += frame23('TCON', b'\x00' + latin1('(17)(RX)'))
    frames += frame23('TLEN', b'\x00' + latin1('2034'))
    frames += frame23('COMM', b'\x00' + latin1('deu') + latin1('Beschreibung') + b'\x00' + latin1('Ein Kommentar'))
    frames += frame23('TXXX', b'\x00' + latin1('MyKey') + b'\x00' + latin1('MyValue'))
    frames += frame23('WXXX', b'\x00' + latin1('Homepage') + b'\x00' + latin1('https://example.com'))
    frames += frame23('WOAR', latin1('https://artist.example.com'))
    frames += frame23('APIC', b'\x00' + latin1('image/png') + b'\x00' + b'\x03' + latin1('Cover') + b'\x00' + PNG_2x3)
    frames += frame23('POPM', latin1('rater@example.com') + b'\x00' + bytes([196]) + struct.pack('>I', 42))
    frames += frame23('PCNT', struct.pack('>I', 7))
    frames += frame23('UFID', latin1('http://musicbrainz.org') + b'\x00' + latin1('abc-123'))
    frames += frame23('PRIV', latin1('WM/Provider') + b'\x00' + b'\x01\x02\x03\x04')
    # encryption method registration + encrypted frame
    frames += frame23('ENCR', latin1('mailto:crypto@example.com') + b'\x00' + b'\x80' + b'\xAA\xBB')
    frames += frame23('TALB', b'\x13\x37\xC0\xDE\xFF\x00\x12', fmt=0x40, extra=b'\x80')
    # group registration + grouped frame
    frames += frame23('GRID', latin1('http://group.example.com') + b'\x00' + b'\x90' + b'\x01')
    frames += frame23('TCOM', b'\x00' + latin1('Komponist'), fmt=0x20, extra=b'\x90')
    # compressed frame (4 byte decompressed size precedes the zlib data)
    text = b'\x00' + latin1('Komprimierter Untertitel ' * 4)
    frames += frame23('TIT3', zlib.compress(text), fmt=0x80, extra=struct.pack('>I', len(text)))
    # status flags: tag alter preservation + read only
    frames += frame23('TENC', b'\x00' + latin1('make_fixtures.py'), status=0xA0)

    padding = b'\x00' * 64
    crc = zlib.crc32(frames) & 0xFFFFFFFF
    ext = struct.pack('>I', 10) + b'\x80\x00' + struct.pack('>I', len(padding)) + struct.pack('>I', crc)
    body = ext + frames + padding
    body = unsync(body)
    header = b'ID3\x03\x00' + bytes([0x80 | 0x40]) + syncsafe(len(body))
    return header + body


# --------------------------------------------------------------------------- v2.4

def frame24(fid, data, status=0, fmt=0, extra=b''):
    payload = extra + data
    return latin1(fid) + syncsafe(len(payload)) + bytes([status, fmt]) + payload


def tag_v24():
    frames = b''
    frames += frame24('TIT2', b'\x03' + 'Grüße aus Bonn'.encode('utf-8'))
    frames += frame24('TPE1', b'\x03' + b'Artist A\x00Artist B')
    frames += frame24('TDRC', b'\x00' + latin1('2026-10-22'))
    frames += frame24('TCON', b'\x00' + latin1('17\x00Eigenes Genre'))
    frames += frame24('TIPL', b'\x00' + latin1('producer\x00Max\x00mix\x00Moritz'))
    frames += frame24('USLT', b'\x02' + latin1('eng') + b'\x00\x00' + 'La la la'.encode('utf-16-be'))
    # unsynchronised frame with data length indicator
    raw = b'\x00' + b'\xFF\xE7 unsync test'
    frames += frame24('TOPE', unsync(raw), fmt=0x02 | 0x01, extra=syncsafe(len(raw)))
    # compressed frame with data length indicator
    text = b'\x03' + 'Komprimiert v2.4 '.encode('utf-8') * 5
    frames += frame24('TIT3', zlib.compress(text), fmt=0x08 | 0x01, extra=syncsafe(len(text)))
    # RVA2: master volume -2.5 dB, 16 bit peak
    frames += frame24('RVA2', latin1('track') + b'\x00' + b'\x01' + struct.pack('>h', -1280) + b'\x10' + b'\x7F\xFF')
    # chapters
    sub = frame24('TIT2', b'\x00' + latin1('Kapitel 1'))
    frames += frame24('CHAP', latin1('chp1') + b'\x00' + struct.pack('>IIII', 0, 1000, 0xFFFFFFFF, 0xFFFFFFFF) + sub)
    sub2 = frame24('TIT2', b'\x00' + latin1('Inhalt'))
    frames += frame24('CTOC', latin1('toc') + b'\x00' + b'\x03' + b'\x01' + latin1('chp1') + b'\x00' + sub2)
    # non-standard size bug (plain 32 bit integer in a v2.4 tag, like old iTunes)
    big = b'\x00' + latin1('x' * 200)
    frames += latin1('TCOP') + struct.pack('>I', len(big)) + b'\x00\x00' + big

    crc = zlib.crc32(frames) & 0xFFFFFFFF
    crc_bytes = syncsafe(crc, 5)
    # flags: CRC (0x20) + restrictions (0x10)
    ext_body = b'\x01' + bytes([0x20 | 0x10]) + b'\x05' + crc_bytes + b'\x01' + bytes([0b01100101])
    ext = syncsafe(4 + len(ext_body)) + ext_body
    body = ext + frames
    flags = 0x40 | 0x10  # extended header + footer
    header = b'ID3\x04\x00' + bytes([flags]) + syncsafe(len(body))
    footer = b'3DI\x04\x00' + bytes([flags]) + syncsafe(len(body))
    return header + body + footer


# --------------------------------------------------------------------------- v2.2

def frame22(fid, data):
    return latin1(fid) + struct.pack('>I', len(data))[1:] + data


def tag_v22():
    frames = b''
    frames += frame22('TT2', b'\x00' + latin1('Titel v2.2'))
    frames += frame22('TP1', b'\x01' + utf16('Interpret') + b'\x00\x00')
    frames += frame22('TCO', b'\x00' + latin1('(13)'))
    frames += frame22('TYE', b'\x00' + latin1('1999'))
    frames += frame22('COM', b'\x00' + latin1('eng') + b'\x00' + latin1('Kommentar 2.2'))
    frames += frame22('PIC', b'\x00' + latin1('JPG') + b'\x03' + latin1('Bild') + b'\x00' + JPEG_HEAD)
    frames += frame22('TCP', b'\x00' + latin1('1'))
    body = frames + b'\x00' * 32
    return b'ID3\x02\x00\x00' + syncsafe(len(body)) + body


# --------------------------------------------------------------------------- v1 / APE

def pad(s, n):
    b = latin1(s)[:n]
    return b + b'\x00' * (n - len(b))


def id3v1(title, artist, album, year, comment, genre, track=None):
    if track is None:
        c = pad(comment, 30)
    else:
        c = pad(comment, 28) + b'\x00' + bytes([track])
    return b'TAG' + pad(title, 30) + pad(artist, 30) + pad(album, 30) + pad(year, 4) + c + bytes([genre])


def ape_v2(items):
    body = b''
    for key, value in items:
        v = value.encode('utf-8')
        body += struct.pack('<II', len(v), 0) + latin1(key) + b'\x00' + v
    size = len(body) + 32
    header = b'APETAGEX' + struct.pack('<IIII', 2000, size, len(items), 0x80000000 | 0x20000000) + b'\x00' * 8
    footer = b'APETAGEX' + struct.pack('<IIII', 2000, size, len(items), 0x80000000) + b'\x00' * 8
    return header + body + footer


def main():
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    cbr = (src / 'cbr.mp3').read_bytes()
    vbr = (src / 'vbr.mp3').read_bytes()
    mono = (src / 'mono22.mp3').read_bytes()
    l2 = (src / 'l2crc.mp2').read_bytes()

    (out / 'v23_cbr_v11.mp3').write_bytes(
        tag_v23() + cbr + id3v1('Titel v1', 'Artist v1', 'Album v1', '2026', 'Kommentar', 17, track=5))
    (out / 'v24_vbr_ape_v10.mp3').write_bytes(
        tag_v24() + vbr + ape_v2([('Title', 'APE Titel'), ('Artist', 'APE Artist')])
        + id3v1('Nur v1.0', 'Artist', 'Album', '1980', 'Kommentar mit dreissig Zeichen!', 255))
    (out / 'v22_mpeg2_mono.mp3').write_bytes(tag_v22() + mono)
    # Layer II with CRC and 100 junk bytes in the middle of the stream
    cut = 10 * 576  # 10 frames of 576 bytes (192 kbps, 48 kHz)
    (out / 'layer2_crc_junk.mp2').write_bytes(l2[:cut] + bytes(range(100)) + l2[cut:])


if __name__ == '__main__':
    main()
