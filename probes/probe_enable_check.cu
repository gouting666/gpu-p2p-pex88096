// 使能 peer access 后的双向内容校验（最小、正确版：当前设备必须是发起方）
// 用法: sudo ./probe_enable_check <a> <b>
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CK(x) do { cudaError_t _e=(x); if(_e!=cudaSuccess){printf("  !! %s -> %s(%d)\n",#x,cudaGetErrorString(_e),(int)_e);} } while(0)
#define N (8u<<20)

int main(int argc, char **argv) {
    int a = argc > 1 ? atoi(argv[1]) : 0;
    int b = argc > 2 ? atoi(argv[2]) : 1;
    size_t n = N;
    unsigned char *pa = (unsigned char *)malloc(n), *pb = (unsigned char *)malloc(n), *t = (unsigned char *)malloc(n);
    for (size_t i = 0; i < n; i++) { pa[i] = (unsigned char)(i * 3 + 1); pb[i] = (unsigned char)(i * 5 + 2); }

    void *da = NULL, *db = NULL;
    CK(cudaSetDevice(a)); CK(cudaMalloc(&da, n));
    CK(cudaSetDevice(b)); CK(cudaMalloc(&db, n));

    CK(cudaSetDevice(a)); CK(cudaMemcpy(da, pa, n, cudaMemcpyHostToDevice)); CK(cudaDeviceSynchronize());
    CK(cudaSetDevice(b)); CK(cudaMemcpy(db, pb, n, cudaMemcpyHostToDevice)); CK(cudaDeviceSynchronize());

    // 自检：两块缓冲各自的初始内容
    CK(cudaSetDevice(a)); CK(cudaMemcpy(t, da, n, cudaMemcpyDeviceToHost));
    printf("da 初始内容自检: %s\n", memcmp(t, pa, n) == 0 ? "OK" : "BAD");
    CK(cudaSetDevice(b)); CK(cudaMemcpy(t, db, n, cudaMemcpyDeviceToHost));
    printf("db 初始内容自检: %s\n", memcmp(t, pb, n) == 0 ? "OK" : "BAD");

    // 在 a 上使能访问 b
    CK(cudaSetDevice(a));
    int can = 0; CK(cudaDeviceCanAccessPeer(&can, a, b));
    cudaError_t e = cudaDeviceEnablePeerAccess(b, 0);
    printf("canAccessPeer(%d,%d)=%d  EnablePeerAccess(b)=%s(%d)\n", a, b, can, cudaGetErrorString(e), (int)e);

    // b -> a
    CK(cudaSetDevice(a)); CK(cudaMemcpyPeer(da, a, db, b, n)); CK(cudaDeviceSynchronize());
    CK(cudaMemcpy(t, da, n, cudaMemcpyDeviceToHost));
    printf("b->a 使能后: %s (0x%02X/0x%02X vs 期望 0x%02X/0x%02X)\n",
           memcmp(t, pb, n) == 0 ? "内容正确" : "内容错", t[0], t[n-1], pb[0], pb[n-1]);

    // a -> b（反向，另写一段可区分数据到 da 再送过去）
    unsigned char *pa2 = (unsigned char *)malloc(n);
    for (size_t i = 0; i < n; i++) pa2[i] = (unsigned char)(i * 11 + 9);
    CK(cudaSetDevice(a)); CK(cudaMemcpy(da, pa2, n, cudaMemcpyHostToDevice));
    CK(cudaMemcpyPeer(db, b, da, a, n)); CK(cudaDeviceSynchronize());
    CK(cudaSetDevice(b)); CK(cudaMemcpy(t, db, n, cudaMemcpyDeviceToHost));
    printf("a->b 使能后: %s (0x%02X/0x%02X vs 期望 0x%02X/0x%02X)\n",
           memcmp(t, pa2, n) == 0 ? "内容正确" : "内容错", t[0], t[n-1], pa2[0], pa2[n-1]);
    return 0;
}
