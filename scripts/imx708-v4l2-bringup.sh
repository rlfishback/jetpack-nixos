#!/usr/bin/env bash
# IMX708 V4L2-raw bring-up checks for the Orin Nano dev kit (p3767/p3768).
# Run on-target after flashing the imx708-v4l2 branch and selecting the
# IMX708-V4L2-C overlay via jetson-io. Pure read-only; no system mutation.
#
# Usage:
#   ./imx708-v4l2-bringup.sh                       # run all checks, no capture
#   ./imx708-v4l2-bringup.sh --capture             # capture one frame at 2304x1296
#   ./imx708-v4l2-bringup.sh --capture --mode=4608 # capture at 4608x2592
#   ./imx708-v4l2-bringup.sh --device=/dev/video0  # override video device

set -u
set -o pipefail

DEVICE=/dev/video0
DO_CAPTURE=0
MODE=2304
OUT=/tmp/imx708-bringup

for arg in "$@"; do
    case "$arg" in
        --capture)        DO_CAPTURE=1 ;;
        --device=*)       DEVICE="${arg#*=}" ;;
        --mode=4608)      MODE=4608 ;;
        --mode=2304)      MODE=2304 ;;
        --mode=1536)      MODE=1536 ;;
        -h|--help)
            sed -n '2,11p' "$0"
            exit 0
            ;;
        *)
            echo "unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

mkdir -p "$OUT"

pass=0
fail=0
warn=0

ok()   { printf '  \e[32mOK\e[0m   %s\n' "$1"; pass=$((pass+1)); }
fly()  { printf '  \e[33mWARN\e[0m %s\n' "$1"; warn=$((warn+1)); }
bad()  { printf '  \e[31mFAIL\e[0m %s\n' "$1"; fail=$((fail+1)); }
hdr()  { printf '\n=== %s ===\n' "$1"; }

# 1. dmesg probe -----------------------------------------------------------
hdr 'imx708 driver probe (dmesg)'

probe=$(dmesg 2>/dev/null | grep -i imx708 || true)
if [ -z "$probe" ]; then
    bad 'no imx708 lines in dmesg — driver did not probe'
    echo '       likely causes:'
    echo '         - overlay not selected (run jetson-io.py)'
    echo '         - sensor not on i2c (check ribbon, i2c mux, power)'
    echo '         - imx708 module not loaded (modprobe imx708)'
else
    echo "$probe" | sed 's/^/       /'
    if echo "$probe" | grep -qiE 'failed|error|timeout|not.*supported|-ENODEV'; then
        bad 'imx708 dmesg shows errors — see above'
    else
        ok 'imx708 lines present, no error keywords'
    fi
fi

if echo "$probe" | grep -qi 'inclk frequency not supported'; then
    bad 'inclk rate mismatch — EXTPERIPH2 not delivering 24 MHz'
    echo '       fallback: try EXTPERIPH1/3/4 in the overlay (4 flashes worst case)'
fi

# 2. v4l2 device existence -------------------------------------------------
hdr "$DEVICE existence + v4l2-ctl --list-devices"

if [ ! -e "$DEVICE" ]; then
    bad "$DEVICE does not exist"
else
    ok "$DEVICE exists"
fi

if ! command -v v4l2-ctl >/dev/null 2>&1; then
    fly 'v4l2-ctl not on PATH; subsequent checks need it (apt install v4l-utils)'
else
    listing=$(v4l2-ctl --list-devices 2>&1 || true)
    echo "$listing" | sed 's/^/       /'
    if echo "$listing" | grep -qi 'imx708'; then
        ok 'v4l2-ctl --list-devices shows imx708 subdev'
    else
        fly 'no imx708 string in --list-devices (subdev may still be at /dev/v4l-subdev*)'
    fi
fi

# 3. listing formats -------------------------------------------------------
hdr 'advertised formats / sizes / framerates'

