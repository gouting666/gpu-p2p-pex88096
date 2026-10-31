// scan_bar1_fast: 在 BAR1 窗口里按步长抽查，找 GPU 写进去的图案落在窗口哪个偏移
// 用法: scan_bar1_fast <gpu 0..2> <pat hex> [步长 MiB=4]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>

#define WIN (32ULL << 30)
#define BLK (64u << 10)

int main(int argc, char **argv)
{
    if (argc < 3) { printf("用法: %s <gpu> <pat hex> [step MiB]\n", argv[0]); return 2; }
    const char *bdfs[3] = {"0000:05:00.0", "0000:0c:00.0", "0000:0d:00.0"};
    int g = atoi(argv[1]);
    unsigned char pat = (unsigned char)strtoul(argv[2], NULL, 16);
    unsigned long long step = (argc > 3 ? (unsigned long long)atoi(argv[3]) : 4ULL) << 20;

    char path[256];
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource1", bdfs[g]);
    int fd = open(path, O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }
    void *m = mmap(NULL, WIN, PROT_READ, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }

    unsigned char *buf = malloc(BLK);
    unsigned long long hits = 0;
    for (unsigned long long off = 0; off + BLK <= WIN; off += step) {
        memcpy(buf, (unsigned char *)m + off, BLK);
        unsigned n = 0, best = 0;
        for (unsigned i = 0; i < BLK; i++) {
            if (buf[i] == pat) { if (++n > best) best = n; }
            else n = 0;
        }
        if (best >= 32) {
            printf("  gpu%d BAR1+0x%llx  最长 %u 字节的 0x%02X run\n", g, off, best, pat);
            if (++hits >= 16) { printf("  (已打 16 条，停)\n"); break; }
        }
    }
    if (!hits) printf("  gpu%d 窗口内没找到 0x%02X（步长 %llu MiB）\n", g, pat, step >> 20);
    munmap(m, WIN); close(fd);
    return 0;
}
