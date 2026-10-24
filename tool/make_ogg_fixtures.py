#!/usr/bin/env python3
"""Builds the Ogg test fixtures in test/fixtures.

Usage: make_ogg_fixtures.py <output dir>

Needs ffmpeg (libvorbis, libopus, flac, libspeex, libtheora) and mutagen
(adds a METADATA_BLOCK_PICTURE comment to the Vorbis file).
"""
import base64
import struct
import subprocess
import sys
from pathlib import Path

from mutagen.flac import Picture
from mutagen.oggvorbis import OggVorbis

import zlib  # noqa: E402


def png(width, height):
    def part(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b''.join(b'\x00' + b'\xff\x00\x00\xff' * width for _ in range(height))
    return (b'\x89PNG\r\n\x1a\n' + part(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + part(b'IDAT', zlib.compress(raw)) + part(b'IEND', b''))


PNG_2x3 = png(2, 3)

FF = ['ffmpeg', '-v', 'error', '-y', '-bitexact']


def run(args):
    subprocess.run(FF + args, check=True)


def sine(freq, duration, rate=44100):
    return ['-f', 'lavfi', '-i', f'sine=frequency={freq}:duration={duration}:sample_rate={rate}']


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)

    vorbis = out / 'ogg_vorbis.ogg'
    run(sine(440, 3) + ['-ac', '2', '-c:a', 'libvorbis', '-q:a', '3',
                        '-metadata', 'title=Testtitel Vorbis', '-metadata', 'artist=Künstler',
                        '-metadata', 'album=Album', '-metadata', 'tracknumber=7', '-metadata', 'genre=Rock',
                        '-serial_offset', '1000', str(vorbis)])
    tags = OggVorbis(str(vorbis))
    pic = Picture()
    pic.type = 3
    pic.mime = 'image/png'
    pic.desc = 'Cover'
    pic.width, pic.height, pic.depth = 2, 3, 32
    pic.data = PNG_2x3
    tags['METADATA_BLOCK_PICTURE'] = [base64.b64encode(pic.write()).decode('ascii')]
    tags.save()

    run(sine(660, 1, 48000) + ['-ac', '2', '-c:a', 'libopus', '-b:a', '64k',
                               '-metadata', 'title=Opus Test', '-serial_offset', '2000', str(out / 'ogg_opus.opus')])
    run(sine(330, 0.5) + ['-ac', '1', '-c:a', 'flac', '-metadata', 'title=FLAC in Ogg',
                          '-serial_offset', '3000', '-f', 'ogg', str(out / 'ogg_flac.oga')])
    run(sine(550, 1, 16000) + ['-ac', '1', '-c:a', 'libspeex', '-serial_offset', '4000',
                               str(out / 'ogg_speex.spx')])
    run(['-f', 'lavfi', '-i', 'testsrc=size=64x48:rate=10:duration=1'] + sine(440, 1)
        + ['-c:v', 'libtheora', '-q:v', '5', '-c:a', 'libvorbis', '-ac', '1', '-serial_offset', '5000',
           str(out / 'ogg_theora_vorbis.ogv')])

    # chained stream: two Vorbis files one after another
    second = out / '_second.ogg'
    run(sine(880, 0.5) + ['-ac', '1', '-c:a', 'libvorbis', '-q:a', '1', '-serial_offset', '6000', str(second)])
    first = vorbis.read_bytes()
    (out / 'ogg_chained.ogg').write_bytes(first + second.read_bytes())
    second.unlink()

    # damaged copy: junk in front of page 3, flipped byte in the body of page 4
    d = bytearray(first)
    starts = [i for i in range(len(d) - 4) if d[i:i + 4] == b'OggS']
    d[starts[4] + 27 + d[starts[4] + 26] + 10] ^= 0xFF
    d[starts[3]:starts[3]] = b'JUNKJUNK'
    (out / 'ogg_vorbis_damaged.ogg').write_bytes(bytes(d))


if __name__ == '__main__':
    main()
