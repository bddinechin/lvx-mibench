# Running MiBench on LVX: the gaps, measured

Status 2026-10-09. Everything below was measured against the installed
toolchain and `gem5-lvx{1,2}.opt`, not inferred from reading code. Build probe:
18 targets from the eleven benchmarks that need no third-party library;
execution probe: the subset that built, under the ISS.

## Summary, in order of how much they block

| # | gap | where | blocks |
|---|---|---|---|
| 1 | ~~no `argv` reaches the guest~~ | **FIXED 2026-10-09** | — |
| 1b | ~~`strtol`/`atoi` returns `LONG_MAX`~~ | **FIXED 2026-10-09** — stale objects | — |
| 2 | **no guest-visible time source** | `lvx-newlib` + `lvx-gem5` | all timing, and `bitcount` outright |
| 3 | **missing BSD/network headers** | `lvx-newlib` | `patricia` |
| 4 | **newlib does not leak `LITTLE_ENDIAN`** | `lvx-newlib` vs glibc | `sha` — *silently wrong output* |
| 5 | legacy-C build flags needed | neither — the benchmarks | nothing, once known |

**The ISA is not a gap.** All 18 targets compile and link identically on lvx-1
and lvx-2 — the build-probe summaries are byte-identical between cores — and
`basicmath_small`, which is almost entirely `double` arithmetic (`sqrt`, `sin`,
`cos`, cubic roots), runs to completion in 61,347,468 cycles on its shipped
small input. Nothing in the
suite asked for an instruction the assembler could not provide, on either core.
The gaps are all runtime: the ISS, the C library, and the crt0 between them.

## 1. No `argv` reaches the guest — FIXED 2026-10-09

**Fixed** in lvx-gem5 `86f2a4c27b` (`Process::argsInit` builds the System V
block; `run_lvx.py` passes the guest's arguments) and lvx-newlib `4af017d`
(`_start` captures `$r12` into `$r0` before the tail jump, and `__start0`
decodes argc/argv/envp off it). `argc=4` for three arguments on both cores,
quoted arguments intact, `argc=1` and a valid `envp` with none, and the stack
pointer `main` sees is 0 mod 32. validation 55/55 both cores at -O0/-O2/-O3 and
run_diff.sh 96/96 — the regression that mattered, since the stack layout moved.

The description below is kept because it is what the symptoms looked like, and
because the next person to see `fatal: readBlob(0x8, ...)` should recognise it.

### 1b. `strtol`/`atoi` can return `LONG_MAX` — found behind the argv fix

With arguments arriving, `fft 4 16` got as far as parsing them and then died
`fatal: writeBlob(0, ...)`. Instrumented, the cause is that `atoi("16")`
returned −1 and `MAXSIZE` became 4294967295, so `malloc(4 * 4294967295)` gave
NULL and FFT — which checks none of its six `malloc`s — wrote through it.

The underlying fault is `strtol` reporting overflow on values that do not
overflow. It is **not** a clean value rule, which is what makes it interesting:

```
program whose first libc call is atoi:   strtol("16")   = 9223372036854775807
program that printf's first:             strtol("16")   = 16
                                         strtol("4096") = 9223372036854775807
                                         strtol("2147483647") = 9223372036854775807
```

`LONG_MAX` is the saturated return `strtol` gives on `ERANGE`, and `atoi` is
`(int)` of it, hence −1. Same on lvx-1 and lvx-2, same at `-O0` and `-O2`, so
not an optimiser artefact. The dependence on what ran before it points at
uninitialised state rather than arithmetic — and 64-bit division is fine
(`LONG_MAX/10` and `LONG_MAX%10` both print correctly), which rules out the
obvious suspect in `strtol`'s cutoff computation.

**It is pre-existing, not a consequence of the argv change.** Verified by
checking out the previous `crt0.c`, rebuilding newlib, confirming `_start` is
again the bare `goto`, and re-running: byte-identical wrong answers. (A first
attempt to verify this was invalid — `git stash push` on an
already-committed file stashes nothing, so both runs used the new crt0.
Check that the file actually changed.)

**Cause: the installed newlib was stale.** `libc_a-strtol.o` dated 2026-09-28
— eleven days old — and so did **3124 of the build tree's 3241 objects**.
Newlib's build depends on its sources, not on the compiler, so an unchanged
`strtol.c` keeps whatever object an earlier lvx-gcc produced, and every
compiler fix since is absent from libc. Recompiling that one file from the same
source with the same flags gave the right answer, which is the test that tells a
stale object from a live miscompile and should be the first thing tried when a
libc function misbehaves.

Fixed by forcing a full rebuild — `find . -name '*.o' -delete`, same for
`*.a`, then `make && make install` — after which `strtol("4096")` is 4096 and
`atoi` is correct on both cores, with validation 55/55 and run_diff.sh 96/96
unchanged. Recorded in the top-level `README.md` under `lvx-newlib`, because
`make` will not do it and nothing diagnoses it: the library builds, links and
mostly works.

Worth knowing about the symptom, since it misled this investigation for a
while: it looked like uninitialised memory. The same call succeeded or failed
depending on what had run before it, because the surrounding data differed.
Four hypotheses were tested and rejected first — runtime 64-bit division
(correct), `isspace`/`isdigit` classification (correct), a hand-written replica
of newlib's exact algorithm (correct), and the digit scan itself (`endptr`
showed exactly 4 characters consumed, so only the overflow test was wrong).

