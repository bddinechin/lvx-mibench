# MiBench reference outputs

Upstream's expected output for each benchmark, downloaded **2026-10-09** from
<https://vhosts.eecs.umich.edu/mibench/output.html>. `CHECKSUMS.txt` holds the
SHA-256 of the five group tarballs as downloaded, so this import can be
re-verified against upstream.

Upstream's own note on them, which matters more than it sounds:

> The output for the benchmarks was generated using an x86 machine running
> Redhat Linux 7.2. This architecture is known to generate machine specific
> output for some of the benchmarks, especially for benchmarks that generate
> floating point numbers.

A 2001 Redhat 7.2 x86 is **32-bit**, and that is not only an FP caveat — see
*LP64* below.

## What is here, and what is not

Only the **small**-variant outputs, and only for the thirteen benchmarks that
compile for LVX (`docs`-less `consumer/`, `sphinx`, `ghostscript`, `ispell` and
`rsynth` are excluded because they do not build here). That is 19 files and
4 MB, against 83 MB for the full set.

Large-variant outputs are deliberately absent: the large datasets are not run on
this target. The five tarballs are re-downloadable with `CHECKSUMS.txt` to
verify them if that changes.

## What has been compared so far

Against the four benchmarks that run at shipped-small input (2026-10-09, lvx-2):

| benchmark | result |
|---|---|
| `office/stringsearch` | **identical** |
| `telecomm/adpcm` (`rawcaudio`) | **identical**, all 342,216 bytes |
| `automotive/basicmath` | 6 lines of 19,731 differ by 1 ulp — the reference is the outlier |
| `security/sha` | structurally different — LP64, see below |

The nine remaining benchmarks here have reference outputs but have not been
compared, because they need command-line arguments and the runs predate the
argv fix, or because the ISS cannot finish their shipped-small input in
reasonable time. `GAPS.md` has the details.

## Caveat 1: floating point — the reference is not authoritative

`basicmath_small` differs from the reference in 6 of 19,731 lines, each by 1 ulp
in the 12th decimal of `%.12f`. The values come from an accumulated sum,
`for (X = 0.0; X <= 2*PI + 1e-6; X += PI/180)`. Printing the bits alongside the
decimals shows **LVX and a current x86-64 glibc agreeing exactly** on all six:

```
deg= 97  %a=0x1.b16670e053653p+0  %.12f=1.692969374435   <- LVX and modern glibc
                                        1.692969374434   <- this reference
```

So LVX is right and the reference is the outlier. The likely cause is the era:
an i386 of that vintage accumulated in x87's 80-bit registers, which shifts a
long running sum. **Use a modern native build as the oracle for floating-point
benchmarks; use this reference for the integer ones.**

## Caveat 2: LP64 — `sha`'s reference cannot be matched as-is

This is a finding rather than something fixed here.

`security/sha`'s reference prints five **8**-hex-digit words:

```
320c22e9 7b1ed440 77d2e55a bbe2481a 2b24a55b
```

LVX prints five **16**-digit ones. The cause is in the benchmark: `sha.h` has
`typedef unsigned long LONG`, and the algorithm requires exactly 32 bits. On the
2001 32-bit host `unsigned long` *was* 32 bits, so the reference is a correct
SHA-0 digest. On **any LP64 target — LVX and modern x86-64 alike —**
`SHA_INFO.data` becomes 128 bytes where the code `memcpy`s 64 into it and
`data[14]`/`data[15]` land at the wrong offsets, so no LP64 build computes a
correct digest.

Demonstrated on the 3-byte input `"abc"`: with `LONG` made `unsigned int` *and*
`sha_print`'s five `%08lx` made `%08x` — both are needed, or the arguments
become varargs type mismatches — LVX, a modern native build and real SHA-0 agree
bit for bit:

```
0164b8a9 14cd2a5e 74c4f7ff 082c4d97 f1edf880
```

(MiBench's `sha` is SHA-0, the withdrawn original, not SHA-1.)

**Not corrected here, and no corrected reference is committed.** Doing it
properly means auditing each benchmark for 32-bit-width assumptions, not just
`sha` — `rijndael`, `blowfish` and `crc32` are 1990s code with the same
`unsigned long` habits and have *not* been checked — then carrying the fixes as
patches against the pristine import and regenerating the affected outputs. Until
that happens, `sha`'s reference here is the ILP32 answer and LVX cannot match it.
