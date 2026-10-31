# The story: six days, sixteen rounds, three false dawns

Why a "simple P2P question" turned into a driver-archaeology expedition, and
how the last 10% — the part that mattered — was a single register.

## Day 0 (2026-10-26): the motivation

Host: Colorful Z690M (consumer board), i9-14900K, three GA10x GPUs behind an
external PEX88096 PCIe switch — one stock 3090 (24G) and two **modded RTX
3080-20G** (a China-market mod: more VRAM than NVIDIA's binning allowed).
Total 64G VRAM, running llama.cpp tensor-split inference on a 100B-class MoE
GGUF.

Known problems on this class of box:

- Modded 3080s come with a vBIOS that **caps the ReBAR size table at 256M**.
  Without a big BAR1, cross-GPU buffer access means host staging everywhere.
- Consumer root complexes don't do peer routing between ports. That's what
  the PEX switch is supposed to solve.
- Stock NVIDIA open modules don't enable consumer multi-GPU P2P. That's what
  the community fork (see THIRD_PARTY.md) is for.

Survey of upstream projects (aikitoria fork, 3080-20g-p2p, CachyOS-P2P-Nvidia,
consumer-multigpu-inference...) — all of them demonstrate only
`cudaMemcpyPeer`-class P2P at ~10 GB/s, none demonstrate SM-level loads
across cards. Community consensus: "consumer card mailbox routing is fused
off, BAR1 routing is stubbed in the stock driver". Fine. Target set: get
3×32G BAR1 + whatever P2P the patched 615 driver can give.

## Days 1-2 (10-28): the ReBAR wall — three walls, actually

**Wall 1: enumeration ordering.** The kernel assigns BAR resources during
PCI enumeration, which finishes before any initramfs userspace hook runs
(0.29s vs 0.83s). Userspace can't ask for a 32G BAR1 on ReBAR-capped cards —
the resource is already allocated at 256M and `resource1_resize` refuses to
grow it into spaces siblings already occupy ("can't assign; no space").
Answer: **patch the kernel** to widen the vendor size table (GA10x reg 0x610)
inside enumeration before `pci_read_bases()`, and let `pci=realloc` re-pack
the bridge windows.

That sounds simple. It wasn't: kernel 7.0.x has a bridge-window sizing bug
where sibling windows behind multi-level switches leave alignment gaps
(`size += max(r_size, align)` doesn't account for the round-up between
siblings). Nine patch revisions. One patch revision blew its own sizing
requirement from 96G to 160G (never inflate by `big_align*(n-1)` — every
level re-adds a chunk). Two attempts ended with the `pci=realloc` retry loop
failing to the bottom and the kernel releasing **every BAR on the chain**,
all three GPUs at `BAR 0M @ 0x0`, `nvidia: probe failed`, machine headless
until cold power-cycle. (The screen lives on the iGPU, so it survived; that
was luck by design — check `display_active` before any of this.)

**Wall 2: the driver shrinks BAR back.** After the kernel finally assigned
32G, the NVIDIA driver's own `nv_resize_pcie_bars()` re-read the ReBAR table
*after a GPU reset* (the vendor unlock is volatile — reset snaps it back to
factory), saw max=256M, and released the kernel's 32G, re-assigning 256M.
Log tell: the device prefix in the resize message changes from `pci 0000:...`
to `nvidia 0000:...` — it's not the allocator failing, it's the driver
undoing it. Fix: keep the vendor table re-widened at runtime (a 60s re-assert
timer writes 0x610 + ReBAR ctrl), and let kernel assignment stand.

**Wall 3: who owns early boot.** nvidia.ko loads *from the initramfs* on this
box (firmware + conf baked in), so any userspace arm-script runs long after
the driver bound. Required a custom dracut module hooking `pre-udev` — and
learning that dracut's own `force_drivers`/`rd.driver.pre` drop-ins silently
do nothing in pre-udev (they're read from the real kernel cmdline, which
isn't available at that stage). Also: unlock modules must run in
`module_init` before anything binds the device; running them later returns
`-EBUSY` and prints "unlock failed (-16)" — which is about *ordering*, not
your module being broken.

End of phase: **3× BAR1 = 32G**, persistent across cold boots, gated behind
a two-key boot arming scheme (GRUB token + ESP marker file), rollback =
delete marker + cold power-cycle. Nothing written to vBIOS/flash anywhere:
everything volatile = everything recoverable by unplug.

## Days 3-5 (10-29/30): the mapping labyrinth — and the first false dawn

With BAR1s in place, the question became: which initiator can actually touch
peer memory?

Early "victories" (false dawn #1): boot reports declaring **`cudaMemcpyPeer`
6/6 pairs byte-exact at 10.8 GB/s**, shipped as a periodic boot-verify
service. Looked great for a day and a half.

Meanwhile kernel-level (SM) access kept failing in a *specific* way:
`cudaDeviceEnablePeerAccess` returns 0 on all pairs, topo says OK — but SM
reads of peer return all-`0xFF`, SM writes vanish silently, zero Xid, zero
AER delta on the whole path. Rounds 4→12 attacked exactly that: static BAR1
(`RMForceStaticBar1`), the driver's global DMA-window gate (`bar1Dma sz=0`
when static BAR1 is off — fail-closed), dynamic Method3 windows (budget
math: `(N-1) × share ≤ BAR1 − reserve`, which three 32G cards can't satisfy),
VMM/IPC exported allocations, forced PEER aperture, and finally a driver
patch encoding peer-aperture PTEs *correctly* (peerIdx + FB offset, verified
bit-for-bit against the stock encoder's output for BAR1-path). Result:
encoding correct, data still doesn't come back. Round 15 registered a
pre-planned rule — `bar1path=1` with stock-shaped PTEs means the encoder is
innocent — and the conclusion became "hardware wall, SM path is fused".

One detour in those rounds deserves a warning label: hand-rolled peer PTEs
with local FB offsets interpreted as host-physical addresses made the GPU
write **into system RAM**. The probe's 8 MiB pattern was still sitting in
DRAM after a warm reboot. If you're reading PTEs from a driver probe and
decoding addresses by hand: decode *all* of them (peer aperture address
fields are **not** contiguous like SYS aperture — different formats), and
never, ever let a write probe proceed without asserting the decoded phys
address is ≥ the MMIO hole.

## Evening of day 5 (10-30, 22:05): false dawn #1 exposed — and #2 erected

A fresh falsification probe (`probe_path`: D2H/H2D pinned, host round-trip,
peer-off, peer-on, same buffers same sizes) revealed the truth about the
10.8 GB/s:

```
D2H pinned             25.82 GB/s
H2D pinned             24.04 GB/s
host round-trip        12.55 GB/s   ← ceiling for any host-staged "P2P"
cudaMemcpyPeer off     10.75 GB/s   ← 0.86 × ceiling: IT'S STAGING
cudaDeviceEnablePeerAccess → 0 (ok)
cudaMemcpyPeer on       1.02 GB/s   ← the real fabric attempt. Fails.
```

So the "P2P 6/6 byte-exact PASS" boot certificates were proving only that
**CPU memory forwarding** works — CUDA's documented fallback when peer
access isn't enabled. Ground truth with `copy_hold` + CPU scans through
`resource1`: after peer-on copy, the source card's framebuffer has the
pattern, the destination card's has... nothing. The bytes never landed
anywhere.

At this point a *second* conclusion was reached and written down (false
dawn #2, of a kind): "GPU→peer-BAR1 intrinsic TLP routing is dead; it's the
switch's ingress/egress decoding; out of driver-side options." This was
wrong in a way we couldn't see: it was *also* silent, *also* looked final.

## Morning of day 6 (10-31, 08:00): round 16 — the register

A simple accusation from the outside: "VFIO people check ACS as step one.
Did you read the switch ports' ACSCtl?" Honest answer: the probe suite had
grepped everything — bridges, windows, AER, PTEs, even per-bit decode of
driver page tables — but **never once read the ACS control register**,
because `lspci -vvv` on these particular Broadcom DSPs doesn't print an
ACSCtl line at all, and "no ACS visible + no ACSViol + zero AER" had been
filed under "ruled out" by round 4.

Raw extended config reads found it instantly: all 7 downstream ports of the
PEX88096 shipped ACSCtl = **0x1d** — SrcValid + ReqRedir + CmpltRedir +
UpstreamFwd. Every GPU-to-GPU request TLP was *compliantly redirected*
upstream toward the root complex, where consumer platforms kill it.
Redirection is forwarding, not blocking — that's why it sets no error bits
anywhere. The symptoms we'd been chasing for six days — all-1 reads (UR
completions), dropped writes, zero Xid, zero AER — were exactly, precisely
the signature of ACS redirection.

`setpci -s <DSP> 0xf24+0x6.w=0000` × 7 ports. Retest the whole suite, first
time ever with ACS actually clear:

- peer-on 6/6 pairs: **25.5–25.7 GB/s byte-exact** (was 1.02 + destroyed)
- SM read peer: 12.6 GB/s, content matches (was all-1)
- SM write peer: 17.7 GB/s, verified on the owner side (was silently dropped)
- CE through VMM peer VA: 25.7/26.2 GB/s verified (was mismatch)
- NCCL with **default config**: `P2P/direct pointer`, passes, Xid=0 (was:
  hang at first collective, requiring `NCCL_P2P_DISABLE=1`)

Nothing above needed a driver reboot, a kernel rebuild, or a GPU reset.
Ten rounds of "hardware wall" were a firmware default.

## Same morning: persistence, and the timer that wasn't

Two 60s re-assert timers existed (one for the switch ACS, one for the
modded-card ReBAR decode). Both units were oneshot with
`RemainAfterExit=yes`. Which means: after the first run they stayed
`active`, and a systemd timer starting an active unit is a **no-op**. The
timer shows `LastTrigger` ticking; `list-timers` shows `LAST` populated;
the script underneath never re-ran — not once since boot. Fix:
`RemainAfterExit=no`, daemon-reload, restart timer, and manually `stop` the
service once so it can leave active state. Verified by watching
`ExecMainStartTimestamp` advance every 60s. Without this, a switch reset
hours later silently un-fixes P2P with nothing healing it.

Cold boot with the full stack (custom kernel + initramfs unlock + timers +
driver + re-asserted ACS): all green, 15 seconds to "P2P is real" in the
boot report, production llama-server ready in ~30s.

## The payoff, measured honestly (same-day A/B, one variable)

Production inference (llama.cpp b1024, 3-GPU tensor split + NCCL), A/B with
the pair of `NCCL_P2P_*DISABLE` env vars as the only difference, alternating
runs, same binary, same day:

- decode mean: 111.3 → **118.3 t/s (+6.3%)**
- 8.4K-token prefill: 1328 → **1498 t/s (+12.8%)**

The prefill-vs-decode split matches theory: P2P pays where bulk transfers
and sync tax live; batch=1 decode on 3 cards was never link-bound and won't
transform. But "hardware P2P that pays double digits on long prompts" on a
consumer desktop, for the price of one register and a timer, is worth more
than the two weeks of detour that produced it. (The detour did produce the
verification discipline of docs/04, which is arguably the reusable part.)

## What actually cost the six days

Not difficulty — **plausible readings**. Every wrong turn was backed by real
data: a bandwidth number, a rc=0, a byte-exact check, an AER zero-delta, a
stock-shaped PTE. What was missing was never effort; it was one line in a
checklist that other communities learned a decade ago, and a rule we now
write everywhere we can: *every number has a failure mode that would also
produce it; name it, or don't believe it.*