## 1a. What the argv gap looked like

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

All at *small* inputs, and the cycle figures are only meaningful for the two
rows that did real work — the rest never reached their data, which is the point
of the table.

| benchmark | arguments it wants | observed |
|---|---|---|
| `basicmath_small` | none | **ok**, 61,347,468 cycles — shipped small |
| `search_small` | none | **ok**, 248,001 cycles — shipped small |
| `adpcm_rawcaudio` | none (stdin) | **ok**, 42,554,668 cycles on `data/small.pcm` — real work |
| `crc32` | a file | exit 0, **66,274 cycles, no output** — took its no-file path and did no work. (Its `runme_small.sh` wants the 25 MB *large* pcm; MiBench ships it no small input.) |
| `qsort_small` | a file | exit −1, 67,860 cycles |
| `fft` | two numbers | exit −1, 71,235 cycles |
| `rijndael` | in, out, mode, key | exit −1, 69,122 cycles |
| `dijkstra_small` | a file | **`fatal: readBlob(0x8, ...) failed`** — a NULL `argv[1]` dereference inside the ISS |
| `susan` | file, file, flag | exit 0, 79,800 cycles, **no work** — printed usage and `exit(0)` |
| `sha` | a file | **hung** to the 30-minute timeout: with `argc < 2` it falls back to `stdin`, which was not redirected |

The correlation is exact: **every benchmark that takes no argument works, every
benchmark that takes one does not.** Hello-world costs 69,412 cycles on this
setup, so the ~67–71k figures above are programs exiting before doing anything.
`crc32` is the trap — it reports success.

**The work:** implement `argsInit()` for LVX against the LVX ABI, have `crt0.c`
decode argc/argv/envp off the stack instead of passing zeros, and change
`process.cmd` to `[elf] + sys.argv[2:]`. All three are needed; any one alone
changes nothing.

**There is a workaround, and it is worth knowing: `stdin` works.**
`adpcm_rawcaudio` reads stdin and takes no argument, and it runs a full workload
— 42,554,668 cycles on `small.pcm`. So does `sha`, which falls back to `stdin`
when `argc < 2`: fed `input_small.asc` that way it produces a digest in
12,848,200 cycles. Any benchmark that accepts a stream on stdin can be run
today. That is `adpcm` (both directions) and `sha`; the rest want filenames.

**Two benchmarks report success while doing nothing** — `crc32` and `susan`
both take their usage path and `exit(0)`. A harness that checks only the exit
code will score them as passes. Check the output, or the cycle count against
hello-world's ~69,400.

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

## 4. newlib does not define `LITTLE_ENDIAN`, and `sha` goes silently wrong

This one produces a **wrong answer rather than a diagnostic**, which makes it
the most dangerous of the five.

`security/sha` byte-reverses its input words under `#ifdef LITTLE_ENDIAN`.
Compiled with exactly `sha.c`'s own includes — `stdlib.h`, `stdio.h`,
`string.h`, nothing else:

```
native/glibc: LITTLE_ENDIAN defined     -> sha.c DOES byte-reverse
LVX/newlib:   LITTLE_ENDIAN not defined -> sha.c does NOT byte-reverse
```

glibc leaks the macro through `<stdlib.h>`; newlib does not. So the same source
computes two different digests on the two libcs, with no warning from either.

**`sha` needs a second fix before it means anything, and this one is the
benchmark's fault:** `sha.h` has `typedef unsigned long LONG`, and the
algorithm requires exactly 32 bits. On LP64 — which is every target here,
including native x86-64 — `SHA_INFO.data` becomes 128 bytes where the code
memcpy's 64 into it, and `data[14]`/`data[15]` land at the wrong offsets. No
LP64 build of MiBench's `sha` computes a correct digest.

With both fixed — `LONG` made `unsigned int`, its `%08lx` prints made `%08x`,
and `-DLITTLE_ENDIAN` added — all three agree exactly:

```
LVX-2 (-DLITTLE_ENDIAN): 0164b8a9 14cd2a5e 74c4f7ff 082c4d97 f1edf880
native                 : 0164b8a9 14cd2a5e 74c4f7ff 082c4d97 f1edf880
real SHA-0("abc")      : 0164b8a9 14cd2a5e 74c4f7ff 082c4d97 f1edf880
```

