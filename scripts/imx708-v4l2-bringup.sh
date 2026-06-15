#!/usr/bin/env bash
# IMX708 V4L2-raw bring-up checks for the Orin Nano dev kit (p3767/p3768).
# Run on-target after a capsule update / flash of the imx708-v4l2 branch
# and selecting the IMX708-V4L2-C overlay via jetson-io.
# Pure read-only by default; --capture writes one raw frame to /tmp.
#
# Usage:
#   ./imx708-v4l2-bringup.sh                       # run all checks, no capture
#   ./imx708-v4l2-bringup.sh --capture             # capture one frame at 2304x1296
#   ./imx708-v4l2-bringup.sh --capture --mode=4608 # capture at 4608x2592
#   ./imx708-v4l2-bringup.sh --device=/dev/video0  # override video device
#   ./imx708-v4l2-bringup.sh --selftest            # run synthetic-input self tests
#
# Test-injection env vars (used by --selftest, also handy for manual debug):
#   BRINGUP_DMESG_FILE      file to read instead of running dmesg
#   BRINGUP_V4L2_LIST_FILE  file containing fake `v4l2-ctl --list-devices` output
#   BRINGUP_V4L2_FMT_FILE   file containing fake `v4l2-ctl --list-formats-ext` output
#   BRINGUP_MEDIACTL_FILE   file containing fake `media-ctl -p` output
#   BRINGUP_FORCE_NO_DEVICE 1 to pretend $DEVICE doesn't exist

set -u
set -o pipefail

DEVICE=/dev/video0
DO_CAPTURE=0
DO_SELFTEST=0
MODE=2304
OUT=/tmp/imx708-bringup

