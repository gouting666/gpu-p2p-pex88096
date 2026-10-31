// copy_hold: peer-on 拷贝后保持两块 buffer，供 CPU 侧扫 BAR1 做地面真值校验
// 用法: copy_hold <src gpu> <dst gpu> <MiB> <pat hex> <sleep 秒>
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

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

int main(int argc, char **argv)
{
    int a = atoi(argv[1]), b = atoi(argv[2]);
    size_t n = (size_t)atol(argv[3]) << 20;
    unsigned char pat = (unsigned char)strtoul(argv[4], NULL, 16);
    int secs = argc > 5 ? atoi(argv[5]) : 60;

    cudaSetDevice(a);
    unsigned char *pa = NULL;
    cudaMalloc(&pa, n);
    fillb<<<512, 256>>>(pa, n, pat);
    cudaDeviceSynchronize();

    cudaSetDevice(b);
    unsigned char *pb = NULL;
    cudaMalloc(&pb, n);
    cudaMemset(pb, 0, n);

    cudaSetDevice(a);
    cudaError_t e = cudaDeviceEnablePeerAccess(b, 0);
    printf("enable(%d->%d)=%s\n", a, b, cudaGetErrorString(e));

    cudaMemcpyPeer(pb, b, pa, a, n);
    e = cudaGetLastError();
    printf("memcpyPeer= %s\n", cudaGetErrorString(e));

    unsigned long long *o = NULL, h = 0;
    cudaSetDevice(b);
    cudaMalloc(&o, 8);
    cudaMemset(o, 0, 8);
    sumb<<<512, 256>>>(pb, n, o);
    cudaDeviceSynchronize();
    cudaMemcpy(&h, o, 8, cudaMemcpyDeviceToHost);
    printf("dst 校验 sum=%#llx 期望=%#llx %s\n", h, (unsigned long long)pat * n,
           h == (unsigned long long)pat * n ? "通过" : "不符");
    printf("HOLD %ds  src(gpu%d)=%p dst(gpu%d)=%p\n", secs, a, (void *)pa, b, (void *)pb);
    fflush(stdout);
    sleep(secs);
    return 0;
}
