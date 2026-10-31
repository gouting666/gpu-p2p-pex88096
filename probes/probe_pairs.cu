// probe_pairs: 六对全部走 EnablePeerAccess 后的真 fabric 拷贝，逐字节校验
// 目的：判断 fabric P2P 是否存在任何一对能真正传数据（不是 host 中转）
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define N (8u << 20)

__global__ void fillb(unsigned char *p, size_t n, unsigned char v)
{
    size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x;
    size_t step = (size_t)gridDim.x * blockDim.x;
    for (; i < n; i += step) p[i] = v;
}
__global__ void sumb(const unsigned char *p, size_t n, unsigned long long *o)
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
    if (threadIdx.x == 0) atomicAdd(o, s);
}
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec*1000.0+t.tv_nsec/1e6; }

static unsigned char *buf[3];
static int ndev = 0;

static void setup(void)
{
    cudaGetDeviceCount(&ndev);
    for (int i = 0; i < ndev; i++) {
        cudaSetDevice(i);
        cudaMalloc(&buf[i], N);
        cudaMemset(buf[i], 0, N);
    }
}

static int one(int a, int b, int enable)
{
    unsigned char pat = (unsigned char)(0x11 + a * 7);
    unsigned long long *o = NULL, h = 0;
    cudaError_t e;
    double t0;

    cudaSetDevice(a);
    fillb<<<256, 256>>>(buf[a], N, pat);
    cudaDeviceSynchronize();
    cudaSetDevice(b);
    cudaMemset(buf[b], 0, N);

    if (enable) {
        cudaSetDevice(a);
        e = cudaDeviceEnablePeerAccess(b, 0);
        if (e != cudaSuccess && e != cudaErrorPeerAccessAlreadyEnabled)
            printf("    enable(%d->%d) 失败: %s\n", a, b, cudaGetErrorString(e));
    }

    cudaSetDevice(a);
    t0 = now_ms();
    e = cudaMemcpyPeerAsync(buf[b], b, buf[a], a, N, 0);
    if (e != cudaSuccess) printf("    copy 提交失败: %s\n", cudaGetErrorString(e));
    cudaDeviceSynchronize();
    double ms = now_ms() - t0;

    cudaSetDevice(b);
    if (!o) cudaMalloc(&o, 8);
    cudaMemset(o, 0, 8);
    sumb<<<256, 256>>>(buf[b], N, o);
    cudaDeviceSynchronize();
    cudaMemcpy(&h, o, 8, cudaMemcpyDeviceToHost);
    unsigned long long exp = (unsigned long long)pat * N;
    printf("  %s %d->%d  %8.3f ms %6.2f GB/s  sum=%#llx expect=%#llx %s\n",
           enable ? "[peer-on ]" : "[peer-off]", a, b, ms, N / ms / 1e6, h, exp,
           h == exp ? "BYTE-EXACT" : "数据不符");
    return h == exp;
}

int main(void)
{
    setup();
    printf("== probe_pairs  %u MiB  %d 卡 ==\n", N >> 20, ndev);
    printf("-- peer access OFF (expect host staging; this is NOT fabric)--\n");
    for (int a = 0; a < ndev; a++)
        for (int b = 0; b < ndev; b++)
            if (a != b) one(a, b, 0);
    printf("-- peer access ON (the real fabric test)--\n");
    for (int a = 0; a < ndev; a++)
        for (int b = 0; b < ndev; b++)
            if (a != b) one(a, b, 1);
    return 0;
}
