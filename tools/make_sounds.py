"""Block World's sounds, synthesized (no samples): crunches, knocks, clinks,
a pop, a splash, a click. Pure Python (no numpy). Writes 16-bit mono WAVs.

usage: python3 make_sounds.py <out dir>
"""
import math
import random
import struct
import sys
import wave
from pathlib import Path

SR = 22050
OUT = Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)


def write(name, xs, gain=1.0):
    peak = max(1e-9, max(abs(x) for x in xs))
    k = gain * 0.89 / peak
    # A few ms of fade in and out: no clicks at the ends.
    n = len(xs)
    f = int(0.003 * SR)
    data = bytearray()
    for i, x in enumerate(xs):
        e = min(1.0, i / f if f else 1, (n - 1 - i) / f if f else 1)
        data += struct.pack("<h", int(max(-1, min(1, x * k * e)) * 32767))
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(bytes(data))


def lowpass(xs, fc):
    a = math.exp(-2 * math.pi * fc / SR)
    y, out = 0.0, []
    for x in xs:
        y = (1 - a) * x + a * y
        out.append(y)
    return out


def highpass(xs, fc):
    lp = lowpass(xs, fc)
    return [x - l for x, l in zip(xs, lp)]


def bandpass(xs, lo, hi):
    return lowpass(highpass(xs, lo), hi)


def resonator(xs, freq, q):
    # Two-pole resonant filter: a body that rings at `freq`.
    r = math.exp(-math.pi * freq / (q * SR))
    c = 2 * r * math.cos(2 * math.pi * freq / SR)
    y1 = y2 = 0.0
    out = []
    for x in xs:
        y = x + c * y1 - r * r * y2
        y2, y1 = y1, y
        out.append(y)
    return out


def silence(t):
    return [0.0] * int(t * SR)


def mix_at(base, xs, at, g=1.0):
    i0 = int(at * SR)
    need = i0 + len(xs) - len(base)
    if need > 0:
        base.extend([0.0] * need)
    for i, x in enumerate(xs):
        base[i0 + i] += x * g
    return base


def env(n, attack, decay):
    a = max(1, int(attack * SR))
    out = []
    for i in range(n):
        t = i / SR
        out.append(min(1.0, i / a) * math.exp(-t / decay))
    return out


def noise(n, rnd):
    return [rnd.uniform(-1, 1) for _ in range(n)]


def grains(rnd, length, count, grain, lo, hi, decay):
    """A crunch: short noise grains scattered over `length`, each its own
    band, louder first."""
    out = silence(length)
    for g in range(count):
        at = rnd.uniform(0, length * 0.75) * (g / count) ** 0.6
        n = int(grain * rnd.uniform(0.6, 1.4) * SR)
        f0 = rnd.uniform(lo, hi)
        x = bandpass(noise(n, rnd), f0 * 0.5, f0 * 1.6)
        e = env(n, 0.001, decay * rnd.uniform(0.6, 1.2))
        mix_at(out, [a * b for a, b in zip(x, e)], at, rnd.uniform(0.5, 1.0) * (1 - 0.5 * g / count))
    return out


def soft(seed, length=0.2, lo=500, hi=1800, count=16):
    rnd = random.Random(seed)
    return grains(rnd, length, count, 0.03, lo, hi, 0.012)


def hard(seed, length=0.16, body=None):
    rnd = random.Random(seed)
    out = grains(rnd, length, 9, 0.02, 1800, 4200, 0.006)
    # A ringing body under the clicks: stone's hollow tock.
    f = body or rnd.uniform(420, 620)
    hit = noise(int(0.004 * SR), rnd) + silence(0.12)
    ring = resonator(hit, f, 18)
    ring = [x * e for x, e in zip(ring, env(len(ring), 0.0005, 0.035))]
    mix_at(out, ring, 0, 0.06)
    return out


