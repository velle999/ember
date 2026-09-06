#!/usr/bin/env python3
"""Build a 128-byte EDID for a panel that publishes none.

A small HDMI panel very often has no EDID at all. KMS then invents a CVT
timing for whatever mode you name on the cmdline, the panel does not
recognise it, and it shows "not support" or blinks — with no way to tell
from the Pi side that the timing, rather than the resolution, is wrong.
Handing the kernel a real EDID makes the panel's own mode the preferred
(and only) one, which is both correct and self-checking: the connector's
`modes` file then lists exactly one line.

⛔ Give the panel's NATIVE mode. A panel sold as "800x480" may well be a
480x800 portrait panel that the vendor's config rotated; naming the rotated
size here produces a mode the panel has never had. Rotate above this, not
in the EDID.
"""
import argparse, sys


def cvt(w, h, hz):
    """CVT v1.1 normal-blanking timing — the same one `cvt` and the Pi's
    `hdmi_cvt` produce, so a vendor config's numbers can be reproduced."""
    CELL, MIN_PORCH = 8, 3
    MIN_VSYNC_BP, C, M, K, J = 550.0, 40.0, 600.0, 128.0, 20.0
    # ⛔ V_SYNC_RQD COMES FROM THE ASPECT RATIO, and everything else can be
    # right while this one number is wrong. A non-standard ratio — which is
    # exactly what a rotated portrait panel has — takes 10, not the 4 that a
    # 4:3 panel takes, and a generator that hardcodes 4 emits an EDID the
    # panel rejects with a timing that otherwise matches `cvt` line for line.
    VSYNC_RQD = 10
    # ⚠ 15:9 is deliberately absent: cvt(1) does not special-case it and falls
    # through to 10, and cvt(1) is the reference the Pi's own hdmi_cvt matches.
    for num, den, vs in ((4, 3, 4), (16, 9, 5), (16, 10, 6), (5, 4, 7)):
        if abs(w * den - h * num) <= 1:
            VSYNC_RQD = vs
            break
    c2 = (C - J) * K / 256.0 + J
    m2 = K / 256.0 * M
    h_pixels = int(round(w / CELL) * CELL)
    v_lines_rnd = int(h)
    h_period_est = ((1.0 / hz) - MIN_VSYNC_BP / 1e6) / (v_lines_rnd + MIN_PORCH) * 1e6
    v_sync_bp = int(MIN_VSYNC_BP / h_period_est) + 1
    if v_sync_bp < VSYNC_RQD + MIN_PORCH:
        v_sync_bp = VSYNC_RQD + MIN_PORCH
    total_v_lines = v_lines_rnd + v_sync_bp + MIN_PORCH
    ideal_duty = c2 - (m2 * h_period_est / 1000.0)
    if ideal_duty < 20.0:
        ideal_duty = 20.0
    h_blank = int(h_pixels * ideal_duty / (100.0 - ideal_duty) / (2 * CELL)) * (2 * CELL)
    h_total = h_pixels + h_blank
    pclk = int(h_total / h_period_est * 1e6 / 250000) * 0.25 * 1e6   # 0.25 MHz steps
    h_sync = int(0.08 * h_total / CELL) * CELL   # CVT floors this, never rounds
    return dict(
        pclk_khz=int(round(pclk / 1000.0)),
        ha=h_pixels, hfp=h_blank // 2 - h_sync, hsw=h_sync, hb=h_blank,
        va=v_lines_rnd, vfp=MIN_PORCH, vsw=VSYNC_RQD,
        vb=total_v_lines - v_lines_rnd,
    )


def build(t, wmm, hmm, name):
    e = bytearray(128)
    e[0:8] = bytes([0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0])
    v = 0
    for c in "EMB":
        v = (v << 5) | (ord(c) - 64)
    e[8:10] = bytes([(v >> 8) & 0xFF, v & 0xFF])
    e[10:12] = (0x4009).to_bytes(2, "little")
    e[12:16] = (1).to_bytes(4, "little")
    e[16], e[17] = 1, 36                       # week 1, year 2026
    e[18], e[19] = 1, 3                        # EDID 1.3
    e[20] = 0x80                               # digital input
    e[21], e[22] = max(1, round(wmm / 10)), max(1, round(hmm / 10))
    e[23] = 120                                # gamma 2.2
    e[24] = 0x0A                               # RGB, preferred timing mode
    e[25:35] = bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])
    for i in range(38, 54, 2):
        e[i], e[i + 1] = 0x01, 0x01            # no standard timings

    d = bytearray(18)
    d[0:2] = (t["pclk_khz"] // 10).to_bytes(2, "little")
    d[2], d[3] = t["ha"] & 0xFF, t["hb"] & 0xFF
    d[4] = ((t["ha"] >> 8) << 4) | (t["hb"] >> 8)
    d[5], d[6] = t["va"] & 0xFF, t["vb"] & 0xFF
    d[7] = ((t["va"] >> 8) << 4) | (t["vb"] >> 8)
    d[8], d[9] = t["hfp"] & 0xFF, t["hsw"] & 0xFF
    d[10] = ((t["vfp"] & 0xF) << 4) | (t["vsw"] & 0xF)
    d[11] = ((t["hfp"] >> 8) << 6) | ((t["hsw"] >> 8) << 4) | ((t["vfp"] >> 4) << 2) | (t["vsw"] >> 4)
    d[12], d[13] = wmm & 0xFF, hmm & 0xFF
    d[14] = ((wmm >> 8) << 4) | (hmm >> 8)
    d[17] = 0x1C                               # digital separate, -hsync +vsync
    e[54:72] = d

    def descriptor(tag, text):
        b = bytearray(18)
        b[3] = tag
        b[5:18] = text.ljust(13)[:13].encode()
        return b

    lo = t["pclk_khz"] / 1000.0
    rng = descriptor(0xFD, "")
    rng[5:11] = bytes([40, 80, 30, 80, int(lo // 10) + 1, 0])
    e[72:90] = rng
    e[90:108] = descriptor(0xFC, name)
    e[108:126] = descriptor(0xFE, "Ember panel")
    e[127] = (-sum(e[:127])) & 0xFF
    return bytes(e)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("width", type=int)
    p.add_argument("height", type=int)
    p.add_argument("hz", type=float, nargs="?", default=60.0)
    p.add_argument("-o", "--out", required=True)
    p.add_argument("--diag", type=float, help="panel diagonal in inches")
    p.add_argument("--name", default="Ember panel")
    a = p.parse_args()
    t = cvt(a.width, a.height, a.hz)
    if a.diag:
        r = (a.width ** 2 + a.height ** 2) ** 0.5
        wmm = round(a.diag * 25.4 * a.width / r)
        hmm = round(a.diag * 25.4 * a.height / r)
    else:
        wmm, hmm = round(a.width / 96 * 25.4), round(a.height / 96 * 25.4)
    open(a.out, "wb").write(build(t, wmm, hmm, a.name))
    print("%s: %dx%d @ %.4g Hz, %.3f MHz  (%d %d %d %d / %d %d %d %d)  %dx%d mm" % (
        a.out, t["ha"], t["va"], a.hz, t["pclk_khz"] / 1000.0,
        t["ha"], t["ha"] + t["hfp"], t["ha"] + t["hfp"] + t["hsw"], t["ha"] + t["hb"],
        t["va"], t["va"] + t["vfp"], t["va"] + t["vfp"] + t["vsw"], t["va"] + t["vb"],
        wmm, hmm))


if __name__ == "__main__":
    sys.exit(main())
