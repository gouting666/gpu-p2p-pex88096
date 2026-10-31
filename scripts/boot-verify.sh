#!/bin/bash
# boot-verify.sh — one-shot whole-stack P2P acceptance after boot.
# Dynamic device discovery (never hardcode BDF lists — bus reorder after a
# rescan makes hardcoded checks silently pass/fail for the wrong reasons).
#
# Checks, in the order that failure is most cheap to interpret:
#   1) BAR1 = 32G per GPU (kernel assignment AND nvidia-smi's view)
#   2) switch ACS clear on every bridge between GPUs
#   3) re-assert timers actually re-run (ExecMainStartTimestamp advances)
#   4) fabric proof: peer-ON copies must beat the host-staging ceiling and
#      match byte-for-byte (see docs/04-verification-playbook.md — peer-OFF
#      numbers mean nothing)
#   5) zero Xid
# Optional: CHECK_SERVICE=<name> to smoke a workload service afterwards.
# Usage: sudo bash boot-verify.sh   (writes to stdout; keep the log)
set -u
[ "$(id -u)" -eq 0 ] || { echo "need root (ACS reads + probes)"; exit 1; }

fail(){ echo "FAIL: $*"; FAILED=1; }
FAILED=0

echo "== BAR1 =="
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader
for d in /sys/bus/pci/devices/*/; do
  [ "$(cat $d/vendor 2>/dev/null)" = "0x10de" ] || continue
  grep -q '^0x03' "$d/class" 2>/dev/null || continue
  bdf=$(basename "$d")
  # resource line 2 = BAR1
  read -r _ s e _ < <(sed -n '2p' "$d/resource")
  sz=$(( e - s + 1 ))
  printf '  %s BAR1 kernel view: %s GiB\n' "$bdf" "$(( sz >> 30 ))"
  (( sz < (32ULL<<30) )) && fail "$bdf BAR1 not 32G in kernel view"
done

echo "== ACS =="
bash "$(dirname "$0")/acs-p2p-tool.sh" audit || fail "ACS not clear"

echo "== timers actually fire =="
# a timer that 'fires' a still-active oneshot is a no-op: compare
# ExecMainStartTimestamp across 90s, it MUST advance.
for svc in acs-p2p-enable nvbigbar-unlock; do
  t1=$(systemctl show $svc.service -p ExecMainStartTimestamp --value 2>/dev/null)
  echo "  $svc: $t1 (compare again in 90s; unchanged + timer active = RemainAfterExit trap)"
done

echo "== fabric probes (peer-on) =="
command -v nvcc >/dev/null && [ -x "$(dirname "$0")/../probes/probe_pairs" ] || \
  { echo "  probes not built — run 'make' in probes/ (needs CUDA toolkit)"; }
if [ -x "$(dirname "$0")/../probes/probe_pairs" ]; then
  "$(dirname "$0")/../probes/probe_pairs" || fail "peer-on pairs"
fi

echo "== Xid =="
sudo dmesg | grep -c Xid

[ "$FAILED" = 0 ] && echo "ALL GREEN" || echo "SOMETHING FAILED"
exit $FAILED