def knock(seed, f=None):
    rnd = random.Random(seed)
    f = f or rnd.uniform(170, 240)
    n = int(0.18 * SR)
    hit = noise(int(0.006 * SR), rnd) + [0.0] * (n - int(0.006 * SR))
    body = resonator(lowpass(hit, 1600), f, 9)
    body2 = resonator(lowpass(hit, 2600), f * 2.7, 14)
    e = env(n, 0.0005, 0.045)
    out = [(a + 0.5 * b) * c for a, b, c in zip(body, body2, e)]
    click = bandpass(noise(int(0.012 * SR), rnd), 1500, 5000)
    click = [x * c for x, c in zip(click, env(len(click), 0.0003, 0.003))]
    return mix_at(out, click, 0, 0.3 * max(abs(x) for x in out))


def clinks(seed):
    rnd = random.Random(seed)
    out = silence(0.55)
    # Shatter: a noisy crack, then glassy partials falling apart.
    crack = highpass(noise(int(0.05 * SR), rnd), 2500)
    crack = [x * e for x, e in zip(crack, env(len(crack), 0.0005, 0.012))]
    mix_at(out, crack, 0, 0.8)
    for _ in range(14):
        f = rnd.uniform(2400, 6200)
        at = rnd.uniform(0, 0.25)
        n = int(rnd.uniform(0.05, 0.22) * SR)
        e = env(n, 0.0005, rnd.uniform(0.02, 0.06))
        ph = rnd.uniform(0, 6.28)
        tone = [math.sin(2 * math.pi * f * i / SR + ph) * e[i] for i in range(n)]
        mix_at(out, tone, at, rnd.uniform(0.15, 0.4))
    return out


def pop():
    n = int(0.09 * SR)
    out, ph = [], 0.0
    for i in range(n):
        t = i / SR
        f = 520 + 900 * (t / 0.09) ** 0.5
        ph += 2 * math.pi * f / SR
        out.append(math.sin(ph) * math.exp(-t / 0.03) * min(1, i / (0.002 * SR)))
    return out


def click():
    rnd = random.Random(7)
    n = int(0.05 * SR)
    x = bandpass(noise(n, rnd), 900, 3500)
    tone = [math.sin(2 * math.pi * 1250 * i / SR) for i in range(n)]
    e = env(n, 0.0005, 0.008)
    return [(0.6 * a + 0.4 * b) * c for a, b, c in zip(x, tone, e)]


def splash(seed, length=0.7, bright=2600):
    rnd = random.Random(seed)
    n = int(length * SR)
    x = noise(n, rnd)
    # Its brightness falls away as the water settles; bubbles under it.
    out, y = [], 0.0
    for i, s in enumerate(x):
        t = i / SR
        fc = bright * math.exp(-t / (length * 0.35)) + 300
        a = math.exp(-2 * math.pi * fc / SR)
        y = (1 - a) * s + a * y
        out.append(y * min(1, t / 0.01) * math.exp(-t / (length * 0.3)))
    for _ in range(int(length * 30)):
        at = rnd.uniform(0.02, length * 0.7)
        bn = int(0.03 * SR)
        f0 = rnd.uniform(500, 1400)
        ph = 0.0
        b = []
        for i in range(bn):
            ph += 2 * math.pi * f0 * (1 + 1.5 * i / bn) / SR
            b.append(math.sin(ph) * math.exp(-i / (0.008 * SR)))
        mix_at(out, b, at, rnd.uniform(0.02, 0.07))
    return out


def thud():
    rnd = random.Random(3)
    n = int(0.16 * SR)
    hit = noise(int(0.01 * SR), rnd) + [0.0] * (n - int(0.01 * SR))
    body = resonator(lowpass(hit, 400), 85, 4)
    return [b * e for b, e in zip(body, env(n, 0.001, 0.05))]


# Each material: three of a kind, so repeats don't sound the same.
for i in range(3):
    write(f"grass{i + 1}", soft(10 + i, 0.2, 450, 1600, 18))
    write(f"dirt{i + 1}", soft(20 + i, 0.18, 300, 1100, 14))
    write(f"sand{i + 1}", soft(30 + i, 0.22, 1500, 4200, 22))
    write(f"gravel{i + 1}", soft(40 + i, 0.2, 700, 2600, 12))
    write(f"snow{i + 1}", soft(50 + i, 0.24, 900, 2200, 20))
    write(f"leaves{i + 1}", soft(60 + i, 0.18, 1800, 5200, 26))
    write(f"stone{i + 1}", hard(70 + i))
    write(f"wood{i + 1}", knock(80 + i))
