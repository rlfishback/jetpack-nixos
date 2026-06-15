# RPi libcamera IPA tuning files (vendored)

Camera-tuning JSON files for the IMX708 sensor module, vendored from the
RaspberryPi fork of libcamera. Used by the V4L2-raw IMX708 path
(`rlfishback/imx708-v4l2`) — see bd issue `imx708-awi` for context.

## Why these files are here

The Tegra ISP block has no IMX708 calibration and there is no
NVIDIA-supplied `.isp` override file. RidgeRun's tegracam-style driver
ships none either. The V4L2-raw path therefore emits **uncorrected
bayer**: green-shifted, no white balance, no black-level subtraction,
no lens shading correction.

These tuning files are RPi's calibrations of the **same sensor module
(Cam Module 3 / wide / NoIR variants)** against the **same lens
hardware**, derived for libcamera's RPi IPA. They contain the parameters
needed to render acceptable color from raw bayer in software when no
ISP is in the path:

- `rpi.black_level` — per-channel pedestal subtraction
- `rpi.ccm` — 3x3 colour correction matrix per illuminant
- `rpi.alsc` — lens shading correction (16x12 grid per channel)
- `rpi.awb` — automatic white balance gains by colour temperature
- `rpi.agc` — auto gain/exposure target curves
- (other algorithm blocks ignored for our use)

We do **not** run libcamera in the V4L2-raw pipeline. These JSONs are
parsed by our own post-processing tooling (Python / GStreamer plugin)
that consumes raw V4L2 frames from `/dev/videoN` and applies the same
math the RPi IPA does, just in a different runtime.

## Files

| File | Variant |
|---|---|
| `imx708.json` | Standard Cam Module 3 (color, standard FoV) |
| `imx708_wide.json` | Cam Module 3 Wide (different lens, different LSC + CCM) |
| `imx708_noir.json` | NoIR (IR-pass, different IR/visible balance) |
| `imx708_wide_noir.json` | Wide + NoIR combined |

Pick the one matching the physical sensor module wired to CAM1.

## Provenance

- Upstream: <https://github.com/raspberrypi/libcamera>
- Path in upstream: `src/ipa/rpi/vc4/data/`
- Vendored at: 2026-06-15
- Tree commit at fetch time:
  `daa1585206e4874681d240ed5b7104bb52d06319`
  (last commit touching `imx708.json`:
  `9f4754cbc6f9ae2276c9e2f42db9302e64c723b5`,
  "ipa: rpi: awb: Update neural network AWB tunings for vc4 platform",
  2026-02-05)

To update:
```
gh api repos/raspberrypi/libcamera/contents/src/ipa/rpi/vc4/data \
  --jq '.[] | select(.name | test("^imx708")) | .download_url' \
  | xargs -L1 curl -fsSLO
```

## Caveats — VC4 vs Tegra differences

These files target VC4 ISP block sizes and quirks; not all fields
translate 1:1 to standalone post-processing:

- `target: "bcm2835"` — purely informational, ignore.
- LSC grid: 16x12 fixed by VC4 hardware. Software implementations
  must match (or upsample at runtime).
- HDR / AGC sections rely on RPi sensor embedded-data-line parsing
  (PDAF + AE-HIST). In V4L2-raw mode we don't extract embedded
  metadata, so AGC must be re-implemented atop V4L2_CID_EXPOSURE /
  V4L2_CID_ANALOGUE_GAIN (the upstream imx708 driver exposes both as
  standard V4L2 controls).
- NN-based AWB block is data only; needs a runtime that can evaluate
  it. Falling back to grey-world AWB is acceptable for most use.

## Licensing

Per upstream `COPYING.rst`: libcamera IPA module data (including
these tuning files) is covered by a free-software license. The files
have no explicit SPDX header; they are vendored alongside this README
that records the upstream source. Treat them as redistributable on
the same terms as upstream libcamera-rpi.
