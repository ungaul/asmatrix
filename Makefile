TARGET = asmatrix
ARCH := $(shell uname -m)

ifneq (,$(filter aarch64 arm64,$(ARCH)))
ARM_AS = as
ARM_LD = ld
else
ARM_AS = aarch64-linux-gnu-as
ARM_LD = aarch64-linux-gnu-ld
endif

all: $(TARGET)

ifneq (,$(filter aarch64 arm64,$(ARCH)))
$(TARGET): matrix_arm64.s
	$(ARM_AS) -o asmatrix.o matrix_arm64.s
	$(ARM_LD) -s -N --no-warn-rwx-segments -o asmatrix asmatrix.o
else
$(TARGET): matrix.asm
	nasm -f elf64 -Ox -o asmatrix.o matrix.asm
	ld -s -N --no-warn-rwx-segments -o asmatrix asmatrix.o
endif

arm64: asmatrix-arm64

asmatrix-arm64: matrix_arm64.s
	$(ARM_AS) -o asmatrix-arm64.o matrix_arm64.s
	$(ARM_LD) -s -N --no-warn-rwx-segments -o asmatrix-arm64 asmatrix-arm64.o

windows: asmatrix.exe

asmatrix.exe: matrix.asm
	nasm -f bin -DWIN -Ox -o asmatrix.exe matrix.asm

clean:
	rm -f asmatrix.o asmatrix asmatrix.exe asmatrix-arm64.o asmatrix-arm64

.PHONY: all arm64 windows clean