if command -v v4l2-ctl >/dev/null 2>&1 && [ -e "$DEVICE" ]; then
    formats=$(v4l2-ctl --device="$DEVICE" --list-formats-ext 2>&1 || true)
    echo "$formats" | sed 's/^/       /'

    if echo "$formats" | grep -qE 'RG10|SRGGB10|BA10'; then
        ok 'SRGGB10 / RG10 advertised by /dev/video* node'
    else
        bad 'no SRGGB10/RG10 format — VI/CSI may not be linked to imx708'
    fi

    for w in 4608 2304 1536; do
        if echo "$formats" | grep -qE "${w}x"; then
            ok "size ${w}x* advertised"
        else
            fly "size ${w}x* not advertised — driver may have only enabled a subset"
        fi
    done
else
    fly 'skipped — v4l2-ctl missing or device absent'
fi

# 4. media topology (link discovery) ---------------------------------------
hdr 'media graph (media-ctl)'

if command -v media-ctl >/dev/null 2>&1; then
    media-ctl --print-dot 2>/dev/null > "$OUT/media-graph.dot" \
        && ok "graph saved to $OUT/media-graph.dot" \
        || fly 'media-ctl --print-dot failed (may need /dev/media* perms)'

    media-ctl -p 2>/dev/null > "$OUT/media-topology.txt" \
        && ok "topology saved to $OUT/media-topology.txt" \
        || true

    if [ -s "$OUT/media-topology.txt" ]; then
        if grep -qi 'imx708' "$OUT/media-topology.txt"; then
            ok 'imx708 entity present in media graph'
        else
            bad 'imx708 entity NOT in media graph — graph wiring broken'
        fi
        if grep -qE 'imx708.*->' "$OUT/media-topology.txt" || \
           grep -qE 'NVCSI.*->' "$OUT/media-topology.txt"; then
            ok 'imx708 / NVCSI link present'
        else
            fly 'no obvious sensor->bridge link in topology (manual review needed)'
        fi
    fi
else
    fly 'media-ctl not on PATH; skipping (apt install v4l-utils)'
fi

# 5. capture (optional) ----------------------------------------------------
if [ "$DO_CAPTURE" = 1 ]; then
    hdr "single-frame capture (mode=$MODE)"

    case "$MODE" in
        4608) W=4608; H=2592 ;;
        2304) W=2304; H=1296 ;;
        1536) W=1536; H=864  ;;
    esac

    out_raw="$OUT/imx708-${W}x${H}.raw"
    rm -f "$out_raw"

    if ! command -v v4l2-ctl >/dev/null 2>&1 || [ ! -e "$DEVICE" ]; then
        bad 'cannot capture — v4l2-ctl missing or device absent'
    else
        # NB: 5s wallclock budget; if streamon hangs that's the bug.
        timeout 5 v4l2-ctl --device="$DEVICE" \
            --set-fmt-video="width=$W,height=$H,pixelformat=RG10" \
            --stream-mmap=4 --stream-count=1 --stream-to="$out_raw" 2>&1 \
            | sed 's/^/       /' || true

        if [ -s "$out_raw" ]; then
            sz=$(stat -c%s "$out_raw")
            expect=$(( W * H * 2 ))   # RG10 packs 10b in 16b, ~2 bytes/pixel
            ok "captured frame: $out_raw ($sz bytes; expected ~$expect)"
            if [ "$sz" -lt $(( expect / 2 )) ]; then
                fly 'frame is much smaller than expected — partial / truncated'
            fi
            # quick all-zero / all-FF detection
            head -c 1024 "$out_raw" | od -An -tx1 | tr -d ' \n' \
                | grep -qE '^0+$' && bad 'first 1KB is all zero — VI returned blank frame'
            head -c 1024 "$out_raw" | od -An -tx1 | tr -d ' \n' \
                | grep -qE '^[fF]+$' && bad 'first 1KB is all 0xFF — sensor saturating / signaling error'
        else
            bad 'no frame captured (file empty or absent)'
        fi
    fi

    hdr 'CSI/VI errors during streamon (dmesg tail)'
    dmesg 2>/dev/null | tail -50 | grep -iE 'tegra-vi|nvcsi|imx708|frame.*timeout|sof|crc' \
        | tail -20 | sed 's/^/       /' || true
fi

# Summary ------------------------------------------------------------------
hdr 'summary'
printf '  pass: %d\n  warn: %d\n  fail: %d\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ]