(MiBench's `sha` is SHA-0, the withdrawn original, not SHA-1.)

**So LVX's code generation is correct here, and that is the useful half of the
result.** The wrong digest was reproducible at `-O0`, `-O1`, `-O2` and `-O3` on
both cores, which is the shape of an environment difference rather than an
optimiser bug — and it was. Worth recording how nearly it looked otherwise:
mid-investigation this was a suspected miscompile, and the two experiments that
seemed to rule out endianness were both invalid. `nm` showed no `byte_reverse`
in either object, but it is `static` and inlined, so `nm` cannot see it; and a
`LITTLE_ENDIAN` probe that `#include`d `<sys/types.h>` reported "defined" on
both, because newlib *does* define it there — just not in the three headers
`sha.c` actually includes. Reproduce the translation unit, not an approximation
of it.

**The work:** decide whether newlib should define `LITTLE_ENDIAN`/`BYTE_ORDER`
more widely (glibc-compatible, and this is what a port of 1990s code will
expect) or whether the harness should pass `-DLITTLE_ENDIAN`. The former is a
newlib change with wider consequences; the latter is one flag, per benchmark
that needs it, and has to be remembered. Either way the benchmark's `LONG` must
be fixed for the output to mean anything at all.

## 5. Legacy-C build flags — not an LVX gap, but you need them

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
- **`stdin` works**, including redirection from a file under the ISS harness —
  see the workaround in §1.
- **Code generation is correct** on everything reached so far. The one
  wrong-answer found (§4) was an environment difference, and LVX matches native
  bit-for-bit once the benchmark is made portable.

## Benchmarks that run a real workload today — and on which input

**Small only. No Large variant has ever been executed here**, though
`basicmath_large`, `qsort_large`, `dijkstra_large` and `search_large` all
compile and link. And two of the small runs below used an input *smaller* than
the one `runme_small.sh` names, because the atomic CPU model could not finish
the shipped one — so read the cycle counts as "this input, this core", never as
a MiBench score.

| benchmark | core | input actually used | as shipped? | cycles |
|---|---|---|---|---|
| `basicmath_small` | lvx-2 | none (self-generated) | **yes** | 61,347,468 |
| `adpcm_rawcaudio` | lvx-2 | `stdin` < `data/small.pcm`, 1,368,864 B | **yes** | 42,554,668 |
| `sha` | lvx-2 | `stdin` < `input_small.asc`, 311,824 B | **yes** | 12,848,200 |
| `search_small` | lvx-2 | none (strings compiled in) | **yes** | 248,001 |
| `qsort_small` | lvx-2 | `head -200 input_small.dat` | **no** — 200 of 10,000 lines | — |
| `fft` | lvx-2 | `4 16` | **no** — `runme_small.sh` says `4 4096` | — |

The two reductions were deliberate and prove different things. `qsort_small`
was trimmed to show that `argv` reached it and the named file opened, which a
200-line sort establishes in minutes where 10,000 lines takes hours. `fft 4
4096` — the real small size — **was killed at 90 minutes**; `4 16` is 256x less
work and was run only to compare its output against native, which is how the
`rand()` divergence below was found.

Two traps in MiBench's own scripts, not substitutions of mine:

- **`crc32`'s `runme_small.sh` uses the LARGE input**: `crc ../adpcm/data/large.pcm`,
  25 MB. There is no small input for it. The 66,274-cycle figure in §1a is it
  doing nothing, not a measurement.
- `sha`'s small input is 312 KB, which is already 12.8 M cycles; its large one
  is 3.1 MB.

So: four of eighteen run a real workload, `sha`'s output is wrong until §4 is
addressed, and the suite is **not** runnable at shipped-small size wholesale on
the atomic CPU. That is a throughput limit rather than a gap, and it is the
prerequisite for any timing comparison: a faster CPU model, or MiBench's own
reduced inputs. Everything else waits on §1.

## Reproducing

The probe scripts are not committed; they are three loops over
`lvx-mbr-gcc -O2 -march=$ARCH -std=gnu89 -fpermissive -I. -T lvx-sim.ld
-L<libgloss>/linker_scripts <sources> -lm` and
`gem5-lvx$N.opt run_lvx.py <elf> <args>`. The per-benchmark source lists come
from each `Makefile`'s `gcc` recipe. Worth turning into a harness beside
`validation/run.sh` once §1 and §2 land — before that, a harness could only run
the two no-argument benchmarks.

## `fft` is not a cross-libc oracle, and neither is anything using `rand()`

`fft` builds its input from `srand(1)` and `rand()`, and the two libcs do not
agree on the sequence:

```
glibc  rand()%1000: 383 886 777 915 793 335
newlib rand()%1000: 933 743 262 529 700 508
```

So `fft`'s output differs from a native build by design, and the difference says
nothing about LVX. Compare it against another newlib run, or feed it a
deterministic input. Checked after the stale-newlib fix, when `fft 4 16` first
ran to completion and its numbers did not match native — the second time in this
exercise that a cross-libc comparison looked like a miscompile and was not
(`sha` and `LITTLE_ENDIAN` was the first).
