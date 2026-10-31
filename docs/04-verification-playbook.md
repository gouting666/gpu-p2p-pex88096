> **本项目P2P实现由AI攻克，github代码AI编写上传，本人非专业代码人员，仅供参考。**
>
> *The P2P implementation in this project was worked out by AI; the code was written
> and uploaded by AI. The author is not a professional developer — for reference only.*

# Verification playbook: believe a number only after naming its fake

Every rule below exists because we were fooled by its absence. This is the
part of the repo most worth reading even if you never touch our stack.

## R1. Name the initiator, in every claim

Four things can touch peer memory and they have **different** failure modes
and different gates:

| Initiator | Path | Consumers |
|---|---|---|
| CE without peer access | host staging (D2H+H2D) | fallback of `cudaMemcpyPeer` |
| CE with peer access | explicit peer mapping | `cudaMemcpyPeerAsync` post-enable |
| SM (kernels) | peer PTEs (`EnablePeerAccess`) / managed / VMM | NCCL direct-pointer, IPC |
| CPU | `mmap /sys/bus/pci/devices/*/resource1` | your debug tools |

"P2P works" is meaningless without the layer. Our final config has CE-good
and SM-good, but they were fixed and broken *independently* for five days.

## R2. Measure your staging ceiling first; peer-off is never evidence

A staged copy crosses the host twice: ceiling ≈ half of your pinned
round-trip. On this box: D2H 25.8 / H2D 24.0 / round-trip **12.55** GB/s —
and "P2P" ran at 10.75, i.e. **0.86 of the staging ceiling**, which is
exactly where staging lives. Real peer-on ran at 2× that (25–26).

Rule: any "P2P bandwidth" **below** your staging ceiling is presumed
staging until peer-**on** byte-exact results say otherwise. Use
`cudaHostAlloc` buffers for ceiling measurements; pageable copies distort.
(`probes/probe_path` does this whole calibration in one run.)

## R3. Byte-exact checks have their own failure modes

- **Different pattern per endpoint, and refill the source per pair.** If
  both sides are memset to the same value before copying, "destination ==
  expected" passes whether or not the copy happened (our boot self-check
  shipped exactly this bug). And in a pairwise loop, source *i* has already
  been overwritten by pair *i−1*'s destination content — refill before each
  pair or you'll get a stable "first N pass, rest fail" that looks like
  hardware regression. Fix: `cudaMemset(src, pattern[src])` immediately
  before each timed copy.
- **BAR1 bigger than VRAM (32G BAR on 24G/20G cards) means high addresses
  aren't backed** — "copy succeeded + bandwidth beautiful + data wrong" is
  a legal combination. Content checks are mandatory, bandwidth is not.
- **Verify writes on the destination owner's side.** A write "read-back"
  through the same broken mapping returns whatever the broken mapping
  returns. Owner self-read (or CPU `resource1` scan) is the only verdict.

## R4. Negotiation signals are noise

`topo -p2p` OK, `EnablePeerAccess` rc=0, driver caps `can=1`, NCCL log
`directMode 1` — all mean *the paperwork is filed*, not that bytes move.
We held all of them simultaneously with all-1 reads and dropped writes for
days. Acceptance = data content. Only.

## R5. Read-back values are a diagnostic alphabet

| Symptom | Meaning |
|---|---|
| all-`0xFF` | UR completion — request died somewhere (ACS redirect lives here) |
| all-`0x00` at line rate | request **completed** against a zero page — your address is wrong, not blocked |
| stale pattern (e.g. last thing you wrote) | address stable but wrong; smells like success, is the most dangerous one |
| mismatch at random | real corruption |

Stale-pattern corollary: if a "write to peer" leaves the destination
looking like what *you* wrote earlier, have the **owner card itself** read
its buffer. Owner sees original ⇒ your write went to a *different* place.
This is how we discovered hand-rolled peer PTEs were writing into **system
RAM** (the pattern was still in DRAM after a warm reboot — decode PTE
addresses with a script, never by eye; peer-aperture address fields are
*not* contiguous the way SYS-aperture ones are: `ADDRESS_VID[32:8]` +
`COMPTAGLINE[55:36]` two-part encoding).

