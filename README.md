# asmatrix

Matrix rain in pure x86-64 Linux assembly. No libc, no dependencies.

## Build
```
make
```
Requires `nasm` and `ld` (binutils).

## Run

```
./matrix
```

Press `Ctrl+C` to exit. The terminal is always restored cleanly.

## How it works

- `TIOCGWINSZ` ioctl to read terminal dimensions
- `/dev/urandom` for randomness
- ANSI escape codes written through a 64 KB buffer, flushed once per frame (~30 fps)
- `rt_sigaction` installs a handler for SIGINT/SIGTERM that restores the cursor before exiting
- Per-column state: head position, trail length, speed, timer, active flag
