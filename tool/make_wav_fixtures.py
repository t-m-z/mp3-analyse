#!/usr/bin/env python3
"""Builds the WAV test fixtures in test/fixtures.

Usage: make_wav_fixtures.py <output dir>

Needs ffmpeg (libmp3lame) for the RF64 and the MP3-in-WAV fixture; all other
files are written by hand so that every chunk type and special case is covered.
"""
import math
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_fixtures import tag_v23, id3v1  # noqa: E402


def chunk(cid, data, be=False):
    out = cid.encode('latin-1') + struct.pack('>I' if be else '<I', len(data)) + data
    if len(data) % 2:
        out += b'\x00'
    return out


def riff(chunks, be=False):
    body = b'WAVE' + b''.join(chunks)
    return (b'RIFX' if be else b'RIFF') + struct.pack('>I' if be else '<I', len(body)) + body


def sine_frames(n, rate, channels, freq=1000.0, amp=0.5):
    for i in range(n):
        v = amp * math.sin(2 * math.pi * freq * i / rate)
        yield [v if c == 0 else v * 0.25 for c in range(channels)]


def pcm16(n, rate, channels, be=False):
    fmt = ('>' if be else '<') + 'h' * channels
    return b''.join(struct.pack(fmt, *[int(round(v * 32767)) for v in f]) for f in sine_frames(n, rate, channels))


def float32(n, rate, channels):
    out = b''
    for f in sine_frames(n, rate, channels):
        out += struct.pack('<' + 'f' * channels, *f)
    # one clipped sample at the end
    return out[:-4 * channels] + struct.pack('<' + 'f' * channels, *([1.25] + [0.0] * (channels - 1)))


def fmt_pcm(channels, rate, bits, tag=1, be=False):
    align = channels * bits // 8
    return struct.pack('>HHIIHH' if be else '<HHIIHH', tag, channels, rate, rate * align, align, bits)


def info_list(items):
    return chunk('LIST', b'INFO' + b''.join(chunk(k, v.encode('utf-8') + b'\x00') for k, v in items))


def bext():
    b = bytearray(602)
    def put(off, length, text):
        raw = text.encode('latin-1')[:length]
        b[off:off + len(raw)] = raw
    put(0, 256, 'BWF Beschreibung')
    put(256, 32, 'Originator')
    put(288, 32, 'REF-0001')
    put(320, 10, '2026-10-24')
    put(330, 8, '18:17:00')
    struct.pack_into('<II', b, 338, 44100 * 3600, 0)  # time reference: 01:00:00
    struct.pack_into('<H', b, 346, 2)
    struct.pack_into('<hhhhh', b, 412, -2300, 450, -100, 0x7FFF, -1800)
    return bytes(b) + b'A=PCM,F=44100,W=16,M=stereo,T=make_wav_fixtures\r\n'


def cue(points):
    data = struct.pack('<I', len(points))
    for cid, sample in points:
        data += struct.pack('<II', cid, sample) + b'data' + struct.pack('<III', 0, 0, sample)
    return chunk('cue ', data)


def adtl():
    sub = chunk('labl', struct.pack('<I', 1) + b'Anfang\x00')
    sub += chunk('labl', struct.pack('<I', 2) + b'Mitte\x00')
    sub += chunk('ltxt', struct.pack('<II', 2, 1000) + b'rgn ' + struct.pack('<HHHH', 49, 7, 0, 1252) + b'Region\x00')
    return chunk('LIST', b'adtl' + sub)


def smpl():
    data = struct.pack('<IIIIIIIII', 0x01000041, 0, 22676, 60, 0x80000000, 25, 0x01020304, 1, 0)
    data += struct.pack('<IIIIII', 7, 0, 100, 5000, 0, 0)
    return chunk('smpl', data)


def wav_pcm16_chunks():
    rate, ch, n = 44100, 2, 11025
    chunks = [
        chunk('JUNK', b'\x00' * 28),
        chunk('fmt ', fmt_pcm(ch, rate, 16)),
        info_list([('INAM', 'Testton'), ('IART', 'Künstler'), ('ICMT', 'ungerade')]),
        chunk('bext', bext()),
        cue([(1, 0), (2, 5512)]),
        adtl(),
        smpl(),
        chunk('inst', bytes([60, 0xFB, 0xFD, 0, 127, 1, 127])),
        chunk('acid', struct.pack('<IHHfIHHf', 0x02, 60, 0x8000, 0.0, 4, 4, 4, 120.0)),
        chunk('data', pcm16(n, rate, ch)),
        chunk('id3 ', tag_v23()),
    ]
    return riff(chunks) + id3v1('WAV v1', 'Artist', 'Album', '2026', 'hinter RIFF', 12, track=9)


def wav_float32_peak():
    rate, ch, n = 48000, 2, 4800
    fmt = struct.pack('<HHIIHHH', 3, ch, rate, rate * 8, 8, 32, 0)
    peak = struct.pack('<II', 1, 0) + struct.pack('<fIfI', 1.25, n - 1, 0.125, 1200)
    return riff([chunk('fmt ', fmt), chunk('fact', struct.pack('<I', n)), chunk('PEAK', peak),
                 chunk('data', float32(n, rate, ch))])


def wav_rifx_mono():
    rate, n = 8000, 800
    return riff([chunk('fmt ', fmt_pcm(1, rate, 16, be=True), be=True),
                 chunk('data', pcm16(n, rate, 1, be=True), be=True)], be=True)


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    (out / 'wav_pcm16_chunks.wav').write_bytes(wav_pcm16_chunks())
    (out / 'wav_float32_peak.wav').write_bytes(wav_float32_peak())
    (out / 'wav_rifx_mono.wav').write_bytes(wav_rifx_mono())
    ff = ['ffmpeg', '-v', 'error', '-y', '-bitexact', '-f', 'lavfi']
    subprocess.run(ff + ['-i', 'sine=frequency=440:duration=0.1:sample_rate=48000', '-af',
                         'pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0', '-c:a', 'pcm_s24le',
                         '-rf64', 'always', str(out / 'wav_rf64_24bit_5_1.wav')], check=True)
    subprocess.run(ff + ['-i', 'sine=frequency=440:duration=1:sample_rate=44100', '-ac', '2',
                         '-c:a', 'libmp3lame', '-b:a', '128k', '-f', 'wav', str(out / 'wav_mp3.wav')], check=True)


if __name__ == '__main__':
    main()