CPU ground truth (`probes/scan_bar1_fast`): after a copy, scan the
*destination* card's BAR1 window from the CPU (sampled, e.g. 64K every 4M —
full-window byte scan of 32G takes forever) for the pattern. Source found +
dest missing ⇒ the bytes landed nowhere; stop looking for a wrong address.
Keep the buffers alive while scanning (probe process must not exit) or
you'll read zeros and blame the fabric for garbage collection.

## R6. Error telemetry caveats

- **Check `pci=noaer` on the kernel cmdline before trusting "zero AER".**
  We had AER disabled wholesale; every "AER showed nothing" conclusion
  drawn from that machine was drawn on a disabled instrument. If noaer is
  set: save each port's `CAP_EXP+0x08.W`, OR in `0x000F` (enable error
  reporting bits), clear `ECAP_AER+0x04/+0x10` status, trigger the failing
  access, dump, restore originals via EXIT trap. Only a post-restore zero
  latch counts as evidence.
- **Zero Xid is normal under redirection.** The GPU did nothing wrong; the
  fabric never delivered anything to it.
- Per-boot Xid count is still a good invariant: `journalctl -k -b -N |
  grep -c Xid` between successive boots — a probe that prints beautiful
  fields while raising `Xid 31 FAULT_PDE` is a regression, not progress.
- `lspci -vvv` may not render ACS on your switch at all; raw ext-config
  reads are the only authoritative source (and they need root; non-root
  `ffffffff` means "you can't look", not "it's all ones").

## R7. Self-healing loops must show their pulses

For anything that re-asserts volatile state: acceptance is the **timestamp
advancing**, not the unit being enabled/active (docs/02's RemainAfterExit
trap). Bake it into your boot verify: read `ExecMainStartTimestamp`, wait
one period+, read again.

## R8. Boot reports: freshness and scope

- Report file `mtime` must be **later than this boot** (`uptime -s`);
  reading yesterday's green report today is how you certify a dead stack.
- Never hardcode device/BDF lists in a verifier — enumerate dynamically;
  after a bus re-scan, BDFs move and hardcoded checks silently test nothing.
- dmesg is a ring buffer: snapshot it (`dmesg > file`) at probe time;
  tail-line arithmetic across a wrap gives empty windows that look like
  "no events".

## R9. Copy size selects the engine

Small `cudaMemcpyPeer` with peer access enabled runs as an **SM copy
kernel**, large ones run on the CE. The same pair can fail at 4K (SM path
dead) and pass at 256M (CE alive) — neither result generalizes. Know which
size class your workload uses before extrapolating.

## R10. Probe hygiene (people will run these)

- Hand-rolled probes generally don't parse args; `--help` **executes the
  real thing**. Read the source before running unfamiliar binaries.
- A probe whose write addresses aren't constrained can make your kernel
  Oops. Our multi-card "paint then write" sweep wrote 8 MiB of pattern into
  system RAM (`Oops: Bad pagetable` on the probe's stack, heap corruption
  in a bystander process minutes later, then a reboot). Gate any peer-VA
  write behind: decoded phys addr ≥ the MMIO hole, else abort.
- `pkill -x name`, never `pkill -f pattern` — the `-f` pattern matches the
  shell running your own command line.

## R11. "Which config booted" is a question, not a feeling

Verify the running image with `uname -a` build # and time vs the tree's
`bzImage` mtime, cmdline tokens (match distinctive tokens, not substrings —
`pci=realloc,noaer` doesn't contain `pci=realloc`), and module **md5** —
not `srcversion`: two content-different builds can share a srcversion.
Conf-on-disk newer than boot time ⇒ you're running the *previous* config;
say so before anyone celebrates or rolls back.
