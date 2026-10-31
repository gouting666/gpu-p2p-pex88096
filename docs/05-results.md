> **本项目P2P实现由AI攻克，github代码AI编写上传，本人非专业代码人员，仅供参考。**
>
> *The P2P implementation in this project was worked out by AI; the code was written
> and uploaded by AI. The author is not a professional developer — for reference only.*

# Results & benchmarks

All measurements on one machine: Z690M + i9-14900K, PEX88096 switch,
3090 + 2×modded 3080-20G, custom kernel 7.0.14-38-rebar, NVIDIA open
modules 615.71.09, CUDA 13.2. "ACS cleared" = switch-port ACSCtl written 0
per docs/02; before that state, ACS was factory `0x1d` on all 7 DSPs.

## Fabric, before vs after ACS clear

Peer-off/on labels refer to CUDA peer access being enabled. Staging
ceiling (host round-trip, pinned): **12.55 GB/s** (D2H 25.8, H2D 24.0).

| Metric | Before | After |
|---|---|---|
| `cudaMemcpyPeer` peer-off (per pair, 6 pairs) | 10.39–10.75 GB/s — **staging** | ~10.5 GB/s (same; staging doesn't care) |
| `cudaMemcpyPeer` peer-on (6 pairs, 8 MiB, byte-exact) | 1.02 GB/s, destination content destroyed | **25.55–25.69 GB/s, 6/6 byte-exact** |
| SM kernel read of peer VRAM (VMM-mapped) | all-1 (UR) | **12.6 GB/s**, content verified |
| SM kernel write to peer VRAM | silently dropped | **17.7 GB/s**, verified on owner side |
| CE through peer VA (read/write) | sum mismatch / 1.02 dropped | **25.72 / 26.19 GB/s** verified |
| Third-card CE through mapped VA | dropped | verified |
| `cudaDeviceEnablePeerAccess` 0→1 | rc=0 (was 4 pairs rc=205 in older configs) | rc=0 |
| NCCL default transport | hang at first collective | **`P2P/direct pointer`**, completes, Xid=0 |
| NCCL with `NCCL_P2P_DIRECT_DISABLE=1` (CUMEM) | hang after ring setup | not re-tested post-fix |
| NCCL `NCCL_P2P_DISABLE=1` (SHM) | works, ~4.78 GB/s busbw (1M–256M) | works (this was production) |

Physical anti-staging argument: peer-on numbers exceed the 12.55 GB/s host
round-trip ceiling, so they cannot be staged; 25.6 ≈ the expected x16
Gen4-ish line rate through the switch, and writes are visible on the
destination owner.

## Production end-to-end A/B (llama.cpp b1024, tensor-split 3-GPU + NCCL)

Same-day alternating runs, same binary and unit, **single variable**: the
two env vars `NCCL_P2P_DISABLE=1` + `NCCL_P2P_DIRECT_DISABLE=1`
(A = set = SHM regime, B = unset = direct P2P regime). 4× decode rounds
(4 tasks, greedy, 400 tokens) + 3× long-prompt prefill each:

| Metric | A: SHM | B: P2P | Δ |
|---|---|---|---|
| decode mean (t/s) | 111.3 (110.2/111.4/112.0/111.7) | **118.3** (115.9/119.5/119.2/118.7) | **+6.3%** |
| short-prompt pp (t/s) | 115.1 | 115.0 | ≈0 |
| 8.4K-token prefill (t/s) | 1327.9 | **1497.9** | **+12.8%** |
| spec-decode accept rate | 0.595 | 0.596 | ≈0 |

Within-arm spread (1.8 / 3.6 t/s) is far below the deltas; accept-rate
invariance is a good sanity signal (no behavior change, just speed).

## What this kind of P2P does and does not buy

- **Does not** transform batch=1 decode: at ~1.1 GB/token read per step on
  this 3-card config, VRAM bandwidth utilization is <5%; the bottleneck is
  synchronization control plane, not the link. The +6.3% is sync-tax
  removal, not bandwidth.
- **Does** pay on bulk-transfer regimes: prefill, large batch, and
  hierarchical-offload paths where avoiding the host round-trip doubles
  effective path width. The prefill result (+12.8% at 8.4K) is the
  expected shape.
- **Does** unlock capabilities that simply weren't there: NCCL direct
  transport, SM-level peer access, CUDA IPC/VMM sharing across processes
  (vLLM-style multi-process P2P grants), which were structurally impossible
  pre-fix regardless of tuning.
- Multi-GPU tensor-split **model loading** is unaffected by P2P — don't
  expect it to.

## Latency notes

- Small-message NCCL floor on 3 cards via SHM was measured at ~14 µs;
  direct-pointer regime wasn't isolated for latency numbers beyond the
  end-to-end A/B above.
- Boot-to-P2P-ready time with the full stack: ~15 s (boot self-check
  prints its fabric report), driver+initrd included.
