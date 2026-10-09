# Running MiBench on LVX: the gaps, measured

Status 2026-10-09. Everything below was measured against the installed
toolchain and `gem5-lvx{1,2}.opt`, not inferred from reading code. Build probe:
18 targets from the eleven benchmarks that need no third-party library;
execution probe: the subset that built, under the ISS.

## Summary, in order of how much they block

| # | gap | where | blocks |
|---|---|---|---|
| 1 | **no `argv` reaches the guest** | `lvx-gem5` + `lvx-newlib` crt0 | most of MiBench |
| 2 | **no guest-visible time source** | `lvx-newlib` + `lvx-gem5` | all timing, and `bitcount` outright |
| 3 | **missing BSD/network headers** | `lvx-newlib` | `patricia` |
| 4 | legacy-C build flags needed | neither — the benchmarks | nothing, once known |

**The ISA is not a gap.** All 18 targets compile and link identically on lvx-1
and lvx-2 — the build-probe summaries are byte-identical between cores — and
`basicmath_small`, which is almost entirely `double` arithmetic (`sqrt`, `sin`,
`cos`, cubic roots), runs to completion in 61,347,468 cycles. Nothing in the
suite asked for an instruction the assembler could not provide, on either core.
The gaps are all runtime: the ISS, the C library, and the crt0 between them.

## 1. No `argv` reaches the guest

The decisive measurement — a three-line program:

```
$ lvx-mbr-gcc -O2 -march=lvx-2 -T lvx-sim.ld av.c -o av.elf
$ gem5-lvx2.opt run_lvx.py av.elf hello world
argc=0
```

Not "the extra arguments were dropped" — **`argc` is 0, so even `argv[0]` is
absent.** Two sides, deliberately matched:

- `LvxISA::Process::initState()` (`lvx-gem5/src/arch/lvx/process.cc`) sets up a
  stack pointer and one reserved page and stops. There is no `argsInit()`
  pushing argc/argv/envp/auxv, which is what `arch/{arm,riscv,x86,mips,sparc,
  power}/process.cc` all have.
- `lvx-newlib/libgloss/lvx-mbr/crt0.c` closes the loop on purpose:

  ```c
  /* The ISS passes no argument vector, so there is nothing to decode off the
     stack: main() gets an empty one.  */
  __start1 (0, (char **) 0, (char **) 0);
  ```

- and `lvx-gem5/tests/lvx/run_lvx.py` has `process.cmd = [elf]`, so it would
  pass nothing even if the other two ends worked.

**How it shows up** — and it is worth knowing because none of these looks like
an argv problem:

| benchmark | arguments it wants | observed |
|---|---|---|
| `basicmath_small` | none | **ok**, 61,347,468 cycles |
| `search_small` | none | **ok**, 248,001 cycles |
| `crc32` | a file | exit 0, **66,274 cycles, no output** — silently took its no-file path and did no work |
| `qsort_small` | a file | exit −1, 67,860 cycles |
| `fft` | two numbers | exit −1, 71,235 cycles |
| `rijndael` | in, out, mode, key | exit −1, 69,122 cycles |
| `dijkstra_small` | a file | **`fatal: readBlob(0x8, ...) failed`** — a NULL `argv[1]` dereference inside the ISS |

The correlation is exact: **every benchmark that takes no argument works, every
benchmark that takes one does not.** Hello-world costs 69,412 cycles on this
setup, so the ~67–71k figures above are programs exiting before doing anything.
`crc32` is the trap — it reports success.

**The work:** implement `argsInit()` for LVX against the LVX ABI, have `crt0.c`
decode argc/argv/envp off the stack instead of passing zeros, and change
`process.cmd` to `[elf] + sys.argv[2:]`. All three are needed; any one alone
changes nothing.

## 2. No guest-visible time source — the timing question

Two independent failures stacked on top of each other.

**(a) The libc side does not link.** `clock()`, `times()` and `gettimeofday()`
are all implemented in `libgloss/lvx-mbr`, and all three call helpers that
exist only as declarations:

```
$ lvx-mbr-gcc -O2 -march=lvx-2 -T lvx-sim.ld clock.c -o /dev/null
undefined reference to `__lvx_counter_num'       # times.c, hence clock()
undefined reference to `__lvx_cluster_timestamp' # gettimeofday.c, nanosleep.c
```

