# Real GPU-to-GPU P2P on a consumer desktop — PEX88096 switch, 3× GA10x, one wrong firmware register

**TL;DR:** If your PCIe GPU P2P "fails silently" — reads return all-1, writes
vanish, `nvidia-smi topo -m` says OK, `EnablePeerAccess` returns success, AER
and Xid stay at zero — and you sit behind a PCIe **switch**, check the ACS
registers on the switch's downstream ports *before* you spend two weeks
patching drivers. On this machine, sixteen rounds of kernel/driver surgery
ended in **one 16-bit register per switch port**, factory-shipped as `0x1d`,
which was *compliantly* redirecting every GPU-to-GPU TLP back to the root
complex to die. Clearing it took one `setpci` command. Everything else —
32G ReBAR on modded 3080s, static BAR1, patched drivers — was real but was
never the wall.

## What "real" means here (and what we proved)

Machine: Colorful Z690M + i9-14900K, external Broadcom/PLX **PEX88096** PCIe
switch, three GPUs behind it: 1× RTX 3090 + 2× modded RTX 3080-20G. Kernel
7.0.14 (custom-built), NVIDIA open kernel modules 615.71.09.

| Test | Before ACS clear | After ACS clear |
|---|---|---|
| `cudaMemcpyPeer` peer-**off** | ~10.5 GB/s *(host staging — was long mistaken for P2P)* | ~10.5 GB/s (same, it's staging) |
| `cudaMemcpyPeer` peer-**on**, all 6 pairs, byte-exact | **1.02 GB/s, data destroyed** | **25.5–25.7 GB/s, 6/6 byte-exact** |
| SM (kernel) direct read of peer VRAM | all-`0xFF` (UR) | **~12 GB/s, content verified** |
| SM direct write to peer VRAM | silently dropped | **17.7 GB/s, owner-side verified** |
| CE via VMM-mapped peer VA | mismatch | **26.2 / 25.7 GB/s verified** |
| NCCL default transport | hangs at first collective | **`P2P/direct pointer`, works, Xid=0** |
| llama.cpp 3-GPU decode (same-day A/B) | baseline | **+6.3%** |
| llama.cpp 8.4K prefill | baseline | **+12.8%** |

Physical proof it isn't staging: the host round-trip ceiling on this box is
12.55 GB/s (measured D2H/H2D pinned). Peer-on runs at 25–26 GB/s — you can't
stage faster than the staging path's own limit.

## Which parts apply to you

| Your situation | What you need from this repo |
|---|---|
| Consumer/HED board + PCIe switch, P2P broken | `scripts/acs-p2p-tool.sh` + `docs/02-acs-silent-killer.md`. That's it, that's the treasure. |
| Modded 3080-20G (or other ReBAR-capped cards) | `kernel/` patch + `scripts/nvbigbar-unlock.sh` (the card layers, docs/03) |
| Multi-GPU on stock driver, want BAR1 P2P | Upstream driver lineage in `THIRD_PARTY.md` (3080-20g-p2p / 615 stack) + registry keys in docs/03 |
| You just want to know if YOUR "P2P works" claim is real | `probes/` + `docs/04-verification-playbook.md`. Our machine shipped a false-positive "P2P 6/6 PASS" boot report for a week. |
| Same platform, want the exact working config | `docs/03-full-stack.md` — five layers, every file |

## Repo map

```
scripts/acs-p2p-tool.sh    audit / enable switch-port ACS (auto-discovers
                           GPU paths, walks extended config caps — no hardcoded BDFs)
scripts/systemd/           oneshot + 60s re-assert timers (with the
                           RemainAfterExit no-op trap fixed inline)
scripts/nvbigbar-unlock.sh modded-GA10x ReBAR re-widen, idempotent
scripts/boot-verify.sh     one-shot whole-stack acceptance, dynamic discovery
kernel/                    Linux 7.0.14 patch: early ReBAR unlock + aligned
                           bridge-window sizing (cmdline-gated, default off)
probes/                    the verification suite: host-bounce falsifier,
                           6-pair peer-on byte-exact matrix, SM/CE initiator
                           probes, BAR1 ground-truth scanner
docs/                      story, ACS deep-dive, full stack, verification
                           playbook, results, dead ends
```

Quickstart for the ACS fix:

```bash
sudo ./scripts/acs-p2p-tool.sh audit    # read-only; look for ReqRedir/CmpltRedir/UpstreamFwd
sudo ./scripts/acs-p2p-tool.sh enable   # clears control words between your GPUs
```

Then prove it with `probes/`: peer-**on** must beat the host-staging ceiling
**and** match bytes. Peer-off numbers are not evidence — that's the trap that
ate ten rounds of debugging here (see docs/04).

## Honesty clauses

- batch=1 decode is *not* link-bound; most of the +6.3% comes from sync tax,
  and prefill/big-batch is where P2P actually pays. Don't expect miracles on
  single-stream decode from "hardware P2P" alone (docs/05).
- The card layers (custom kernel, 0x610 unlock) are for **modded 3080-20G
  boards** specifically. Stock cards don't need them and the vendor-register
  math is GA10x-specific.
- Switch ACS values are volatile — the timer units exist because firmware
  reloads revert them.
- Everything here was done on **one** machine. The ACS lesson is universal;
  the kernel patch and registry keys are best-effort documentation of what
  worked here, not a drop-in product.
- Some paths are **actively dangerous**: hand-rolling peer PTEs can make your
  kernel write GPU framebuffer offsets into *system RAM* (it did here; the
  bytes were still there after reboot). Read docs/06 before improvising.

## Docs

1. [The story](docs/01-story.md) — six days, 16 rounds, 3 false dawns
2. [ACS ReqRedir, the silent killer](docs/02-acs-silent-killer.md)
3. [The full stack, layer by layer](docs/03-full-stack.md)
4. [Verification playbook](docs/04-verification-playbook.md)
5. [Results & benchmarks](docs/05-results.md)
6. [Dead ends, so you don't repeat them](docs/06-dead-ends.md)

License: MIT (our scripts/docs); `kernel/` is derived from Linux and stays
GPL-2.0. Third-party lineage and credits: [THIRD_PARTY.md](THIRD_PARTY.md).

---

## 中文摘要

消费级主板 + PEX88096 交换机后的多卡 P2P「静默失败」，真凶往往是交换机固件
出厂写入的 **ACS Control = 0x1d**（ReqRedir/CmpltRedir/UpstreamFwd）：它按规范
把 GPU 之间的 P2P TLP 重定向回根复合体处死，**且不置任何错误位**——没有
ACSViol、没有 BlockedTLP、没有 Xid，`lspci -vvv` 在这类 Broadcom DSP 上甚至
不打印 ACSCtl 行。本机为此白烧了十轮驱动源码级排查；真正的修复是每个交换机
端口一条 `setpci` 写零。清零后：六对拷贝 25.6 GB/s 逐字节精确（此前 peer-on
是 1.02 GB/s + 数据销毁）、SM 直访对端显存成立、NCCL 默认 direct-pointer
跑通、生产推理 prefill +12.8%。

另外三件事值得带走：① `cudaMemcpyPeer` 不开 peer access 时的 ~10.8 GB/s
是**主机中转**（本机中转上限实测 12.55），拿它当 P2P 证据的验收报告我们都
写过；② 「AER 零增量 + 无 Xid」不能证明 ACS 没挡路，重定向是合规动作；
③ systemd timer 重申 volatile 寄存器时，oneshot 服务带 `RemainAfterExit=yes`
会让重申永远空转。详见 docs/，欢迎提 issue 补充你踩到的平台差异。
