# Dead ends (measured, so you don't pay for them again)

Each item: claim → test → verdict. All post-ACS-clear re-tests are labeled;
anything not re-tested after the fix is marked ⚠️ and should be considered
"measured under redirection", not "false".

## Structural dead ends (true regardless of ACS)

**CE as a TP collective engine.** `cudaMemcpyPeerAsync`-based all-reduce
rings vs NCCL SHM at 3 sizes: loses at every size; and `cudaMemcpyPeerAsync`
**cannot be captured into a CUDA graph** (capture fails), so there's no
"structural win" waiting either. Verdict: dead, no re-test.

**Dynamic BAR1 windows (Method3) for ≥3 cards.** Budget rule: a source card
accumulates all its peer windows (`dynBar1MappedBytes`), cap =
`BAR1 − reserve(64M)`. Three 32G cards each needing two peers at ≥17.25G
resident ⇒ needs ~34.5G of 31.9G window. Physically short, not a counting
error. And when windows fail, allocations silently fall back to mailbox
with wrong-size copies — a data-integrity risk, not just perf. Dead for
3×32G; single-peer pairs only.

**Hand-rolled peer PTEs.** Peer aperture uses a **two-part** address
encoding (`ADDRESS_VID[32:8]` + `COMPTAGLINE[55:36]`); the kernel's own
field setter fills only the first part — PTEs for BAR1 > 128G ranges get
silently truncated (symptom: line-rate, all-zero). And decoding by hand
across aperture types with the wrong formula turns healthy values into
"evidence". The one time we wrote based on hand-decoded PTEs, the GPU wrote
8 MiB into **system RAM** (`/proc/iomem` says System RAM; pattern survived
warm reboot; kernel Oops + bystander heap corruption on the way). If you
insist on writing: assert decoded phys ≥ MMIO hole before the write. We
closed this line with a rule: correct addresses come only from the driver's
own encoder, never from a reconstruction.

**Manual bridge-window surgery via `setpci`.** Registers latch fine and
mean nothing: `rescan` recomputes windows from child requests and
overwrites them. Worse, one wrong offset (prefetch window is *only* at
0x24/0x26/0x28/0x2C — 0x1C/0x1E is I/O) can desync the whole subtree's
resource accounting → endpoint loses even BAR0, `NVRM: This PCI I/O region
assigned to your device is invalid`, no keyboard, cold power-cycle only.
Verdict: never write bridge windows from userspace on a running system.

**Userspace libcuda patching.** The upstream `patch-libcuda-p2p.py` flips
a *device-family* gate (mixed-generation pairs like 3090+4090). Same-gen
multi-GPU pairs already report `CanAccessPeer=1`; our failures were mapping
errors (205 / all-1), which this patch cannot touch. Signature-checking a
copy of libcuda confirmed: matched 0 times on our version — wrong target,
not a predicate problem. Don't patch a 100 MB binary for a gate that isn't
shutting you.

**Registry tri-state "delete to disable".** `RMForceStaticBar1` absent =
AUTO, and AUTO's condition is always true on 32G-BAR1 machines — deleting
the key and rebuilding changed nothing (release drivers compile the INFO
logline out, so silence ≠ failure and absence ≠ off). Write `=0`
explicitly if you want off.

## ⚠️ Measured under redirection — retest before citing

- **`NCCL_P2P_USE_CUDA_MEMCPY`** and variants: first-collective hang or OOB
  check failure.
- **Forced PEER aperture (ap=2) with peerIdx rotation**: all-zero at line
  rate or Xid31 `FAULT_UNSUPPORTED_APERTURE`; PTE-offset sweeping found
  patterns only in the owner's own window. Post-fix the stock VMM path
  works, so this exotic route is moot, not vindicated.
- **"SM cross-card access is fused off on consumer cards"** (the community
  consensus we inherited): ⚠️ at minimum it's **switch-ACS-gated** —
  our SM path went from impossible to 17.7 GB/s writes with one register.
  Retest your platform's "fused" folklore with ACS cleared first.

## Open threads (real work, not hardware)

- **llama.cpp internal allreduce is 2-GPU-only** (`n_devices != 2` gate,
  3+ cards fall back to butterfly). Extending it is a code patch, not a
  bus mystery.
- **vLLM-style multi-process per-buffer P2P grants** — now possible in
  principle (docs/05 capability list); nobody has measured it here yet.
- **NCCL direct-pointer latency isolation** and protocol tuning under the
  new regime — the old SHM-era tuning numbers are stale.