Declared in `newlib/libc/sys/mbr/include/mbr/lvx/{diagnostic,timestamp}.h`,
defined nowhere in the repository. Both cores. This is why `bitcount` is the one
benchmark that fails to *link*: `bitcnts.c` calls `clock()` around its kernel.

**(b) The ISS side returns zero.** The ISA has the right register —
`RegFile.yml`: `FRCC`, SRS 63, 64-bit, `GET`-readable, *"Free running cycle
counter"* — and `get $rN = $frcc` assembles, links and executes without a
panic. It just never counts:

```
frcc a=0 b=0 delta=0        # with 100000 loop iterations in between
== Exiting @ tick 470441000 (470441 cycles) ==
```

`$pm0` behaves the same (`pm0 0->0`), so neither the free-running counter nor
the performance monitors are modelled as counting. gem5 knows the cycle count —
it prints it on exit — but the guest cannot see it.

**The work:** define `__lvx_counter_num` and `__lvx_cluster_timestamp` over
`FRCC` (the frequencies they scale by are already in `mbr/lvx/cpu.h`:
`_LVX_CPU_FREQ` 800 MHz, `__LVX_CLOCKS_PER_SEC__` 10^6, `_LVX_TIMESTAMP_FREQ`
10^8), and make the ISS's `FRCC` read return the current cycle. Until the
second half is done the first half links but reports zero elapsed time, which is
worse than a link error because it looks like a measurement.

Note for whoever does this: a cycle counter that reads the simulated cycle is
*not* a wall clock, and MiBench divides by `CLOCKS_PER_SEC` to print seconds. On
an ISS the honest number is cycles; the seconds figure will be whatever
`_LVX_CPU_FREQ` claims. Prefer reporting cycles, and treat
`gem5`'s own exit line as the reference until `FRCC` agrees with it.

## 3. Missing BSD/network headers

`patricia` is the only build failure once the flags of §4 are applied:

```
patricia   COMPILE  fatal error: err.h: No such file or directory
```

and behind it `sys/socket.h`, `netinet/in.h`, `arpa/inet.h`, `rpc/rpc.h` — none
of which newlib ships. But `patricia_test.c` barely uses them: zero calls to the
`err`/`warn` family (the `err.h` include is dead), `inet_aton` is commented out,
`socket` appears only in that include line. What it actually needs is **`struct
in_addr` and `htonl`** — so a small `netinet/in.h` with the byte-order macros
and that one struct, plus a trivial `err.h`, closes it. The other three headers
are includes nothing reads.

## 4. Legacy-C build flags — not an LVX gap, but you need them

MiBench is 1990s C and GCC 17 rejects by default what was a warning then:
implicit function declarations, implicit `int`, return-type mismatches. On the
first probe 11 of 18 targets failed to compile for this reason alone. Adding

```
-std=gnu89 -fpermissive
```

takes the same 18 targets from 7 building to **16 building**, leaving only the
two real gaps above. Any modern compiler needs this; it says nothing about LVX.
Also note each benchmark's `Makefile` hardcodes `gcc -static`, so cross-building
means overriding the recipe rather than setting `CC`.

## What works today, and is worth knowing

- **File I/O works.** `fopen`/`fwrite`/`fread`/`fclose` round-trip correctly
  under gem5 SE mode — which matters, because nearly every MiBench benchmark
  reads an input file. The blocker is getting it the *name*, not reading it.
- **The hosted link works** with `-T lvx-sim.ld` from
  `libgloss/lvx-mbr/linker_scripts`; without it `_heap_start`/`_heap_end` are
  undefined and `malloc` has no heap. The DejaGnu boards already pass this.
- **`malloc`, `printf`, `libm`** all work: `basicmath_small` exercises all three
  for 61M cycles.

## Reproducing

The probe scripts are not committed; they are three loops over
`lvx-mbr-gcc -O2 -march=$ARCH -std=gnu89 -fpermissive -I. -T lvx-sim.ld
-L<libgloss>/linker_scripts <sources> -lm` and
`gem5-lvx$N.opt run_lvx.py <elf> <args>`. The per-benchmark source lists come
from each `Makefile`'s `gcc` recipe. Worth turning into a harness beside
`validation/run.sh` once §1 and §2 land — before that, a harness could only run
the two no-argument benchmarks.
