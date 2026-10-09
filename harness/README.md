# MiBench as a compiler-performance tracker for LVX

```bash
./harness/run.sh                        # lvx-2, -O2: build, run, measure, check
ARCH=lvx-1 OPT=3 ./harness/run.sh
STATIC_ONLY=1 ./harness/run.sh          # build + static metrics only, minutes
ONLY='sha fft' ./harness/run.sh         # a subset
./harness/compare.sh results/A.tsv results/B.tsv
```

Results land in `results/<arch>-O<opt>-<date>.tsv`, one row per benchmark.
Commit them: the series is the point, and `compare.sh` diffs two of them.

## Why cycles, not time

The ISS is **deterministic** — the same ELF gives the same cycle count every
run, on any host, with no quiet machine and no averaging. That makes it a
better instrument for tracking a compiler than real hardware. Six metrics per
benchmark, three dynamic and three static:

| metric | from | what moves it |
|---|---|---|
| `cycles` | gem5 `system.cpu.numCycles` | the headline number |
| `bundles_dyn` | gem5 `simInsts` | gem5 counts one **bundle** as one "instruction" on this VLIW, so `cycles / bundles_dyn` is the execution-weighted packing density — exactly what scheduling and bundling changes move |
| `text_bytes` | `lvx-mbr-size` | code size |
| `insns_static` | `objdump -d` | instruction count |
| `bundles_static` | `;;` count in the disassembly | static packing |

The static three cost nothing and are defined even for benchmarks the ISS
cannot finish, so a regression in code size or packing is caught for all
thirteen regardless of runtime.

## Why every run is diffed against a reference

**A miscompile can look like a large speed-up.** `crc32` and `susan` print
usage and `exit(0)` when their arguments are missing, so an exit-code-only
harness scores them as passes *and* records their cycle counts as spectacular
wins. Every run is therefore checked against `reference-output/`, and a row
whose `correct` column is not `ok` is not a performance result.

Values in that column:

| value | meaning |
|---|---|
| `ok` | byte-identical to upstream's reference |
| `ok-ws` | identical ignoring blank lines (text references only) |
| `fp-Nulp` | `basicmath` only: N lines differ by 1 ulp. **LVX is right** — it agrees with a modern x86-64 bit-for-bit; the 2001 x87 reference is the outlier. See `reference-output/REFERENCE.md`. Expect `fp-6ulp` |
| `noref` | upstream ships no reference for this invocation (`crc32`, `fft`, `rijndael_enc`), or the output is not comparable to one (`bitcnts`, which prints its own elapsed times) — metrics only |
| `MISMATCH` | a real failure. Investigate before reading any number in the row |
| `exitN`, `timeout`, `buildfail` | did not complete |

## Three traps this harness had to be built around

Each cost a debugging round and each is easy to reintroduce.

**gem5's stdout and stderr must not be merged.** gem5's `info:`/`warn:` go to
stderr — including `Increasing stack size by one page`, emitted repeatedly
*mid-run* — while stdout carries only its banner and the guest's bytes. A
`2>&1` interleaves diagnostics into the guest's output and no extraction can
recover it.

**gem5's own redirection cannot separate them instead.** `process.output` has
no effect, because LVX's syscalls are implemented inline in the runtime shim
and bypass gem5's `SyscallDesc` table and its `FDArray` entirely
(`lvx-gem5/src/arch/lvx/se_workload.hh`). Hence `guest-output.py`, which cuts
the guest's bytes out positionally. If `scall` is ever routed through
`SyscallDesc`, that script becomes unnecessary.

**The guest's stdin must always be redirected**, even for a benchmark that
reads none. gem5 inherits the harness's stdin, and the harness's stdin is
`benchmarks.def` being read by the loop — so without `< /dev/null` the guest
eats the rest of the table and the run stops early. It presented as `adpcm`
reading the benchmark table as PCM.

## `bitcnts` prints seconds, and they are simulated

`bitcount` is the one benchmark whose timing path exercises `$frcc`, and it
reports the elapsed time of each of its seven kernels. Those numbers are
cycles rescaled by `_LVX_CPU_FREQ`, which is 1 GHz and must stay equal to the
ISS clock domain (`run_lvx.py`'s `SrcClockDomain(clock="1GHz")`) — they are
exact *simulated* time, never wall-clock, and they move if either constant
does. So its row is `noref`: track its metrics, not its printout. The two
constants disagreed (800 MHz against 1 GHz) until 2026-10-09, which is
`GAPS.md` §2.

## Adding a benchmark

One line in `benchmarks.def`:

```
name | dir | sources | args | stdin | reference-output
```

`args` are relative to the benchmark's directory, which the runner copies to a
scratch dir first (these benchmarks write their output beside their inputs, so
they must not run in the source tree). `stdin` is repo-relative, because
`adpcm`'s data sits a level above its sources. `-` means none.

`-std=gnu89 -fpermissive` is not optional: MiBench is 1990s C and GCC 17
rejects implicit declarations, implicit `int` and return-type mismatches by
default. Without them 11 of 18 targets fail to compile, which says nothing
about LVX.

## What is not here yet

- **`patricia`** needs `err.h` and `netinet/in.h`, which newlib does not ship,
  though it uses only `struct in_addr` and `htonl`. `GAPS.md` §3.
- **Large datasets are never run** — not a limitation of the harness but a
  decision: the atomic CPU cannot finish them. Two *small* invocations are also
  reduced, and both are marked in `benchmarks.def` with the published size they
  deviate from, so neither is mistaken for a comparable MiBench figure.
- **A tiny input tier.** The slowest rows here are tens of minutes; `qsort` at
  its shipped 10,000 lines extrapolates to ~17 M cycles, about 20 minutes. If
  the suite needs to run per-commit rather than nightly, committed `input_tiny.*`
  files sized to 10–100 M cycles are the way, with the generating command
  recorded beside them.
