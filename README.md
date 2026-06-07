# asmatrix

Matrix rain in pure x86-64 Linux assembly. Runs in about 40KB RSS.

![color picker](./assets/demo.gif?raw=true)

## Install
```bash
sudo curl -fsSL https://github.com/ungaul/asmatrix/releases/download/latest/asmatrix-linux-x86_64 -o /usr/local/bin/asmatrix && sudo chmod +x /usr/local/bin/asmatrix
```

## Build from source
Requires `nasm` and `ld` (binutils).
```bash
make
./matrix
```

## Usage
```bash
./matrix [--density=1-9] [--speed=1-9] [--color=SCHEME]

  --density=1-9   Column density   (1=sparse ... 9=dense,  default 5)
  --speed=1-9     Animation speed  (1=slow   ... 9=fast,   default 5)
  --color=SCHEME  Color scheme     (default: green)
                  Schemes: green  red  blue  cyan  yellow  white
  --help          Show this message
```
