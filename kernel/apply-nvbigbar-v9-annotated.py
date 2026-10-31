#!/usr/bin/env python3
"""v9 补丁：NV 子树的非 pref 桥窗「按对齐上取整」，消除兄弟窗之间的对齐跳空。

v8 实测（2026-10-28 21:13 启动）—— sizing 已经对了，卡在 assignment：
  02:08.0 / 0a:00.0 桥窗 [mem size 0x06200000]（98M）、0b:00.0 / 0b:10.0 各
  [mem size 0x03100000]（49M），尺寸都算出来了，但全部 "can't assign; no space"，
  结果是两张 3080 的 BAR0/BAR3/ROM 全灭，只剩 3090（BAR1 三卡 32G 都拿到了）。

根因在 pbus_size_mem 的累加方式：
    size += max(r_size, align);          /* 只按 size 累加，不按 align 补齐 */
  兄弟窗之间只要「尺寸不是对齐的整数倍」就必然出现跳空（例如 49M 的窗后面
  下一个 32M 对齐点要再走 15M），而窗口尺寸没把这部分算进去。
  实测链：01:00.0 只有 148M（89000000-923fffff），3090 支吃掉前 49M 后，
  98M 的 02:08.0 窗只能落 8e000000，+98M=93c00000 越过窗尾 -> failed。
  v8 把 root port 撑到 896M 也没用，因为瓶颈在下一层 148M 的窗。

修法（只作用于「子树含 NVIDIA GPU 且是主存窗（非 pref）」的桥）：
  1) 子资源按自身对齐上取整后累加：size += round_up(max(r_size, align), align)
  2) 记录子资源最大对齐 nv_max_align，窗口头部对齐抬到它
  3) 窗口尺寸按 nv_max_align 上取整
  => 每层窗尺寸都是其对齐的整数倍，兄弟窗完美紧挨，零跳空。
     本机链路预期：0b 各 64M、0a 128M、02:08.0 128M、02:00.0 64M、
     01:00.0 224M（今天 148M 装不下，224M 绰绰有余，root port 896M 不变）。

只在 cmdline 带 nvbigbar=1 时生效。
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
f = root / "drivers/pci/setup-bus.c"
src = f.read_text()

if "实验补丁 v9" in src:
    print("setup-bus.c: v9 已存在，跳过")
    sys.exit(0)

# 1) 局部变量
a = "\tresource_size_t big_align = 0;\t/* 实验补丁 v5 */\n\tint big_cnt = 0;\t\t/* 实验补丁 v5 */\n"
assert a in src, "找不到 big_cnt 定义"
src = src.replace(a, a +
    "\tbool nv_pack = false;\t\t/* 实验补丁 v9 */\n"
    "\tresource_size_t nv_max_align = 0;\t/* 实验补丁 v9 */\n"
    "\tresource_size_t v9_old;\t\t/* 实验补丁 v9 */\n", 1)

# 2) 循环前判定
b = "\tmax_order = 0;\n\tsize = 0;\n"
assert b in src, "找不到 max_order/size 初始化"
src = src.replace(b, b +
    "\t/* 实验补丁 v9：NV 子树的非 pref 窗，子资源按对齐上取整累加 */\n"
    "\tnv_pack = nvbigbar_enabled && bus->self &&\n"
    "\t\t  !(b_res->flags & IORESOURCE_PREFETCH) &&\n"
    "\t\t  nvbigbar_bus_has_nv_gpu(bus);\n", 1)

# 3) 累加方式
c = "\t\t\tr_size = resource_size(r);\n\t\t\tsize += max(r_size, align);\n"
assert c in src, "找不到 size 累加"
src = src.replace(c,
    "\t\t\tr_size = resource_size(r);\n"
    "\t\t\tif (nv_pack) {\t/* 实验补丁 v9 */\n"
    "\t\t\t\tsize += round_up(max(r_size, align), align);\n"
    "\t\t\t\tnv_max_align = max(nv_max_align, align);\n"
    "\t\t\t} else {\n"
    "\t\t\t\tsize += max(r_size, align);\n"
    "\t\t\t}\n", 1)

# 4) 窗口对齐 + 尺寸上取整（放在 size0 计算之后、root port 兜底之前）
d = ("\tsize0 = calculate_memsize(size, realloc_head ? 0 : add_size,\n"
     "\t\t\t\t  0, win_align);\n")
assert d in src, "找不到 size0 = calculate_memsize"
src = src.replace(d, d +
    "\n\t/* 实验补丁 v9：窗口自身对齐到最大子对齐，尺寸也取该对齐的整数倍 */\n"
    "\tif (nv_pack && nv_max_align) {\n"
    "\t\tv9_old = size0;\n"
    "\t\tif (nv_max_align > min_align)\n"
    "\t\t\tmin_align = nv_max_align;\n"
    "\t\tsize0 = round_up(size0, nv_max_align);\n"
    "\t\tif (size0 != v9_old)\n"
    "\t\t\tpr_info(\"PCI: nvbigbar: %04x:%02x 非 pref 窗 %lluMB -> %lluMB（%lluMB 对齐）\\n\",\n"
    "\t\t\t\tpci_domain_nr(bus), bus->number,\n"
    "\t\t\t\t(unsigned long long)(v9_old >> 20),\n"
    "\t\t\t\t(unsigned long long)(size0 >> 20),\n"
    "\t\t\t\t(unsigned long long)(nv_max_align >> 20));\n"
    "\t}\n", 1)

f.write_text(src)
print("setup-bus.c: v9 已写入")
print("  nv_pack 判定:", src.count("nv_pack = nvbigbar_enabled"))
print("  对齐累加  :", src.count("round_up(max(r_size, align), align)"))
print("  尺寸上取整:", src.count("size0 = round_up(size0, nv_max_align)"))