write("glass", clinks(90))
write("pop", pop())
write("click", click())
write("splash", splash(5))
write("swim1", splash(6, 0.35, 1500))
write("swim2", splash(7, 0.35, 1700))
write("land", thud())
print("ok", len(list(OUT.glob("*.wav"))), "files")


# Animals: a voice is a buzz (a few harmonics at a pitch that moves) shaped
# by two formants, as a mouth would.
def voice(f0s, length, formants, vib=0.0, vib_rate=0.0, breath=0.05, seed=1):
    rnd = random.Random(seed)
    n = int(length * SR)
    out, ph = [], 0.0
    for i in range(n):
        t = i / SR
        u = t / length
        # f0 along its points, linearly
        k = min(len(f0s) - 2, int(u * (len(f0s) - 1)))
        fu = u * (len(f0s) - 1) - k
        f = f0s[k] * (1 - fu) + f0s[k + 1] * fu
        f *= 1 + vib * math.sin(2 * math.pi * vib_rate * t)
        ph += 2 * math.pi * f / SR
        x = 0.0
        for h in range(1, 14):
            x += math.sin(ph * h) / h
        out.append(x + rnd.uniform(-1, 1) * breath)
    y = [0.0] * n
    for fc, q, g in formants:
        r = resonator(out, fc, q)
        for i in range(n):
            y[i] += r[i] * g
    e = env(n, 0.015, length * 0.5)
    for i in range(n):
        y[i] *= e[i] * min(1.0, (n - i) / (0.03 * SR))
    return y


def cluck(seed):
    rnd = random.Random(seed)
    out = silence(0.36)
    at = 0.0
    for k in range(rnd.choice([2, 3])):
        f = rnd.uniform(560, 700) * (1.12 if k == 0 else 1.0)
        b = voice([f * 1.3, f, f * 0.9], rnd.uniform(0.06, 0.09), [(1500, 6, 1), (2600, 8, 0.5)], breath=0.2, seed=seed + k)
        mix_at(out, b, at)
        at += rnd.uniform(0.09, 0.12)
    return out


def oink(seed, hurt=False):
    rnd = random.Random(seed)
    f = rnd.uniform(110, 135) * (1.35 if hurt else 1)
    length = 0.2 if hurt else 0.32
    return voice([f * 1.25, f * 1.1, f * 0.8], length, [(520, 5, 1), (900, 6, 0.7), (2200, 8, 0.2)], breath=0.35, seed=seed)


def baa(seed, hurt=False):
    rnd = random.Random(seed)
    f = rnd.uniform(240, 280) * (1.25 if hurt else 1)
    length = 0.28 if hurt else 0.65
    return voice([f * 0.92, f, f * 0.95, f * 0.85], length, [(700, 5, 1), (1250, 7, 0.6), (2600, 9, 0.2)], vib=0.06, vib_rate=11, breath=0.12, seed=seed)


def tool_break():
    rnd = random.Random(99)
    out = knock(98, 380)
    snap = highpass(noise(int(0.06 * SR), rnd), 1800)
    snap = [x * e for x, e in zip(snap, env(len(snap), 0.0005, 0.015))]
    return mix_at(out, snap, 0, 0.6 * max(abs(x) for x in out))


write("chicken1", cluck(301))
write("chicken2", cluck(302))
write("chicken_hurt", voice([900, 1150, 700], 0.14, [(1600, 6, 1), (2800, 8, 0.5)], breath=0.3, seed=303))
write("pig1", oink(311))
write("pig2", oink(312))
write("pig_hurt", oink(313, True))
write("sheep1", baa(321))
write("sheep2", baa(322))
write("sheep_hurt", baa(323, True))
write("tool_break", tool_break())
print("ok animals")
