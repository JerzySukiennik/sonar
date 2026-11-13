# Sonar: reads a .sonarlog pulled from the phone and reports what the echoes and poses actually look like.
# Usage: python3 analyze.py scan.sonarlog [chirpSamples f1 f2]   (defaults match the current app: 2048 2000 15000)
import struct, sys
import numpy as np

C = 343.0
CHIRP, F1, F2 = (int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])) if len(sys.argv) > 4 else (2048, 2000.0, 15000.0)


def load(path):
    raw = open(path, "rb").read()
    assert raw[:8] == b"SONARLOG", "not a sonar log"
    fs, n, _ = struct.unpack_from("<dii", raw, 8)
    pos, frames = 24, []
    while pos + 24 <= len(raw):
        t, lag, has, count = struct.unpack_from("<ddii", raw, pos)
        pos += 24
        if pos + 64 + count * 2 > len(raw):
            break
        m = np.frombuffer(raw, "<f4", 16, pos).reshape(4, 4).T
        pos += 64
        pcm = np.frombuffer(raw, "<i2", count, pos).astype(np.float64) / 32767
        pos += count * 2
        frames.append((t, lag, has == 1, m, pcm))
    return fs, n, frames


def compressor(fs, n):
    top = min(F2, fs / 2 - 1500)
    i = np.arange(CHIRP)
    t = i / fs
    edge = np.minimum(i, CHIRP - 1 - i) / (0.08 * CHIRP)
    a = np.where(edge >= 1, 1, 0.5 - 0.5 * np.cos(np.pi * edge))
    wave = np.zeros(n)
    wave[:CHIRP] = a * np.sin(2 * np.pi * (F1 * t + 0.5 * (top - F1) / (CHIRP / fs) * t * t))
    X = np.fft.fft(wave)
    k_lo, k_hi = round(F1 * n / fs), round(top * n / fs)
    g = np.zeros(n, complex)
    k = np.arange(k_lo, k_hi + 1)
    p = np.abs(X[k]) ** 2
    g[k] = np.conj(X[k]) / (p + p.max() * 1e-3) * (1 - np.cos(2 * np.pi * (k - k_lo) / (k_hi - k_lo)))
    return g


def main():
    fs, n, frames = load(sys.argv[1])
    g = compressor(fs, n)
    bin_m = C / (2 * fs)
    print(f"fs {fs:.0f}  period {n}  frames {len(frames)}  span {frames[-1][0] - frames[0][0]:.1f} s  with pose {sum(f[2] for f in frames)}")
    peaks = np.array([np.abs(f[4]).max() for f in frames])
    print(f"mic peak min/median/max {peaks.min():.3f} {np.median(peaks):.3f} {peaks.max():.3f}   rms median {np.median([f[4].std() for f in frames]):.4f}")
    lags = np.array([f[1] for f in frames])
    print(f"stored direct lag first/last {lags[0]:.2f} {lags[-1]:.2f}  min/max {lags.min():.2f} {lags.max():.2f}")
    H = np.array([np.fft.fft(f[4]) * g for f in frames])
    coarse = np.fft.ifft(H, axis=1)
    env = np.abs(coarse)
    own = np.array([next((q % n for q in range(m - 96, m + 1) if e[q % n] >= 0.4 * e[m] and e[q % n] >= e[(q - 1) % n] and e[q % n] >= e[(q + 1) % n]), m) for e, m in zip(env, env.argmax(axis=1))])
    print("first-arrival lag per frame:", " ".join(str(v) for v in own[:: max(1, len(own) // 24)]))
    k = np.arange(n)
    tau = np.median(own[len(own) // 2:])
    h = np.fft.ifft(H * np.exp(2j * np.pi * k * tau / n), axis=1)
    ref = np.median(np.abs(h[:, :48]).max(axis=1))
    print("own sound, first 48 samples (dB):", " ".join(f"{v:.0f}" for v in 20 * np.log10(np.abs(h).mean(axis=0)[:48] / ref + 1e-9)))
    tail = np.sqrt(np.mean(np.abs(h[:, n // 4: n // 2]) ** 2))
    print(f"direct amplitude {ref:.4f}  floor (far lags) {20 * np.log10(tail / ref):.1f} dB re direct")
    mean = np.abs(h).mean(axis=0)
    bg = h[0].copy()
    motion = []
    for row in h:
        motion.append(np.abs(row - bg))
        bg += 0.04 * (row - bg)
    motion = np.array(motion[len(motion) // 3:]).mean(axis=0)
    print("range        mean echo dB   moving part dB   (re direct)")
    for a, b in [(0, 0.05), (0.05, 0.1), (0.1, 0.2), (0.2, 0.3), (0.3, 0.5), (0.5, 0.75), (0.75, 1), (1, 1.5), (1.5, 2), (2, 3), (3, 4), (4, 5)]:
        i0, i1 = int(a / bin_m), int(b / bin_m)
        j = i0 + mean[i0:i1].argmax()
        print(f"{a:4.2f}-{b:4.2f} m   {20 * np.log10(mean[i0:i1].max() / ref):7.1f} at {j * bin_m:5.3f} m   {20 * np.log10(motion[i0:i1].max() / ref):7.1f}")
    print("pre-direct (negative lags, should be empty):", f"{20 * np.log10(np.abs(h[:, -400:-20]).mean(axis=0).max() / ref):.1f} dB")
    poses = np.array([f[3][:3, 3] for f in frames if f[2]])
    if len(poses):
        print("camera position range x/y/z (m):", " ".join(f"{poses[:, i].min():+.2f}..{poses[:, i].max():+.2f}" for i in range(3)))
        step = np.linalg.norm(np.diff(poses, axis=0), axis=1)
        print(f"path length {step.sum():.2f} m  median step {np.median(step) * 100:.1f} cm")
    spec = np.abs(np.fft.rfft(np.array([f[4] for f in frames]), axis=1)).mean(axis=0)
    f = np.fft.rfftfreq(n, 1 / fs)
    print("recorded spectrum by band (dB):", "  ".join(f"{lo // 1000}-{hi // 1000}k {20 * np.log10(spec[(f >= lo) & (f < hi)].mean() + 1e-12):.0f}" for lo, hi in [(0, 1000), (1000, 3000), (3000, 6000), (6000, 10000), (10000, 14000), (14000, 18000), (18000, 24000)]))


main()