for arg in "$@"; do
    case "$arg" in
        --capture)        DO_CAPTURE=1 ;;
        --selftest)       DO_SELFTEST=1 ;;
        --device=*)       DEVICE="${arg#*=}" ;;
        --mode=4608)      MODE=4608 ;;
        --mode=2304)      MODE=2304 ;;
        --mode=1536)      MODE=1536 ;;
        -h|--help)
            sed -n '2,18p' "$0"
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

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; pass=$((pass+1)); }
fly()  { printf '  \033[33mWARN\033[0m %s\n' "$1"; warn=$((warn+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
hdr()  { printf '\n=== %s ===\n' "$1"; }

# --- Pluggable input wrappers -------------------------------------------------

read_dmesg() {
    if [ -n "${BRINGUP_DMESG_FILE:-}" ] && [ -r "${BRINGUP_DMESG_FILE}" ]; then
        cat "$BRINGUP_DMESG_FILE"
    else
        dmesg 2>/dev/null
    fi
}

read_v4l2_list() {
    if [ -n "${BRINGUP_V4L2_LIST_FILE:-}" ] && [ -r "${BRINGUP_V4L2_LIST_FILE}" ]; then
        cat "$BRINGUP_V4L2_LIST_FILE"
        return 0
    fi
    if ! command -v v4l2-ctl >/dev/null 2>&1; then
        return 127
    fi
    v4l2-ctl --list-devices 2>&1
}

read_v4l2_formats() {
    if [ -n "${BRINGUP_V4L2_FMT_FILE:-}" ] && [ -r "${BRINGUP_V4L2_FMT_FILE}" ]; then
        cat "$BRINGUP_V4L2_FMT_FILE"
        return 0
    fi
    if ! command -v v4l2-ctl >/dev/null 2>&1; then
        return 127
    fi
    v4l2-ctl --device="$DEVICE" --list-formats-ext 2>&1
}

read_mediactl() {
    if [ -n "${BRINGUP_MEDIACTL_FILE:-}" ] && [ -r "${BRINGUP_MEDIACTL_FILE}" ]; then
        cat "$BRINGUP_MEDIACTL_FILE"
        return 0
    fi
    if ! command -v media-ctl >/dev/null 2>&1; then
        return 127
    fi
    media-ctl -p 2>/dev/null
}

device_exists() {
    if [ "${BRINGUP_FORCE_NO_DEVICE:-0}" = 1 ]; then
        return 1
    fi
    [ -e "$DEVICE" ]
}

# --- The actual checks --------------------------------------------------------

run_checks() {
    pass=0; fail=0; warn=0

    # 1. dmesg probe ---------------------------------------------------------
    hdr 'imx708 driver probe (dmesg)'

    probe=$(read_dmesg | grep -i imx708 || true)
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

    if echo "$probe" | grep -qi 'inclk frequency not supported\|failed to get inclk\|-ENODEV'; then
        bad 'inclk routing wrong — EXTPERIPH2 not delivering 24 MHz to PP.01'
        cat <<'HINT'
       Fallback procedure (4 .dtbo rebuilds + capsule updates worst case):

         Edit overlay/tegra234-p3767-camera-p3768-imx708-v4l2-C.dts
         in t23x-public-dts and replace TEGRA234_CLK_EXTPERIPH2 with one
         of EXTPERIPH1 / EXTPERIPH3 / EXTPERIPH4 in BOTH the `clocks` and
         `assigned-clocks` lines, then:

           cd ~/sources/t23x-public-dts && git commit -am 'try EXTPERIPHn'
           cd ~/public_repos/sources/jetpack-nixos
           rm pkgs/kernels/r36/patches/t23x-public-dts/0001-imx708-v4l2-add-camera-overlay.patch
           git -C ~/sources/t23x-public-dts format-patch -1 -o pkgs/kernels/r36/patches/t23x-public-dts/
           mv pkgs/kernels/r36/patches/t23x-public-dts/0001-overlay-* \
              pkgs/kernels/r36/patches/t23x-public-dts/0001-imx708-v4l2-add-camera-overlay.patch
           nix build .#nixosConfigurations.orin-nano-super-devkit.config.system.build.toplevel
           # capsule-update path (no re-flash) for the new generation

         Preferred order: 1, 3, 4 (PP.0x mapping argues these are
         less likely; EXTPERIPH2 was the prior best-inference).
HINT
    fi

    # 2. v4l2 device existence ----------------------------------------------
    hdr "$DEVICE existence + v4l2-ctl --list-devices"

    if ! device_exists; then
        bad "$DEVICE does not exist"
    else
        ok "$DEVICE exists"
    fi

    listing=$(read_v4l2_list 2>&1; echo "rc=$?")
    rc="${listing##*rc=}"
    listing="${listing%rc=*}"
    if [ "$rc" = 127 ]; then
        fly 'v4l2-ctl not on PATH; subsequent checks need it (apt install v4l-utils)'
    else
        echo "$listing" | sed 's/^/       /'
        if echo "$listing" | grep -qi 'imx708'; then
            ok 'v4l2-ctl --list-devices shows imx708 subdev'
        else
            fly 'no imx708 string in --list-devices (subdev may still be at /dev/v4l-subdev*)'
        fi
    fi

    # 3. listing formats ----------------------------------------------------
    hdr 'advertised formats / sizes / framerates'

    formats=$(read_v4l2_formats 2>&1; echo "rc=$?")
    rc="${formats##*rc=}"
    formats="${formats%rc=*}"

    if [ "$rc" = 127 ] || ! device_exists; then
        fly 'skipped — v4l2-ctl missing or device absent'
    else
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
    fi

    # 4. media topology -----------------------------------------------------
    hdr 'media graph (media-ctl)'

    topology=$(read_mediactl 2>&1; echo "rc=$?")
    rc="${topology##*rc=}"
    topology="${topology%rc=*}"

    if [ "$rc" = 127 ]; then
        fly 'media-ctl not on PATH; skipping (apt install v4l-utils)'
    elif [ -z "$topology" ]; then
        fly 'media-ctl returned empty (need /dev/media* perms?)'
    else
        echo "$topology" > "$OUT/media-topology.txt"
        ok "topology saved to $OUT/media-topology.txt"
        if echo "$topology" | grep -qi 'imx708'; then
            ok 'imx708 entity present in media graph'
        else
            bad 'imx708 entity NOT in media graph — graph wiring broken'
        fi
        if echo "$topology" | grep -qE 'imx708.*->|NVCSI.*->|nvcsi.*->'; then
            ok 'imx708 / NVCSI link present'
        else
            fly 'no obvious sensor->bridge link in topology (manual review needed)'
        fi
    fi

    # 5. capture (optional) -------------------------------------------------
    if [ "$DO_CAPTURE" = 1 ]; then
        hdr "single-frame capture (mode=$MODE)"
        case "$MODE" in
            4608) W=4608; H=2592 ;;
            2304) W=2304; H=1296 ;;
            1536) W=1536; H=864  ;;
        esac
        out_raw="$OUT/imx708-${W}x${H}.raw"
        rm -f "$out_raw"

        if ! command -v v4l2-ctl >/dev/null 2>&1 || ! device_exists; then
            bad 'cannot capture — v4l2-ctl missing or device absent'
        else
            timeout 5 v4l2-ctl --device="$DEVICE" \
                --set-fmt-video="width=$W,height=$H,pixelformat=RG10" \
                --stream-mmap=4 --stream-count=1 --stream-to="$out_raw" 2>&1 \
                | sed 's/^/       /' || true

            if [ -s "$out_raw" ]; then
                sz=$(stat -c%s "$out_raw")
                expect=$(( W * H * 2 ))
                ok "captured frame: $out_raw ($sz bytes; expected ~$expect)"
                if [ "$sz" -lt $(( expect / 2 )) ]; then
                    fly 'frame is much smaller than expected — partial / truncated'
                fi
                hex=$(head -c 1024 "$out_raw" | od -An -tx1 | tr -d ' \n')
                if echo "$hex" | grep -qE '^0+$'; then
                    bad 'first 1KB is all zero — VI returned blank frame'
                fi
                if echo "$hex" | grep -qE '^[fF]+$'; then
                    bad 'first 1KB is all 0xFF — sensor saturating / signaling error'
                fi
            else
                bad 'no frame captured (file empty or absent)'
            fi
        fi

        hdr 'CSI/VI errors during streamon (dmesg tail)'
        read_dmesg | tail -50 \
            | grep -iE 'tegra-vi|nvcsi|imx708|frame.*timeout|sof|crc' \
            | tail -20 | sed 's/^/       /' || true
    fi

    hdr 'summary'
    printf '  pass: %d\n  warn: %d\n  fail: %d\n' "$pass" "$warn" "$fail"
}

