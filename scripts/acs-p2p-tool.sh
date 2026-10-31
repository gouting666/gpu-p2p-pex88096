#!/bin/bash
# acs-p2p-tool.sh — audit / clear PCIe ACS on the switches between your GPUs.
#
# THE HEADLINE: many PCIe switch firmwares (e.g. Broadcom/PLX PEX88096 boards)
# ship every Downstream Port with ACSCtl = 0x1d: SrcValid + ReqRedir +
# CmpltRedir + UpstreamFwd. This *compliantly* redirects GPU-to-GPU P2P TLPs
# back upstream to the host root complex, where they die on consumer platforms.
# Redirection sets NO error bits: no ACSViol, no BlockedTLP, no Xid, no DMAR
# fault. Reads return all-1 (UR), writes are silently dropped, and "zero AER
# delta" proves nothing. If your P2P "fails silently" behind a switch, clear
# ACS HERE before you spend days patching drivers (we did — 10 rounds).
#
# Subcommands:
#   audit          Read ACS cap + control word of every relevant bridge,
#                  decode bits, print verdict. READ-ONLY.
#   enable         Write 0 to the ACS control word of those bridges, verify
#                  readback, log via syslog. Idempotent. Needs root.
#   paths         Print the bridges discovered between GPU endpoints.
# Options:
#   --all          Consider every PCI-PCI bridge (class 0604), not just the
#                  ones between NVIDIA GPU endpoints.
#
# Scope: only bridges strictly between the endpoints are touched — root ports
# are NOT (they don't need it here and clearing them is a separate decision).
# ACS register layout: extended cap ID 0x000D, capability header at cap+0,
# control word at cap+6. Extended config space needs root.
#
# Persistence: switch reboots (firmware reload, host warm reboot that re-inits
# the switch) restore factory values. Run this from a systemd oneshot+timer
# (see systemd/ dir, and the RemainAfterExit trap documented there).
set -u

MODE=""
ALL=0
ARGS=()
for a in "$@"; do
  case "$a" in
    audit|enable|paths) MODE="$a" ;;
    --all) ALL=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
[ -n "$MODE" ] || { sed -n '2,20p' "$0"; exit 1; }

ACS_ID=13   # 0x000D
GPU_VENDOR=0x10de

die(){ echo "acs: $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "run as root — extended config space and writes need it"; }
[ "$MODE" = enable ] && need_root

# walk the extended capability list, print ACS cap offset (decimal) or fail
acs_off(){
  local dev=$1 off=$((0x100)) guard=0 dw id
  while (( off != 0 && guard < 64 )); do
    dw=$(setpci -s "$dev" "$(printf '0x%x' $off).l" 2>/dev/null) || return 1
    echo "$dw" | grep -qE '^[0-9a-fA-F]{8}$' || return 1
    [ "$dw" = "ffffffff" ] && return 1
    id=$(( 0x$dw & 0xffff ))
    if (( id == ACS_ID )); then echo "$off"; return 0; fi
    off=$(( (0x$dw >> 20) & 0xffc ))
    guard=$((guard+1))
  done
  return 1
}

decode_bits(){
  local v=$1 names=("SrcValid" "TranslationBlocking" "ReqRedir" "CmpltRedir" "UpstreamFwd" "EgressCtrl" "DirectTrans") out="" i
  for i in 0 1 2 3 4 5 6; do (( v & (1<<i) )) && out="$out ${names[$i]}"; done
  echo "${out# }"
}

gpu_bdfs(){
  local d
  for d in /sys/bus/pci/devices/*; do
    [ "$(cat $d/vendor 2>/dev/null)" = "$(printf '0x%04x' $GPU_VENDOR)" ] || continue
    grep -q '^0x03' "$d/class" 2>/dev/null || continue
    basename "$d"
  done
}

# bridges strictly between every GPU pair (deduped). Path segments under
# /sys/bus/pci/devices/ are the BDF chain from the root port down.
bridges_between_gpus(){
  local gpus=("$@") i j a b ka kb common pathA pathB
  for ((i=0;i<${#gpus[@]};i++)); do
    for ((j=i+1;j<${#gpus[@]};j++)); do
      IFS=/ read -ra pathA < <(realpath /sys/bus/pci/devices/${gpus[$i]})
      IFS=/ read -ra pathB < <(realpath /sys/bus/pci/devices/${gpus[$j]})
      common=0
      for ((ka=0;ka<${#pathA[@]}&&ka<${#pathB[@]};ka++)); do
        [ "${pathA[$ka]}" = "${pathB[$ka]}" ] || break
        common=$ka
      done
      # pathA[common]-is the first bridge after the divergence; last element
      # is the endpoint itself — exclude it.
      for ((kb=common;kb<${#pathA[@]}-1;kb++)); do echo "${pathA[$kb]}"; done | grep -E '^[0-9a-fA-F]{4}:' || true
      for ((kb=common;kb<${#pathB[@]}-1;kb++)); do echo "${pathB[$kb]}"; done | grep -E '^[0-9a-fA-F]{4}:' || true
    done
  done
}

all_bridges(){
  local d
  for d in /sys/bus/pci/devices/*/class; do
    grep -q '^0x0604' "$d" 2>/dev/null && basename "$(dirname "$d")"
  done
}

TARGETS=()
if (( ALL )); then
  TARGETS=($(all_bridges))
else
  GPUS=($(gpu_bdfs))
  [ ${#GPUS[@]} -ge 2 ] || die "found fewer than 2 NVIDIA GPUs; use --all to scan every bridge"
  TARGETS=($(bridges_between_gpus "${GPUS[@]}" | sort -u))
fi

if [ "$MODE" = paths ]; then
  echo "bridges between GPU endpoints:"; printf '  %s\n' "${TARGETS[@]}"
  exit 0
fi

FAIL=0
for d in "${TARGETS[@]}"; do
  off=$(acs_off "$d") || { echo "  $d  no ACS cap (nothing to clear)"; continue; }
  cur=$(setpci -s "$d" "$(printf '0x%x' $((off+6))).w" 2>/dev/null) || { echo "  $d  read failed"; continue; }
  if [ "$MODE" = audit ]; then
    printf '  %s  acs_cap=0x%03x ctl=0x%s  [%s]\n' "$d" "$off" "$cur" "$(decode_bits $((0x$cur)))"
    [ "$cur" = "0000" ] || FAIL=$((FAIL+1))
  else
    if [ "$cur" = "0000" ]; then continue; fi
    setpci -s "$d" "$(printf '0x%x' $((off+6))).w=0000"
    rb=$(setpci -s "$d" "$(printf '0x%x' $((off+6))).w")
    logger -t acs-p2p "$d ACS ctl @0x$(printf '%x' $((off+6))) $cur -> $rb"
    echo "  $d  $cur -> $rb"
    [ "$rb" = "0000" ] || FAIL=$((FAIL+1))
  fi
done

if [ "$MODE" = audit ]; then
  echo "bridges with ACS not clear: $FAIL  (a non-zero ReqRedir/CmpltRedir/UpstreamFwd is enough to kill GPU P2P behind this switch)"
  exit $(( FAIL > 0 ? 1 : 0 ))
fi
echo "done; $FAIL failures"
exit $FAIL
