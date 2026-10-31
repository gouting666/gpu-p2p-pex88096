// probe_vmm: 用 CUDA 合法路径(VMM cuMemCreate/Export/Import/Map + cuMemSetAccess)
// 把 peer 显存映射进本卡 VA，再用**本卡 SM 的 kernel** 直接 load/store 过去。
// 这是"SM 直访对端显存"的官方通路(NCCL P2P/CUMEM 同款)，不手搓 PTE，不碰主机物理地址。
// 用法: probe_vmm <src_dev> <dst_dev> [sizeMiB]
#include <cuda.h>
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#define FAIL(...) do { printf(__VA_ARGS__); printf("\n"); return 1; } while (0)

#define CK(x) do { CUresult _r=(x); if (_r!=CUDA_SUCCESS) { const char*_s="?"; cuGetErrorName(_r,&_s); \
    printf("FAIL %s -> %d %s\n", #x, (int)_r, _s); return 1; } } while (0)

__global__ void fillb(unsigned char *p, size_t n, unsigned char v)
{
    size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x;
    size_t step = (size_t)gridDim.x * blockDim.x;
    for (; i < n; i += step) p[i] = v;
}

__global__ void sumb(const unsigned char *p, size_t n, unsigned long long *out)
{
    unsigned long long acc = 0;
    size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x;
    size_t step = (size_t)gridDim.x * blockDim.x;
    for (; i < n; i += step) acc += p[i];
    __shared__ unsigned long long s;
    if (threadIdx.x == 0) s = 0;
    __syncthreads();
    atomicAdd(&s, acc);
    __syncthreads();
    if (threadIdx.x == 0) atomicAdd(out, s);
}

static double now_ms(void)
{
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

/* expect_fill: 该步之前写入的填充字节；0 表示只报数不判定 */
static int dev_sum(int dev, CUcontext ctx, unsigned char *va, size_t n,
                   const char *what, unsigned char expect_fill, double *gbps)
{
    CUdeviceptr outd = 0;
    unsigned long long h = 0;
    CUresult r;
    double t0, t1;

    cudaSetDevice(dev);
    if (cudaMalloc((void **)&outd, 8) != cudaSuccess) FAIL("[%s] cudaMalloc 失败", what);
    cudaMemset((void *)outd, 0, 8);
    t0 = now_ms();
    sumb<<<512, 256>>>(va, n, (unsigned long long *)outd);
    if (cudaDeviceSynchronize() != cudaSuccess) FAIL("[%s] kernel 执行失败: %s", what, cudaGetErrorString(cudaGetLastError()));
    t1 = now_ms();
    cudaMemcpy(&h, (void *)outd, 8, cudaMemcpyDeviceToHost);
    cudaFree((void *)outd);
    if (expect_fill) {
        unsigned long long want = (unsigned long long)expect_fill * n;
        printf("      [%s] sum=%#llx  期望(%#04x)=%#llx  %s  %.3f ms  %.2f GB/s\n",
               what, h, expect_fill, want, (h == want) ? "PASS" : "FAIL——内容不对",
               t1 - t0, n / (t1 - t0) / 1e6);
    } else {
        printf("      [%s] sum=%#llx  %.3f ms  %.2f GB/s\n",
               what, h, t1 - t0, n / (t1 - t0) / 1e6);
    }
    if (gbps) *gbps = n / (t1 - t0) / 1e6;
    (void)r; (void)ctx;
    return 0;
}

static int dev_fill(int dev, unsigned char *va, size_t n, unsigned char v, const char *what, double *gbps)
{
    double t0, t1;
    cudaSetDevice(dev);
    t0 = now_ms();
    fillb<<<512, 256>>>(va, n, v);
    if (cudaDeviceSynchronize() != cudaSuccess) FAIL("[%s] fill kernel 失败: %s", what, cudaGetErrorString(cudaGetLastError()));
    t1 = now_ms();
    printf("      [%s] 写 %#x  %.3f ms  %.2f GB/s\n", what, v, t1 - t0, n / (t1 - t0) / 1e6);
    if (gbps) *gbps = n / (t1 - t0) / 1e6;
    return 0;
}

int main(int argc, char **argv)
{
    int src = atoi(argv[1]), dst = atoi(argv[2]);
    size_t MiB = (argc > 3) ? atol(argv[3]) : 8;
    size_t n = MiB << 20;
    CUdevice devs[8]; CUcontext ctxs[8];
    int ndev = 0, can = 0;
    CUresult r;
    CUmemAllocationProp prop;
    CUmemGenericAllocationHandle hSrc = 0, hDst = 0;
    CUdeviceptr vaSrc = 0, vaDst = 0;
    CUmemAccessDesc ad;
    size_t gran = 0, sz;
    int fd = -1, i;
    double g;

    CK(cuInit(0));
    CK(cuDeviceGetCount(&ndev));
    printf("== VMM SM 直访探针: owner=GPU%d  mapper=GPU%d  size=%zu MiB ==\n", src, dst, MiB);
    if (src >= ndev || dst >= ndev) FAIL("设备号越界 (ndev=%d)", ndev);

    for (i = 0; i < ndev; i++) {
        CK(cuDeviceGet(&devs[i], i));
        CK(cuDevicePrimaryCtxRetain(&ctxs[i], devs[i]));
    }
    {
        CUdevice d0, d1; int c01 = 0, c10 = 0;
        CK(cuDeviceGet(&d0, src)); CK(cuDeviceGet(&d1, dst));
        r = cuDeviceCanAccessPeer(&c01, d0, d1);
        r = cuDeviceCanAccessPeer(&c10, d1, d0);
        printf("   cuDeviceCanAccessPeer: %d->%d = %d, %d->%d = %d\n", src, dst, c01, dst, src, c10);
    }

    /* ---- 1) 在 owner(src) 上建 VMM 分配并映射进自己的 VA ---- */
    CK(cuCtxSetCurrent(ctxs[src]));
    memset(&prop, 0, sizeof(prop));
    prop.type = CU_MEM_ALLOCATION_TYPE_PINNED;
    prop.location.type = CU_MEM_LOCATION_TYPE_DEVICE;
    prop.location.id = src;
    prop.requestedHandleTypes = CU_MEM_HANDLE_TYPE_POSIX_FILE_DESCRIPTOR;
    CK(cuMemGetAllocationGranularity(&gran, &prop, CU_MEM_ALLOC_GRANULARITY_MINIMUM));
    printf("   granularity = %zu\n", gran);
    sz = (n + gran - 1) / gran * gran;
    CK(cuMemCreate(&hSrc, sz, &prop, 0));
    CK(cuMemAddressReserve(&vaSrc, sz, 0, 0, 0));
    CK(cuMemMap(vaSrc, sz, 0, hSrc, 0));
    memset(&ad, 0, sizeof(ad));
    ad.location.type = CU_MEM_LOCATION_TYPE_DEVICE; ad.location.id = src; ad.flags = CU_MEM_ACCESS_FLAGS_PROT_READWRITE;
    CK(cuMemSetAccess(vaSrc, sz, &ad, 1));
    if (dev_fill(src, (unsigned char *)vaSrc, n, 0x5A, "owner 自写 0x5A", &g)) return 1;
    if (dev_sum(src, ctxs[src], (unsigned char *)vaSrc, n, "owner 自读(本地基线)", 0x5A, &g)) return 1;

    /* ---- 2) 导出 shareable handle ---- */
    CK(cuMemExportToShareableHandle((void *)&fd, hSrc, CU_MEM_HANDLE_TYPE_POSIX_FILE_DESCRIPTOR, 0));
    printf("   export POSIX_FD handle = %d\n", fd);

    /* ---- 3) 在 mapper(dst) 上导入 + 映射进 dst 的 VA ---- */
    CK(cuCtxSetCurrent(ctxs[dst]));
    {   /* 关键：先让 libcuda/RM 为这对卡建立 P2P 对象(enabled)，否则下面 map 的 PTE 不带 BAR1 编码 */
        cudaError_t e;
        cudaSetDevice(dst);
        e = cudaDeviceEnablePeerAccess(src, 0);
        printf("   cudaDeviceEnablePeerAccess(%d -> %d) = %d (%s)\n", src, dst, (int)e, cudaGetErrorString(e));
    }
    CK(cuMemImportFromShareableHandle(&hDst, (void *)(uintptr_t)fd, CU_MEM_HANDLE_TYPE_POSIX_FILE_DESCRIPTOR));
    CK(cuMemAddressReserve(&vaDst, sz, 0, 0, 0));
    CK(cuMemMap(vaDst, sz, 0, hDst, 0));
    memset(&ad, 0, sizeof(ad));
    ad.location.type = CU_MEM_LOCATION_TYPE_DEVICE; ad.location.id = dst; ad.flags = CU_MEM_ACCESS_FLAGS_PROT_READWRITE;
    printf("   cuMemSetAccess(peer=%d, RW) ...\n", dst);
    CK(cuMemSetAccess(vaDst, sz, &ad, 1));
    printf("   mapper VA = %#llx (owner VA = %#llx)\n", (unsigned long long)vaDst, (unsigned long long)vaSrc);

    /* ---- 4) mapper 的 SM 读 owner 的显存 ---- */
    if (dev_sum(dst, ctxs[dst], (unsigned char *)vaDst, n, "mapper SM 读 peer", 0x5A, &g)) return 1;

    /* ---- 5) mapper 的 SM 写 owner 的显存，回 owner 侧核对 ---- */
    if (dev_fill(dst, (unsigned char *)vaDst, n, 0xA7, "mapper SM 写 peer 0xA7", &g)) return 1;
    if (dev_sum(src, ctxs[src], (unsigned char *)vaSrc, n, "owner 侧复核(应=0xA7)", 0xA7, &g)) return 1;

    /* ---- 6) 同一条映射，改用拷贝引擎(CE)走一遍：用来区分"映射坏了" vs "SM 走不通" ---- */
    {
        unsigned char *lbuf = NULL;
        double t0, t1;
        cudaSetDevice(dst);
        if (cudaMalloc((void **)&lbuf, n) != cudaSuccess) FAIL("[CE] cudaMalloc 失败");
        fillb<<<512, 256>>>(lbuf, n, 0x33);
        if (cudaDeviceSynchronize() != cudaSuccess) FAIL("[CE] 本地填充失败");
        t0 = now_ms();
        if (cudaMemcpyAsync((void *)vaDst, lbuf, n, cudaMemcpyDeviceToDevice, 0) != cudaSuccess)
            FAIL("[CE] 写 peer VA 失败: %s", cudaGetErrorString(cudaGetLastError()));
        if (cudaDeviceSynchronize() != cudaSuccess) FAIL("[CE] 写 peer VA 未完成");
        t1 = now_ms();
        printf("      [CE 写 peer VA] %.3f ms  %.2f GB/s\n", t1 - t0, n / (t1 - t0) / 1e6);

        cudaSetDevice(src);
        if (dev_sum(src, ctxs[src], (unsigned char *)vaSrc, n, "owner 侧复核 CE 写(应=0x33)", 0x33, &g)) return 1;

        cudaSetDevice(dst);
        cudaMemsetAsync(lbuf, 0, n, 0);
        t0 = now_ms();
        if (cudaMemcpyAsync(lbuf, (void *)vaDst, n, cudaMemcpyDeviceToDevice, 0) != cudaSuccess)
            FAIL("[CE] 读 peer VA 失败: %s", cudaGetErrorString(cudaGetLastError()));
        if (cudaDeviceSynchronize() != cudaSuccess) FAIL("[CE] 读 peer VA 未完成");
        t1 = now_ms();
        printf("      [CE 读 peer VA] %.3f ms  %.2f GB/s\n", t1 - t0, n / (t1 - t0) / 1e6);
        {   /* lbuf 里应是 owner 侧当前内容(0x33) */
            CUdeviceptr o = 0; unsigned long long h = 0;
            cudaMalloc((void **)&o, 8); cudaMemset((void *)o, 0, 8);
            sumb<<<512, 256>>>(lbuf, n, (unsigned long long *)o);
            cudaDeviceSynchronize();
            cudaMemcpy(&h, (void *)o, 8, cudaMemcpyDeviceToHost);
            printf("      [CE 读回校验] sum=%#llx  期望(0x33)=%#llx  %s\n", h,
                   (unsigned long long)0x33 * n,
                   (h == (unsigned long long)0x33 * n) ? "通过" : "不符");
            cudaFree((void *)o);
        }
        cudaFree(lbuf);
    }

    /* ---- 7) 真·CE 复核：GPU2 的拷贝引擎从 mapper(GPU1) 的那个 VA 拉数据 ----
       若这里字节精确，说明 PTE 是好的、只是 SM 走不通；若也 garbage，说明映射本身没指对端 */
    if (ndev >= 3 && dst != 2 && src != 2) {
        unsigned char *lb2 = NULL; CUdeviceptr o2 = 0; unsigned long long h2 = 0;
        double t0, t1;
        cudaSetDevice(2);
        if (cudaMalloc((void **)&lb2, n) != cudaSuccess) FAIL("[CE2] cudaMalloc 失败");
        cudaMemset(lb2, 0, n);
        cudaMalloc((void **)&o2, 8); cudaMemset((void *)o2, 0, 8);
        t0 = now_ms();
        if (cudaMemcpyPeerAsync(lb2, 2, (void *)vaDst, dst, n, 0) != cudaSuccess)
            FAIL("[CE2] PeerAsync 失败: %s", cudaGetErrorString(cudaGetLastError()));
        if (cudaDeviceSynchronize() != cudaSuccess) FAIL("[CE2] PeerAsync 未完成: %s", cudaGetErrorString(cudaGetLastError()));
        t1 = now_ms();
        printf("      [CE2 GPU2<-GPU1的VA]  %.3f ms  %.2f GB/s\n", t1 - t0, n / (t1 - t0) / 1e6);
        sumb<<<512, 256>>>(lb2, n, (unsigned long long *)o2);
        cudaDeviceSynchronize();
        cudaMemcpy(&h2, (void *)o2, 8, cudaMemcpyDeviceToHost);
        /* 此刻那块显存的内容是第 6 步 CE 写进去的 0x33；拉到它就算 CE 走通。
           （旧版拿最初的 0x5A 当期望，数据明明对却打印"不符"，误导过两次。） */
        unsigned long long want33 = (unsigned long long)0x33 * n;
        unsigned long long want5A = (unsigned long long)0x5A * n;
        printf("      [CE2 字节校验] sum=%#llx 期望(当前内容 0x33)=%#llx  %s\n", h2, want33,
               (h2 == want33) ? "PASS——GPU2 的 CE 拉到对端当前内容"
                              : ((h2 == want5A) ? "PASS(内容是原始的 0x5A，同样说明 CE 走通)"
                                                : "FAIL——garbage，映射没指对端"));
        cudaFree(lb2); cudaFree((void *)o2);
    }

    /* ---- 8) 真·CE 写进入 mapped VA：GPU2 的 CE 把数据推进 GPU1 的 VA(即 GPU0 的显存) ---- */
    if (ndev >= 3 && dst != 2 && src != 2) {
        unsigned char *sb2 = NULL;
        double t0, t1;
        cudaSetDevice(2);
        if (cudaMalloc((void **)&sb2, n) != cudaSuccess) FAIL("[CEW] cudaMalloc 失败");
        fillb<<<512, 256>>>(sb2, n, 0x77);
        cudaDeviceSynchronize();
        t0 = now_ms();
        if (cudaMemcpyPeerAsync((void *)vaDst, dst, sb2, 2, n, 0) != cudaSuccess)
            FAIL("[CEW] PeerAsync 写失败: %s", cudaGetErrorString(cudaGetLastError()));
        if (cudaDeviceSynchronize() != cudaSuccess) FAIL("[CEW] PeerAsync 写未完成");
        t1 = now_ms();
        printf("      [CEW GPU2 的CE 写进 mapped VA]  %.3f ms  %.2f GB/s\n", t1 - t0, n / (t1 - t0) / 1e6);
        cudaSetDevice(src);
        if (dev_sum(src, ctxs[src], (unsigned char *)vaSrc, n, "owner 侧复核 CE 写(应=0x77)", 0x77, &g)) return 1;
        cudaFree(sb2);
    }

    printf("== 判定: SM 行全绿=SM 直访成立; SM 行 garbage 而 CE 行通过=映射好但 SM 走不通 ==\n");
    return 0;
}
