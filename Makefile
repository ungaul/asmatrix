TARGET = asmatrix

all: $(TARGET)

$(TARGET): matrix.asm
	nasm -f elf64 -o asmatrix.o matrix.asm
	ld -o asmatrix asmatrix.o

clean:
	rm -f asmatrix.o asmatrix

.PHONY: all clean
