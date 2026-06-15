#!/usr/bin/env python3
"""
imx708-tune.py — apply RPi libcamera IMX708 tuning JSON to a raw V4L2 frame.

Pure Python (numpy, optional Pillow for PNG output). NO LSC, NO AGC.
Input is the .raw produced by `imx708-v4l2-bringup.sh --capture` or any
v4l2-ctl --stream-to= output of pixel format RG10 (10-bit Bayer in
16-bit words, RGGB pattern).

Pipeline:
    raw bytes -> uint16 array
    -> black-level subtract (per rpi.black_level)
    -> bilinear debayer (RGGB -> RGB float32)
    -> grey-world WB (mean R/G/B equalisation; ignores rpi.awb)
    -> CCM (per rpi.ccm — picks closest CT entry to D65=6500K by default)
    -> normalise / gamma 2.2 / clip to 8-bit
    -> PNG

Usage:
    imx708-tune.py --width 2304 --height 1296 \\
        --tuning third-party/rpi-libcamera-tuning/imx708.json \\
        --in /tmp/imx708-bringup/imx708-2304x1296.raw \\
        --out /tmp/imx708-2304x1296.png

The acceptance bar (per bd imx708-awi) is "color cast within 1.5x of a
Pi-5-libcamera reference of the same scene". This tool is sufficient to
hit that bar; LSC and AGC are explicit non-goals.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

try:
    from PIL import Image
except ImportError:
    Image = None  # type: ignore[assignment]


def load_tuning(path: Path) -> dict:
    """Load a libcamera-rpi tuning JSON; return a flat dict of algorithm blocks."""
    doc = json.loads(path.read_text())
    blocks: dict = {}
    for entry in doc["algorithms"]:
        for key, value in entry.items():
            blocks[key] = value
    return blocks


def select_ccm(blocks: dict, target_ct: int = 6500) -> np.ndarray:
    """Pick the rpi.ccm entry whose `ct` is closest to target_ct; return 3x3."""
    ccms = blocks["rpi.ccm"]["ccms"]
    chosen = min(ccms, key=lambda c: abs(c["ct"] - target_ct))
    matrix = np.array(chosen["ccm"], dtype=np.float32).reshape(3, 3)
    return matrix


def unpack_rg10(raw: bytes, width: int, height: int) -> np.ndarray:
    """Unpack RG10: 10-bit values stored in 16-bit little-endian words.

    Pixel format string is 'RG10' (V4L2 four-cc), bayer pattern is RGGB.
    Each pixel occupies 2 bytes; only the low 10 bits carry data.
    """
    arr = np.frombuffer(raw, dtype="<u2", count=width * height)
    arr = arr.reshape(height, width)
    return (arr & 0x03FF).astype(np.float32)


def debayer_rggb_bilinear(bayer: np.ndarray) -> np.ndarray:
    """Bilinear RGGB demosaic to HxWx3 RGB. Edges are zero-padded; cropped after."""
    h, w = bayer.shape
    rgb = np.zeros((h, w, 3), dtype=np.float32)

    rows = np.arange(h)[:, None]
    cols = np.arange(w)[None, :]
    is_red_row = (rows % 2 == 0)
    is_red_col = (cols % 2 == 0)
    is_red = is_red_row & is_red_col
    is_blue = (~is_red_row) & (~is_red_col)
    is_green_r = is_red_row & (~is_red_col)   # green on red row
    is_green_b = (~is_red_row) & is_red_col   # green on blue row

    # Direct samples
    rgb[..., 0][is_red] = bayer[is_red]
    rgb[..., 2][is_blue] = bayer[is_blue]
    rgb[..., 1][is_green_r | is_green_b] = bayer[is_green_r | is_green_b]

    # Pad once, work on padded view, slice back
    bp = np.pad(bayer, 1, mode="edge")
    nW = bp[:-2, 1:-1]
    nE = bp[2:, 1:-1]
    nS = bp[1:-1, :-2]
    nN = bp[1:-1, 2:]
    nNW = bp[:-2, :-2]
    nNE = bp[:-2, 2:]
    nSW = bp[2:, :-2]
    nSE = bp[2:, 2:]

    # Green at red sites: average of 4 cardinal greens
    g_at_red = 0.25 * (nW + nE + nS + nN)
    rgb[..., 1][is_red] = g_at_red[is_red]
    rgb[..., 1][is_blue] = g_at_red[is_blue]

    # Red at green-on-red row sites: avg of 2 horizontal reds
    rgb[..., 0][is_green_r] = 0.5 * (nS[is_green_r] + nN[is_green_r])
    # Red at green-on-blue row sites: avg of 2 vertical reds
    rgb[..., 0][is_green_b] = 0.5 * (nW[is_green_b] + nE[is_green_b])
    # Red at blue sites: avg of 4 diagonal reds
    rgb[..., 0][is_blue] = 0.25 * (nNW[is_blue] + nNE[is_blue] + nSW[is_blue] + nSE[is_blue])

    # Mirror the pattern for blue
    rgb[..., 2][is_green_b] = 0.5 * (nS[is_green_b] + nN[is_green_b])
    rgb[..., 2][is_green_r] = 0.5 * (nW[is_green_r] + nE[is_green_r])
    rgb[..., 2][is_red] = 0.25 * (nNW[is_red] + nNE[is_red] + nSW[is_red] + nSE[is_red])

    return rgb


def grey_world_wb(rgb: np.ndarray) -> np.ndarray:
    """Multiply each channel so its mean equals the global mean. Naive AWB."""
    means = rgb.mean(axis=(0, 1))
    means = np.where(means < 1.0, 1.0, means)
    overall = means.mean()
    gains = overall / means
    return rgb * gains


def apply_ccm(rgb: np.ndarray, ccm: np.ndarray) -> np.ndarray:
    """Apply 3x3 CCM (rows are output channels)."""
    h, w, _ = rgb.shape
    flat = rgb.reshape(-1, 3)
    out = flat @ ccm.T
    return out.reshape(h, w, 3)


def to_uint8_srgb(rgb: np.ndarray, pct: float = 99.0, gamma: float = 2.2) -> np.ndarray:
    """Normalise to the given percentile, gamma-encode, clip, return uint8."""
    target = np.percentile(rgb, pct)
    if target <= 0:
        target = 1.0
    norm = np.clip(rgb / target, 0, 1)
    encoded = np.power(norm, 1.0 / gamma)
    return (encoded * 255).astype(np.uint8)


def write_png(arr: np.ndarray, path: Path) -> None:
    if Image is None:
        raise RuntimeError(
            "Pillow not installed; install with `nix shell nixpkgs#python3Packages.pillow` "
            "or write the array to a different format."
        )
    Image.fromarray(arr).save(path)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--in", dest="raw_path", type=Path, required=True, help="raw V4L2 frame (.raw)")
    p.add_argument("--width", type=int, required=True, help="frame width in pixels")
    p.add_argument("--height", type=int, required=True, help="frame height in pixels")
    p.add_argument("--tuning", type=Path, required=True, help="path to imx708.json")
    p.add_argument("--out", dest="out_path", type=Path, required=True, help="output PNG")
    p.add_argument("--ct", type=int, default=6500, help="target colour temperature (K) for CCM selection")
    p.add_argument("--no-wb", action="store_true", help="skip grey-world WB")
    p.add_argument("--no-ccm", action="store_true", help="skip CCM application")
    p.add_argument("--gamma", type=float, default=2.2, help="output gamma (default 2.2)")
    p.add_argument("--norm-pct", type=float, default=99.0, help="percentile for white normalisation")
    args = p.parse_args()

    if not args.raw_path.exists():
        print(f"input not found: {args.raw_path}", file=sys.stderr)
        return 2

    expected = args.width * args.height * 2
    raw = args.raw_path.read_bytes()
    if len(raw) < expected:
        print(
            f"raw size {len(raw)} < expected {expected} for "
            f"{args.width}x{args.height} RG10 — frame truncated?",
            file=sys.stderr,
        )
        return 3

    print(f"loading tuning: {args.tuning}", file=sys.stderr)
    blocks = load_tuning(args.tuning)
    black_level = float(blocks["rpi.black_level"]["black_level"])
    if black_level > 1023:
        # RPi quotes black level in 16-bit space (4096 = 256 in 10-bit)
        black_level /= 64.0
    print(f"  black_level (10-bit): {black_level:.1f}", file=sys.stderr)

    print(f"unpacking {args.width}x{args.height} RG10 ...", file=sys.stderr)
    bayer = unpack_rg10(raw[:expected], args.width, args.height)
    bayer = np.maximum(bayer - black_level, 0.0)

    print("debayering ...", file=sys.stderr)
    rgb = debayer_rggb_bilinear(bayer)

    if not args.no_wb:
        print("grey-world WB ...", file=sys.stderr)
        rgb = grey_world_wb(rgb)

    if not args.no_ccm:
        ccm = select_ccm(blocks, target_ct=args.ct)
        chosen_ct = min(blocks["rpi.ccm"]["ccms"], key=lambda c: abs(c["ct"] - args.ct))["ct"]
        print(f"CCM (closest to {args.ct}K -> {chosen_ct}K) ...", file=sys.stderr)
        rgb = apply_ccm(rgb, ccm)

    print(f"normalising at p{args.norm_pct} + gamma {args.gamma} ...", file=sys.stderr)
    out = to_uint8_srgb(rgb, pct=args.norm_pct, gamma=args.gamma)

    print(f"writing {args.out_path} ({out.shape})", file=sys.stderr)
    write_png(out, args.out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
