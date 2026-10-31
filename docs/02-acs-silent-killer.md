> **本项目P2P实现由AI攻克，github代码AI编写上传，本人非专业代码人员，仅供参考。**
>
> *The P2P implementation in this project was worked out by AI; the code was written
> and uploaded by AI. The author is not a professional developer — for reference only.*

# ACS ReqRedir: the silent killer of PCIe P2P behind a switch

## What ACS is

ACS (Access Control Services) is a PCI feature (extended capability ID
**0x000D**) designed to control peer-to-peer TLP routing between
downstream ports — its raison d'être is virtualization security: with
VFIO/IOMMU groups, you often *want* ACS so one VM's device can't DMA into
another's. A PCIe switch downstream port with ACS can:

| Bit | Name | Effect when set |
|---|---|---|
| 0 | SrcValid | validate requester ID on forwarded TLPs |
| 1 | TranslationBlocking | block untranslated (address-type) TLPs |
| 2 | **ReqRedir** | **redirect P2P *requests* upstream toward the root complex** |
| 3 | **CmpltRedir** | redirect completions toward the requester via RC |
| 4 | **UpstreamFwd** | forward upstream-originated P2P (RC → device → device) |
| 5 | EgressCtrl | per-port egress control vector |
| 6 | DirectTrans | direct transmittal |

Control word lives at **cap offset + 0x06**.

The killer combination for multi-GPU boxes is **ReqRedir+CmpltRedir+UpstreamFwd**
(bits 2/3/4): every GPU→GPU request is legally forwarded *up* the fabric to
the root complex, which on consumer Intel platforms won't route it back down
to the peer — the request dies there and the peer never sees it. From the
GPU's point of view the read gets an Unsupported Request completion (reads
return all-`0xFF`), and writes go nowhere.

**Why nothing reports it:** redirection is *forwarding*, not blocking. The
ACS "blocked TLP" counter (BlockedTLP) only counts TLPs ACS actually denied;
the "ACSViol" status only fires on specific approve-fail conditions. A
redirect that completes (however pathologically downstream) sets **no error
bits anywhere**. The root complex killing it is a *different* agent, and
consumer RCs kill quietly. Result: the entire failure is invisible to
standard error telemetry.

## The exact symptom triad to fear

If ALL of these hold, suspect ACS redirection before anything else:

1. Peer access **negotiates** fine (`topo -p2p` OK / `EnablePeerAccess` rc=0
   / driver P2P caps look right).
2. Reads through the mapping return **all-1 (0xFF)**; writes are **silently
   dropped** (destination unchanged, verified on the *destination* side).
3. **Zero** Xid, **zero** AER delta across the whole path, no DMAR faults.

Point 3 is the trap: people conclude "not blocked, since no errors". With
ReqRedir, absence of errors is the *expected* signature, not a counter-proof.

And a fourth trap specific to our switch: on the PEX88096 downstream ports
in this box, `lspci -vvv` prints **no ACS lines at all** — the capability is
present in config space (at `0xf24`) but doesn't render. "lspci shows no ACS"
is a **false negative** on some hardware; only a raw extended-config walk is
authoritative. (Also: extended config reads need root. As non-root you get
`ffffffff` and conclude the cap is broken/absent.)

## Detection (5 minutes, read-only)

```bash
sudo ./scripts/acs-p2p-tool.sh audit        # walks ext caps, decodes bits for you
```

or by hand, if you know your switch ports' BDFs and cap offsets:

```bash
sudo setpci -s 02:08.0 0xf24+0x6.w   # 0x1d = SrcValid+ReqRedir+CmpltRedir+UpstreamFwd
```

or find the cap offset dynamically: walk the extended capability list from
`0x100`, each dword is `capID[15:0] : capVer[15:16] : nextOff[11:20-ish]`
(next offset = `(dword >> 20) & 0xffc`), until you hit ID `0x000D`.

## The fix

Clear the control word on **every switch downstream port on the GPU-to-GPU
path** (intermediate-level ports included; root ports are not in the P2P
path when both GPUs hang off the same root port — don't touch them unless
you know why):

```bash
sudo ./scripts/acs-p2p-tool.sh enable
```

Manual equivalent per port: `setpci -s <bdf> <cap>+0x6.w=0000`.

Decide consciously: you are disabling an *intended* isolation feature. On a
dedicated inference box that's fine; on a box hosting untrusted VMs it's not.
Rollback = write back the values you saved, or power-cycle the switch.

## Persistence — the non-obvious part

Switch config-space is **volatile**: a switch re-init (which can happen on
host warm reboot depending on the board's PERST behavior, or firmware
reload) restores factory ACSCtl. So the fix needs a re-assert loop. Ours:

- `scripts/systemd/acs-p2p-enable.service` — oneshot, runs the tool
- `scripts/systemd/acs-p2p-enable.timer` — `OnBootSec=15s`,
  `OnUnitActiveSec=60s`

Verified behavior on a real cold boot: nvidia.ko loads from initramfs at
08:35:07; the ACS service's **first tick** (08:35:15) flips all 7 ports
`001d -> 0000`; the **second tick, 60s later, writes nothing** (idempotent
no-op by design). No "wait for driver" condition is needed — udev-settle +
15s is enough, and adding a `ConditionPathExists=/proc/driver/nvidia/version`
style gate only adds a new failure point.

### THE TIMER NO-OP TRAP (this one bit us for days)

If the oneshot service has `RemainAfterExit=yes`, it stays `active` forever
after its first run. `systemctl start` on an *active* unit is a no-op — so
**the 60s re-assert never runs again**, while everything *looks* healthy:

- `systemctl list-timers` shows LAST ticking along ✅
- `systemctl is-active acs-p2p-enable.service` → active ✅
- `systemctl show acs-p2p-enable.service -p ExecMainStartTimestamp --value`
  → frozen at boot time ❌ ← **this is the only honest indicator**

Fix: `RemainAfterExit=no`, `daemon-reload`, restart the timer, and `stop`
the service once (it must leave `active` before the timer can start it
again). Acceptance test: read `ExecMainStartTimestamp`, wait 90s, read
again — it must have advanced. Our two "persistent" timers were silently
dead for days; if your switch ever reverts mid-run, nothing heals it.

## Proving it actually fixed something (physics check)

Peer-on bandwidth must **exceed the host-staging ceiling** of your machine.
Measure the ceiling first (`probes/probe_path`): a staged copy is D2H+H2D
serialized, so its max is ~min(H2D, D2H)/1 paths round-trip ≈ (H2D+D2H)/2
harmonic; on this box staging tops out at 12.55 GB/s and real peer-on runs
at 25–26. If your "fixed" P2P bandwidth is *below* your staging ceiling,
you're still staging. See docs/04.

## Where ACS is NOT your problem

- GPUs hang off root ports directly (`PHB`/`SYS` in `nvidia-smi topo -m`):
  no switch, no switch-ACS; P2P fate is decided by your root complex, and
  consumer RCs often just say no — different problem, no register fix.
- `NV#` in topo — you have NVLink, leave the forum, you lucky person.
- Server boards/HED with proper PCIe: ACS is usually absent or off by
  default; P2P generally works (that's why this failure mode is mostly a
  consumer + exotic-switch thing).
- If reads return all-**0** at line rate (not all-1): different signature —
  request *completed* against a zero page: your address is wrong, not
  blocked (see docs/04 aperture A/B table).
