# Build the P2P verification probes. Needs CUDA toolkit (nvcc) and, for
# probe_vmm, the CUDA driver API (-lcuda).
NVCC ?= nvcc
CC   ?= gcc

CUDA_BINS = probe_path probe_pairs probe_enable_check probe_vmm copy_hold
C_BINS    = scan_bar1_fast

all: $(CUDA_BINS) $(C_BINS)

probe_vmm: probe_vmm.cu
	$(NVCC) -O2 -o $@ $< -lcuda

%: %.cu
	$(NVCC) -O2 -o $@ $<

%: %.c
	$(CC) -O2 -o $@ $<

clean:
	rm -f $(CUDA_BINS) $(C_BINS)

.PHONY: all clean
