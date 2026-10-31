> **本项目P2P实现由AI攻克，github代码AI编写上传，本人非专业代码人员，仅供参考。**
>
> *The P2P implementation in this project was worked out by AI; the code was written
> and uploaded by AI. The author is not a professional developer — for reference only.*

# The full stack: five layers, every file, what to change

This is the "which files, what for" answer. Each layer lists purpose →
files → acceptance → failure modes. Layers are independent where marked;
take what applies to your platform.

> **Operating rule that made this survivable:** every boot-level change was
> (1) evaluated read-only first and written down before touched, (2) armed
> behind a **dual gate** — a GRUB one-shot test entry *and* a marker file on
> the ESP, so a mis-patched kernel can't boot by accident — (3) paired with
> a tested rollback, and (4) nothing was ever flashed (vBIOS untouched), so
> cold power-cycle always returns to factory. Check that your display is on
> the iGPU (`nvidia-smi --query-gpu=display_active`) before any GPU
> bus surgery: ours was, so a dead GPU chain meant "recover over SSH", not
> "open the case".

## Layer 0 — BIOS / platform (applies to everyone)

- **Above-4G decoding: ON.** Without it there is no address space above 4G to
  put a 32G BAR1 in. Some boards hide this behind "ReBAR Support".
- **ReBAR / Resizable BAR: ON** (for stock cards this alone is often
  enough; modded cards see Layer 2+3).
- MMIO High base/size, if your BIOS exposes it: the *sum* of all BAR1s must
  fit in the 64-bit MMIO hole the firmware carves out. Ours: a 256 GiB
  above-4G aperture, fragmented by iGPU VF BARs and a NIC prefetch window —
  3×32G fits, with layout choices left. Compute Σ(BAR1)+alignments and
  compare against the firmware window **before** designing anything clever.
- Kernel cmdline: `intel_iommu=on iommu=pt` (peer BAR1 mappings want
  passthrough), `pci=realloc` (lets the kernel re-pack bridge windows at
  boot; see Layer 1 warning).

## Layer 1 — custom kernel: early ReBAR unlock + window sizing (ReBAR-capped cards only)

**Purpose.** The kernel allocates BAR resources during enumeration — before
any initramfs hook exists. Cards whose ReBAR size table is vBIOS-capped
cannot be widened from userspace, period. The patch does it *inside*
enumeration and fixes sibling-window alignment gaps behind multi-level
switches.

**Files:** `kernel/nvbigbar-v9-for-linux-7.0.14.patch` (+ the annotated
python applier with the full rationale as docstrings). Cmdline-gated
(`nvbigbar=1`) — without the token the kernel behaves stock, which is how
the experiment stayed safe.

**Build:** same-version kernel sources + your distro's `/boot/config`;
set `LOCALVERSION=-custom`; disable `SYSTEM_TRUSTED_KEYS` (unsigned build);
turn off DEBUG_INFO if you want fast iteration (must edit `.config` text —
`scripts/config --enable DEBUG_INFO_NONE` gets reverted by `olddefconfig`).
Install as a **separate flavor** (`vmlinuz-<ver>-custom` + own GRUB entry),
never over the distro kernel. Order matters: `dkms install` first, then
`dracut --add-drivers ...` — reverse order gives an initrd missing the GPU
modules.

**Acceptance:** `dmesg`/journal shows the patch's own lines asking for
32G; `/sys/bus/pci/devices/*/resource` line 2 is 32 GiB; NO
`can't assign; no space` on any bridge in the GPU chain; and after driver
bind, no `nvidia ...: BAR 1 ... releasing` (see Layer 3 — that line means
the *driver* is shrinking your BAR back).

**Failure modes.** `pci=realloc` retry loops that fail to the bottom
**release the whole chain** — every GPU behind the switch loses every BAR
until cold power-cycle. This is why the boot entry is one-shot
(`grub-reboot`) with the distro kernel as permanent default. Manual
`setpci` bridge-window writing is a separate, worse failure mode — see
docs/06; don't.

## Layer 2 — initramfs early unlock (third-party lineage; see THIRD_PARTY.md)

**Purpose.** For modded cards, widen 0x610 before first driver bind and
load the card firmware needed at probe time. Implemented as a dkms module
(`gpu_unlock.targets=` on the kernel cmdline lists target BDFs) plus two
custom dracut modules hooking `pre-udev`.

