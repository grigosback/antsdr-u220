#!/usr/bin/env python3
"""Spectrum of a cs16 file (interleaved int16 I/Q, as written by u220_rx --out).

    iq_spectrum.py FILE --rate HZ [--freq HZ] [--fft N] [--png OUT.png]

Prints the strongest tone (frequency offset, level in dBFS), the strongest
other spur and its distance below the tone (SFDR), the mirror image level
(I/Q balance), and the median noise floor per FFT bin. --freq only shifts the
plot axis to RF frequency.
"""
import argparse
import sys

import numpy as np


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--rate", type=float, required=True, help="sample rate, Hz")
    ap.add_argument("--freq", type=float, default=0.0, help="center frequency for the plot axis, Hz")
    ap.add_argument("--fft", type=int, default=8192, help="FFT size")
    ap.add_argument("--max-ffts", type=int, default=200, help="FFTs to average")
    ap.add_argument("--png", help="save a plot here")
    a = ap.parse_args()

    raw = np.fromfile(a.file, dtype="<i2")
    if raw.size < 2 * a.fft:
        sys.exit("file too short for one FFT")
    x = (raw[0::2].astype(np.float32) + 1j * raw[1::2].astype(np.float32)) / 32768.0
    n = a.fft
    k = min(x.size // n, a.max_ffts)
    win = np.blackman(n).astype(np.float32)
    seg = x[: k * n].reshape(k, n) * win
    p = np.mean(np.abs(np.fft.fftshift(np.fft.fft(seg, axis=1), axes=1)) ** 2, axis=0)
    p /= n * np.sum(win ** 2)                  # bins sum to power: full-scale tone = 0 dBFS
    db = 10 * np.log10(p + 1e-30)
    f = (np.arange(n) - n // 2) * a.rate / n

    def band_power(i, half=4):
        lo, hi = max(i - half, 0), min(i + half + 1, n)
        return 10 * np.log10(np.sum(p[lo:hi]) + 1e-30), lo, hi

    i_peak = int(np.argmax(db))
    tone_db, lo, hi = band_power(i_peak)
    # mirror image of the tone: -f
    i_img = (n - i_peak) % n
    img_db, _, _ = band_power(i_img)
    # strongest spur outside the tone, its image and DC
    mask = np.ones(n, bool)
    for c in (i_peak, i_img, n // 2):
        mask[max(c - 6, 0):min(c + 7, n)] = False
    i_spur = int(np.argmax(np.where(mask, db, -400)))
    spur_db, _, _ = band_power(i_spur)
    floor = float(np.median(db))

    print(f"{a.file}: {x.size} samples, {k} x {n}-point FFTs, bin {a.rate / n / 1e3:.2f} kHz")
    print(f"tone   {f[i_peak] / 1e6:+10.6f} MHz  {tone_db:7.1f} dBFS")
    print(f"image  {f[i_img] / 1e6:+10.6f} MHz  {img_db:7.1f} dBFS  ({tone_db - img_db:.1f} dB below)")
    print(f"spur   {f[i_spur] / 1e6:+10.6f} MHz  {spur_db:7.1f} dBFS  (SFDR {tone_db - spur_db:.1f} dB)")
    print(f"DC     {db[n // 2]:7.1f} dBFS/bin, noise floor (median) {floor:.1f} dBFS/bin")

    if a.png:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(11, 4.5))
        ax.plot((f + a.freq) / 1e6, db, lw=0.6)
        ax.set_xlabel("MHz" if a.freq else "offset, MHz")
        ax.set_ylabel("dBFS / bin")
        ax.set_title(f"{a.file}  ({a.rate / 1e6:g} MS/s)")
        ax.grid(alpha=0.3)
        fig.tight_layout()
        fig.savefig(a.png, dpi=120)
        print(f"wrote {a.png}")


if __name__ == "__main__":
    main()
