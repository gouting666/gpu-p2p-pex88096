# Third-party lineage, credits, licenses

This repo documents a system **built from** several upstream projects. The
original contributions belong to their authors; what's here is ours only to
the extent noted in LICENSE.

## The driver stack

| Project | Role here | License |
|---|---|---|
| [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) | base of the 615.71.09 driver (kernel side; GSP firmware under NVIDIA's own terms) | kernel code MIT/GPL-2.0 dual; firmware NVIDIA license |
| [noon-at-cgn/3080-20g-p2p](https://github.com/noon-at-cgn/3080-20g-p2p) | the 615.71.09 build with consumer P2P/BAR1-path patches — **the driver we actually run** (built from `main`; our local additions were diagnostic probes only, not required for the final config) | MIT (per COPYING) |
| [aikitoria/open-gpu-kernel-modules](https://github.com/aikitoria/open-gpu-kernel-modules) (`-p2p` branches) | the 610-era P2P lineage; evaluated; 610.57.04-p2p failed to build against the 7.x kernel (dmem_cgroup API change, upstream PR pending at the time of writing) | NVIDIA open-kernel terms |
| [CachyOS-P2P-Nvidia](https://github.com/A1RM4X/CachyOS-P2P-Nvidia), [consumer-multigpu-inference](https://github.com/eduardopessin/consumer-multigpu-inference) | surveyed as prior art; both are CE/`cudaMemcpyPeer`-level | respective repos |
| gpu_unlock lineage (GFW/vBIOS unlock community; GA102 ports) | the initramfs early-unlock dkms module on this box descends from this work | check upstream before reuse |

## The card layer

| Project | Role |
|---|---|
| [3080-20gb-rebar](https://github.com/noon-at-cgn/3080-20gb-rebar) | documented the 0x610 FB_SIZE_OVERRIDE unlock for modded 3080-20G; our `nvbigbar-unlock.sh` is an independent idempotent re-implementation of the same knowledge | 
| Linux kernel `drivers/pci/{probe,setup-bus}.c` | our patch is derived from these files → **GPL-2.0** for the `kernel/` directory |

## Engines and tools

llama.cpp / ggml (peer-copy and NCCL integration), nccl-tests (the only
trustworthy way to certify an NCCL transport — use upstream
`all_reduce_perf`, not hand-rolled collectives), NVIDIA CUDA driver API for
the VMM probes.

## The idea that mattered

Checking switch-port ACS as a **first-class step** in "why doesn't my PCIe
P2P work" is standard knowledge in the VFIO/eGPU community. Our entire six-
day detour was possible because the multi-GPU-inference corner of the world
doesn't cross-read that community's war stories, and because the failure
mode of ReqRedir is engineered (by spec, not malice) to be invisible. If
this repo does one thing, let it be moving that sentence one row up in the
other community's checklist.

## A note on the modded hardware

"3080-20G" boards are a Chinese-market VRAM mod of GA102 hardware; they're
unsupported by NVIDIA in that configuration and their vBIOS caps (ReBAR
table, device strapping) are mods-on-mods. Nothing in this repo flashes,
rewrites, or persists anything to card firmware — every card-side change
documented here is volatile config-space poking, recoverable by power
cycle. Whether used hardware like this should exist is a different forum;
we took it as the constraint and worked within it.
