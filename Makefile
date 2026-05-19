TARGET = matrix

all: $(TARGET)

$(TARGET): matrix.asm
	nasm -f elf64 -o matrix.o matrix.asm
	ld -o matrix matrix.o

clean:
	rm -f matrix.o matrix

.PHONY: all clean