**Pitfalls learned:**
- dracut's packaged `force_drivers` / `rd.driver.pre` drop-ins can be
  *present in the image and still do nothing* (they're read from the real
  kernel cmdline, which doesn't exist in the pre-udev stage). Write your own
  module with `inst_hook pre-udev 20` + explicit `modprobe`.
- Unlock modules do their work in `module_init` and require the device to
  have **no driver bound**. Manually modprobing them later prints
  `unlock failed (-16)` — ordering, not brokenness.
- The initrd embeds a **snapshot** of module config (conf files under
  `/etc/modprobe.d` are copied at build time). Edit conf on disk, reboot,
  and `/proc/driver/nvidia/params` shows... the old values. Rebuild the
  initrd (`dracut -f`), then verify *inside the image*, not on disk.

## Layer 3 — NVIDIA driver: 615.71.09 + registry keys

**Purpose.** Consumer multi-GPU P2P over BAR1 doesn't exist in stock NVIDIA
drivers. The community fork (see THIRD_PARTY.md) provides it; we build it
ourselves and install to `/lib/modules/<kver>/updates/p2p/` — deliberately
**outside** the distro's DKMS/apt package management, so `apt` can never
touch it. (Corollary: `nvidia-smi` showing 615.71.09 while the apt stack is
held at 610 is *normal*; never "fix" this by unholding apt packages. 26
nvidia/nccl packages are `apt-mark hold`ed on this box.)

**Registry keys** (`/etc/modprobe.d/*.conf`, into the initrd snapshot):

```
options nvidia NVreg_RegistryDwords="RMDisableFeatureDisablement=1"
options nvidia NVreg_EnableResizableBar=0
options nvidia NVreg_RegistryDwordsPerDevice="pci=<bdf1>;RMForceStaticBar1=1;RMPcieP2PType=1;RMForceP2PType=1;pci=<bdf2>;...;pci=<bdf3>;...;"
```

- `EnableResizableBar=0`: stops the driver shrinking the kernel's 32G BAR
  back to factory table max after a GPU reset. (Default is 0; if any conf
  has `RegistryDwords` with EnableResizableBar=1, **that one wins** over the
  module option. Grep all of /etc/modprobe.d.)
- `RMForceStaticBar1=1`: full-FB static BAR1 mapping → global peer DMA
  window exists (`bar1Dma sz != 0`). Without it the driver fail-closes the
  managed/peer aperture gate and NCCL-class access can never exist.
  Size gate: BAR1 − ~512M (console+mailbox) ≥ client-visible FB — 32G BAR1
  covers 20G/24G cards.
- `RMPcieP2PType=1;RMForceP2PType=1`: force BAR1 P2P path (stock would
  refuse based on a PCIe topology walk that can't see an external switch —
  `switch=0` in the driver's own probe output).
- **Tri-state gotcha:** these keys have AUTO defaults. *Deleting*
  `RMForceStaticBar1=X` does **not** mean "off" — AUTO re-enables static
  BAR1 on 32G-BAR1 machines. To disable, write `=0` explicitly. And release
  drivers compile out INFO-level logging, so "the confirmation line isn't
  in dmesg" means nothing — verify functionally.

**Acceptance:** `/proc/driver/nvidia/params` shows your RegistryDwordsPerDevice
*as of this boot* (compare against conf mtime vs boot time — conf newer than
boot means you're still running the previous config, which has fooled us
before and would send a rollback in the wrong direction); dmesg shows
`p2pOverride=0x211` / `connectivity=PCIE_BAR1`; `nvidia-smi -q` BAR1 Total =
32768 MiB per card (the driver's own view — lspci alone can disagree with
the RM and both can be "right" about different things).

## Layer 4 — runtime re-assert timers (both, everyone with switches)

`scripts/systemd/`:
- `acs-p2p-enable` — clears switch-port ACS at boot+60s. **Everyone with a
  P2P switch needs this one.**
- `nvbigbar-unlock` — re-widens 0x610/ReBAR ctrl on modded cards after any
  GPU reset, boot+60s. Modded-card owners need this.

Read the inline comment in `acs-p2p-enable.service` about
`RemainAfterExit` — it is the difference between a self-healing setup and a
decorative one (docs/02 has the full story).

## Layer 5 — engine env (llama.cpp / NCCL users)

- **Before** the ACS fix: `NCCL_P2P_DISABLE=1` is *mandatory* — NCCL's
  default `direct pointer` transport hangs at the first collective when the
  fabric silently drops writes. `NCCL_P2P_DIRECT_DISABLE=1` alone does NOT
  save you (CUMEM route uses SM access → same silent death).
- **After** the ACS fix: remove both. Verified same-day A/B: prefill
  +12.8%, decode +6.3% (docs/05).
- `GGML_CUDA_P2P`: ggml checks `getenv() != nullptr` — setting it to *any*
  value enables explicit `cudaDeviceEnablePeerAccess` on every pair at init.
  Don't set it to "0" thinking it's off.

## Rollback ladder (what we actually kept)

1. In-session: nothing — mappings are per-process.
2. Keys/config: restore backed conf → rebuild initrd → reboot.
3. Boot-level arming: delete ESP marker (disarm) + cold power-cycle →
   everything volatile is factory. No flash was ever written; no card is
   bricked by any step above.
4. Keep the distro kernel entry as GRUB default, forever.
