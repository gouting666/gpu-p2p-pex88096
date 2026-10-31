// probe_path: 判 10.6GB/s 的 cudaMemcpyPeer 到底是真 fabric P2P 还是 host 中转
// 测法：同一对卡同一尺寸，分四种通路对比
//   1) H2D / D2H（pinned）单程线速
//   2) host 中转往返（D2H 后 H2D）—— 理论下限 = min(H2D,D2H)/2
//   3) cudaMemcpyPeerAsync（不 EnablePeerAccess）
//   4) cudaMemcpyPeerAsync（EnablePeerAccess 之后）
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define N (64u << 20)

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec*1000.0+t.tv_nsec/1e6; }

static void gbs(const char *tag, double ms) { printf("  %-46s %8.3f ms  %6.2f GB/s\n", tag, ms, N/(ms)/1e6); }

int main(int argc, char **argv)
{
    int a = atoi(argv[1]), b = atoi(argv[2]);
    unsigned char *pa = NULL, *pb = NULL, *h = NULL;
    double t0;

    cudaSetDevice(a);
    cudaMalloc(&pa, N);
    cudaMemset(pa, 0x5A, N);
    cudaSetDevice(b);
    cudaMalloc(&pb, N);
    cudaMemset(pb, 0, N);
    cudaHostAlloc(&h, N, cudaHostAllocDefault);
    printf("== probe_path %d->%d  %u MiB ==\n", a, b, N >> 20);

    /* 1) 单程线速 */
    cudaSetDevice(b);
    t0 = now_ms(); cudaMemcpy(h, pb, N, cudaMemcpyDeviceToHost); cudaDeviceSynchronize();
    gbs("D2H pinned (GPU->host)", now_ms() - t0);

    t0 = now_ms(); cudaMemcpy(pb, h, N, cudaMemcpyHostToDevice); cudaDeviceSynchronize();
    gbs("H2D pinned (host->GPU)", now_ms() - t0);

    /* 2) host 中转往返：GPU0 -> host -> GPU1 */
    {
        double tD, tH;
        cudaSetDevice(a);
        t0 = now_ms(); cudaMemcpy(h, pa, N, cudaMemcpyDeviceToHost); cudaDeviceSynchronize(); tD = now_ms() - t0;
        cudaSetDevice(b);
        t0 = now_ms(); cudaMemcpy(pb, h, N, cudaMemcpyHostToDevice); cudaDeviceSynchronize(); tH = now_ms() - t0;
        printf("  %-46s %8.3f ms  %6.2f GB/s  (D2H %.3f + H2D %.3f)\n",
               "host round-trip (staging ceiling)", tD + tH, N/(tD + tH)/1e6, tD, tH);
    }

    /* 3) peer access OFF 的 peer copy */
    cudaSetDevice(a);
    t0 = now_ms();
    cudaMemcpyPeerAsync(pb, b, pa, a, N, 0);
    cudaDeviceSynchronize();
    gbs("cudaMemcpyPeer (peer access OFF)", now_ms() - t0);

    /* 4) EnablePeerAccess 之后 */
    {
        cudaError_t e1 = cudaSetDevice(a), e2;
        (void)e1;
        e2 = cudaDeviceEnablePeerAccess(b, 0);
        printf("  cudaDeviceEnablePeerAccess(%d->%d) = %d (%s)\n", a, b, e2,
               e2 == cudaSuccess ? "ok" : cudaGetErrorString(e2));
        t0 = now_ms();
        cudaMemcpyPeerAsync(pb, b, pa, a, N, 0);
        cudaDeviceSynchronize();
        gbs("cudaMemcpyPeer (peer access ON)", now_ms() - t0);
    }

    return 0;
}
