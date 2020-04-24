FUTHARK = ~/.local/bin/futhark
SIZES = 13 42 8704 32768 524288 1048576
# 65536 131072 262144 524288 1048576 16777216
# 33 1024 1025 2048 8704

allcuda: compile compile-simple-cuda dump-cuda test-cuda
all: compile compile-simple-opencl dump-simple test

compile:
	stack install --fast

compile-simple-opencl:
	$(FUTHARK) opencl tests/scan/simple.fut

compile-simple-cuda:
	$(FUTHARK) cuda tests/scan/simple.fut

run-simple:
	echo "[1,2,3,4,5,6,7,8]" | ./tests/scan/simple

dump-simple:
	./tests/scan/simple --dump-opencl tests/scan/simple-kernel.c

gpu-simple:
	$(FUTHARK) dev --gpu tests/scan/simple.fut > tests/scan/simple.gpu

gpu-seg:
	$(FUTHARK) dev --gpu tests/scan/seg-scan.fut > tests/scan/seg.gpu

dump-fused:
	$(FUTHARK) dev --gpu tests/intragroup/scan0.fut > tests/intragroup/scan0.gpu
	# ./tests/intragroup/scan0 --dump-opencl tests/intragroup/scan0-kernel.c

dump-cuda:
	./tests/scan/simple --dump-cuda tests/scan/simple-cuda-kernel.c

load-cuda:
	./tests/scan/simple --load-cuda tests/scan/simple-cuda-kernel.c < tests/scan/kA-131072.data

test: $(SIZES:%=kA-%.data)
	$(FUTHARK) test --backend=opencl tests/scan/simple.fut

test-cuda: $(SIZES:%=kA-%.data)
	$(FUTHARK) test --backend=cuda tests/scan/simple.fut

kA-%.data:
	futhark dataset --i32-bounds=-10000:10000 -g [$*]i32 > tests/scan/$@

ntest: $(SIZES:%=kA-%.data)
	$(FUTHARK) test --backend=cuda tests/scan/n-tests.fut