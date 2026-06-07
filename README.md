# asmatrix

Matrix rain in pure x86-64 Linux assembly.

> I did this in order to see the potential of Assembly, and how even low-level languages can compare in raw performance for the same result.

 Benchmarks:
| Metric | asmatrix | cmatrix |
|---|---|---|---|
| CPU cycles | 11,251,832 | 193,819,938 |
| Instructions | 10,825,898 | 220,158,233 |
| Cache misses | 3,897 | 156,683 |
| RSS (physical RAM) | 40 kB | 4,728 kB |
| Virtual memory | 256 kB | 6,336 kB |

![preview](./assets/preview.gif)

## Install
```bash
sudo curl -fsSL https://github.com/ungaul/asmatrix/releases/download/latest/asmatrix-linux-x86_64 -o /usr/local/bin/asmatrix && sudo chmod +x /usr/local/bin/asmatrix
```

## Build from source
Requires `nasm` and `ld` (binutils).
```bash
make
chmod +x ./asmatrix
sudo cp ./asmatrix /usr/local/bin/ 
```

## Usage
```bash
asmatrix [--density 1-9] [--speed 1-9] [--color SPEC]

  --density 1-9   Column density   (1=sparse ... 9=dense,  default 5)
  --speed 1-9     Animation speed  (1=slow   ... 9=fast,   default 7)
  --color SPEC    Color: name, hex (#RRGGBB), or ANSI 0-255  (default: green)
  --help          Show this message
```
