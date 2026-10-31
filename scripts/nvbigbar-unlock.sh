#!/bin/bash
# nvbigbar-unlock.sh — for MODDED GA10x cards (e.g. 3080 20G) whose vBIOS caps
# the ReBAR size table: re-widen the table (vendor reg 0x610) and set the
# ReBAR control size code to 32G AFTER the NVIDIA driver has bound, because any
# GPU reset snaps 0x610 back to factory and the driver's own resize logic will
# then shrink BAR1 back to 256M.
#
# THIS IS CARD-SPECIFIC HACKERY. 0x610 (FB_SIZE_OVERRIDE) and its mask/val are
# GA10x-specific. Do not run blindly on other chips. Cards that advertise 32G
# ReBAR natively (stock 3090 etc.) do NOT need this at all — check first:
#   cat /sys/bus/pci/devices/<bdf>/resource1_resize   # supported bitmap
#   bit15 set (…ffc0) = card can do 32G natively, skip it.
#   max bit8  (…01c0) = factory-capped, this script is about such cards.
#
# WARNING: while the driver is loaded these are RM-proxy registers. The script
# only ever runs the write when the value drifted from target (idempotent),
# which is the tested path. Values are volatile: power-cycle resets them.
#
# Usage: nvbigbar-unlock.sh [bdf...]   (default: $NVBIGBAR_CARDS, space-sep)
# Run from systemd oneshot + 60s re-assert timer (see systemd/ dir).
set -u

CARDS="${NVBIGBAR_CARDS:-$*}"
[ -n "$CARDS" ] || { echo "usage: nvbigbar-unlock.sh 0000:xx:yy.z ...  (or set NVBIGBAR_CARDS)" >&2; exit 1; }

REG_UNLOCK=0x610
MASK=0xF80
VAL=0xC80            # GA10x: widen FB_SIZE_OVERRIDE table to cover 32G
REBAR_CAPCTL=0xbc0   # PCIe ReBAR capability: ctrl dword (BAR1 size code in bits[13:8])
REBAR_MASK=0xbbc     # ... supported sizes dword
SIZE_CODE_32G=15     # size = 1<<(n+20) bytes → n=15 → 32G

log() { logger -t nvbigbar-unlock -- "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "need root" >&2; exit 1; }
command -v setpci >/dev/null || { log "setpci missing"; exit 1; }

# Writes before the driver binds get lost to the probe-time GPU reset.
[ -e /proc/driver/nvidia/version ] || { log "nvidia driver not loaded, skip"; exit 0; }

for bdf in $CARDS; do
    [ -e "/sys/bus/pci/devices/$bdf" ] || { log "$bdf absent"; continue; }

    v610=$(setpci -s "$bdf" $REG_UNLOCK.l 2>/dev/null) || { log "$bdf 0x610 read failed"; continue; }
    [ -n "$v610" ] || { log "$bdf 0x610 empty"; continue; }
    v610=$((0x$v610))
    if (( (v610 & MASK) != VAL )); then
        setpci -s "$bdf" $REG_UNLOCK.l=$(printf '%08X' $(( (v610 & ~MASK) | VAL ))) || { log "$bdf 0x610 write failed"; continue; }
        log "$bdf 0x610: 0x$(printf %08X $v610) -> 0x$(printf %08X $(( (v610 & ~MASK) | VAL )))"
    fi

    mask=$(setpci -s "$bdf" $REBAR_MASK.l 2>/dev/null)
    ctrl=$(setpci -s "$bdf" $REBAR_CAPCTL.l 2>/dev/null)
    [ -n "$mask" ] && [ -n "$ctrl" ] || { log "$bdf ReBAR regs unreadable"; continue; }
    mask=$((0x$mask)); ctrl=$((0x$ctrl))

    # never write a size code the (just-widened) table does not support
    if (( (mask >> SIZE_CODE_32G) & 1 )); then
        cur=$(( (ctrl >> 8) & 0x3f ))
        if (( cur != SIZE_CODE_32G )); then
            # low 3 bits of ctrl are the BAR index — preserve them
            setpci -s "$bdf" $REBAR_CAPCTL.l=$(printf '%08X' $(( (ctrl & ~0x3f00) | (SIZE_CODE_32G << 8) ))) || { log "$bdf ReBAR ctrl write failed"; continue; }
            rb=$(setpci -s "$bdf" $REBAR_CAPCTL.l)
            log "$bdf BAR1 size code: $cur -> $(( (0x$rb >> 8) & 0x3f )) (readback 0x$rb)"
        fi
    else
        log "$bdf size table lacks 32G (mask 0x$(printf %08X $mask)) — leave alone"
    fi
done
exit 0