# --- Selftest harness ---------------------------------------------------------

selftest() {
    local tmp; tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    local total_pass=0 total_fail=0 total_warn=0 case_count=0 case_failed=0

    run_case() {
        case_count=$((case_count + 1))
        local name="$1"; shift
        local expect_fail="$1"; shift
        echo
        echo "─── case: $name (expect fail >= $expect_fail)"
        # Discard normal output; just collect tallies.
        local out
        out=$("$@" 2>&1)
        local cur_pass cur_fail cur_warn
        cur_pass=$(echo "$out" | awk '/^  pass:/ {print $2; exit}')
        cur_fail=$(echo "$out" | awk '/^  fail:/ {print $2; exit}')
        cur_warn=$(echo "$out" | awk '/^  warn:/ {print $2; exit}')
        echo "    pass=$cur_pass fail=$cur_fail warn=$cur_warn"
        total_pass=$((total_pass + cur_pass))
        total_fail=$((total_fail + cur_fail))
        total_warn=$((total_warn + cur_warn))
        if [ "$cur_fail" -lt "$expect_fail" ]; then
            echo "    *** FAIL: expected at least $expect_fail fail, got $cur_fail"
            case_failed=$((case_failed + 1))
        fi
    }

    # Case A: nothing works (empty dmesg, no v4l2-utils, no /dev/video0)
    : > "$tmp/dmesg_empty"
    BRINGUP_DMESG_FILE="$tmp/dmesg_empty" \
    BRINGUP_FORCE_NO_DEVICE=1 \
    BRINGUP_V4L2_LIST_FILE="" BRINGUP_V4L2_FMT_FILE="" BRINGUP_MEDIACTL_FILE="" \
        run_case 'nothing-works' 2 run_checks

    # Case B: probe with errors visible
    cat > "$tmp/dmesg_inclk" <<'EOF'
[    7.123] imx708 8-001a: failed to get inclk
[    7.124] imx708 8-001a: probe failed with error -ENODEV
EOF
    BRINGUP_DMESG_FILE="$tmp/dmesg_inclk" \
    BRINGUP_FORCE_NO_DEVICE=1 \
        run_case 'inclk-mismatch' 2 run_checks

    # Case C: probe ok but no media graph
    cat > "$tmp/dmesg_ok" <<'EOF'
[    7.123] imx708 8-001a: model id 0x0708, revision 0x01
[    7.124] imx708 8-001a: registered as /dev/v4l-subdev2
EOF
    cat > "$tmp/v4l2_list_ok" <<'EOF'
NVIDIA Tegra Video Input Device (platform:tegra-capture-vi):
        /dev/media0
imx708 8-001a (platform:tegra-capture-vi):
        /dev/v4l-subdev2
        /dev/video0
EOF
    cat > "$tmp/v4l2_fmt_ok" <<'EOF'
ioctl: VIDIOC_ENUM_FMT
        Type: Video Capture
        [0]: 'RG10' (10-bit Bayer RGRG/GBGB)
                Size: Discrete 4608x2592
                Size: Discrete 2304x1296
                Size: Discrete 1536x864
EOF
    : > "$tmp/mediactl_empty"
    BRINGUP_DMESG_FILE="$tmp/dmesg_ok" \
    BRINGUP_V4L2_LIST_FILE="$tmp/v4l2_list_ok" \
    BRINGUP_V4L2_FMT_FILE="$tmp/v4l2_fmt_ok" \
    BRINGUP_MEDIACTL_FILE="$tmp/mediactl_empty" \
        run_case 'probe-ok-no-mediagraph' 0 run_checks

    # Case D: full happy path
    cat > "$tmp/mediactl_full" <<'EOF'
- entity 1: tegra-capture-vi
- entity 7: NVCSI-12 [pad source]
- entity 13: imx708 8-001a [pad source]
        pad0: Source -> "NVCSI-12":0 [ENABLED]
EOF
    BRINGUP_DMESG_FILE="$tmp/dmesg_ok" \
    BRINGUP_V4L2_LIST_FILE="$tmp/v4l2_list_ok" \
    BRINGUP_V4L2_FMT_FILE="$tmp/v4l2_fmt_ok" \
    BRINGUP_MEDIACTL_FILE="$tmp/mediactl_full" \
        run_case 'all-happy' 0 run_checks

    echo
    echo "═══ selftest summary"
    echo "    cases     : $case_count"
    echo "    case fails: $case_failed"
    echo "    total pass: $total_pass"
    echo "    total fail: $total_fail"
    echo "    total warn: $total_warn"
    return "$case_failed"
}

if [ "$DO_SELFTEST" = 1 ]; then
    # Suppress per-case detail; exit code reflects test-case correctness.
    selftest
    exit $?
fi

run_checks
[ "$fail" -eq 0 ]
