#!/usr/bin/env bash
# MiBench on LVX: compiler performance tracking, with a correctness gate.
#
#   ./harness/run.sh                      # lvx-2, -O2, run + measure
#   ARCH=lvx-1 OPT=3 ./harness/run.sh
#   STATIC_ONLY=1 ./harness/run.sh        # build + static metrics, no ISS
#   ONLY='sha fft' ./harness/run.sh       # a subset
#
# Writes one TSV row per benchmark to results/<arch>-O<opt>-<date>.tsv and a
# human summary to stdout.  Compare two runs with harness/compare.sh.
#
# WHY CYCLES AND NOT TIME.  The ISS is deterministic: the same ELF yields the
# same cycle count every run, on any host, with no quiet-machine ritual and no
# averaging.  That makes it a better instrument for tracking a compiler than
# real hardware.  Three dynamic numbers come from gem5's own stats.txt:
#
#   numCycles   the figure to track
#   simInsts    BUNDLES, not instructions -- gem5 counts one bundle as one
#               "instruction" on this VLIW, so cycles/simInsts is the
#               execution-weighted packing density, which is exactly what a
#               scheduling or bundling change moves
#   simTicks    ticks, 1000 per cycle here; kept only to catch a clock change
#
# and three static ones, which cost nothing and are immune to the ISS being too
# slow for a benchmark: .text size, instruction count, static bundle count.
#
# WHY THE OUTPUT IS DIFFED.  A miscompile can look like a large speed-up.  Two
# benchmarks here -- crc32 and susan -- print usage and exit(0) when their
# arguments are missing, so an exit-code-only harness scores them as passes and
# their cycle counts as spectacular wins.  Every run is therefore checked
# against upstream's reference output where one exists, and a row whose
# correctness column is not `ok' must not be read as a performance result.
#
# KNOWN-INEXACT comparisons, both documented in reference-output/REFERENCE.md:
#   basicmath  6 lines of 19,731 differ by 1 ulp.  LVX agrees with a modern
#              x86-64 bit-for-bit; the 2001 x87 reference is the outlier.  So
#              the column reports `fp-1ulp' rather than failing.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
CSW="$(cd "$repo/.." && pwd)"

ARCH=${ARCH:-lvx-2}
OPT=${OPT:-2}
core=${ARCH#lvx-}
STATIC_ONLY=${STATIC_ONLY:-0}
ONLY=${ONLY:-}
TIMEOUT=${TIMEOUT:-5400}

TOOLS=${LVX_TOOLS:-$CSW/lvx-toolchain/bin}
GCC=$TOOLS/lvx-mbr-gcc
OBJDUMP=$TOOLS/lvx-mbr-objdump
SIZE=$TOOLS/lvx-mbr-size
GEM5=${GEM5:-$CSW/lvx-gem5/build/gem5-lvx$core.opt}
GEM5_CFG=${GEM5_CFG:-$CSW/lvx-gem5/tests/lvx/run_lvx.py}
LDSCRIPTS=${LDSCRIPTS:-$CSW/lvx-newlib/libgloss/lvx-mbr/linker_scripts}

# -std=gnu89 -fpermissive is not optional: MiBench is 1990s C and GCC 17
# rejects implicit declarations, implicit int and return-type mismatches by
# default.  Without these flags 11 of 18 targets fail to compile, which says
# nothing about LVX.  -T lvx-sim.ld supplies sbrk's _heap_start/_heap_end;
# without it a hosted link leaves them undefined and malloc has no heap.
CFLAGS="-O$OPT -march=$ARCH -std=gnu89 -fpermissive -ffreestanding -fno-strict-aliasing"
LDFLAGS="-T lvx-sim.ld -L$LDSCRIPTS -lm"

for t in "$GCC" "$OBJDUMP" "$SIZE"; do
    [ -x "$t" ] || { echo "missing tool: $t" >&2; exit 2; }
done
if [ "$STATIC_ONLY" != 1 ]; then
    [ -x "$GEM5" ] || { echo "missing ISS: $GEM5 (build-cores.sh)" >&2; exit 2; }
fi

stamp=$(date +%Y-%m-%d)
outdir="$repo/results"; mkdir -p "$outdir"
tsv="$outdir/$ARCH-O$OPT-$stamp.tsv"
work=$(mktemp -d); trap 'rm -rf "$work"' 0 1 2 3 15

HEADER='benchmark\tarch\topt\tcorrect\tcycles\tbundles_dyn\ttext_bytes\tinsns_static\tbundles_static'

# Rows are collected here and merged into $tsv at the end.  Writing $tsv
# directly would make an ONLY= run DESTROY a full baseline: the file is named
# by arch, opt and date only, so a one-benchmark re-run opens the same path and
# truncates it.  That happened on 2026-10-09 -- `ONLY=bitcnts' wiped a complete
# 13-row lvx-2 baseline taken an hour before, and the numbers compared against
# it were no longer reproducible from the tree.  Merging instead makes the
# re-run do the useful thing: replace that benchmark's row, keep the rest.
rows="$work/rows.tsv"; : > "$rows"
printf '%-18s %-9s %12s %12s %10s %9s\n' BENCHMARK CORRECT CYCLES BUNDLES_DYN TEXT INSNS

while IFS='|' read -r name dir srcs args stdin ref; do
    case "$name" in ''|\#*) continue ;; esac
    name=$(echo "$name" | xargs); dir=$(echo "$dir" | xargs)
    srcs=$(echo "$srcs" | xargs);  args=$(echo "$args" | xargs)
    stdin=$(echo "$stdin" | xargs); ref=$(echo "$ref" | xargs)
    [ -n "$ONLY" ] && ! grep -qw "$name" <<<"$ONLY" && continue

    # --- build, out of tree, so the source stays pristine
    bdir="$work/$name"; mkdir -p "$bdir"
    ( cd "$repo/$dir" && $GCC $CFLAGS -I. $srcs $LDFLAGS -o "$bdir/$name.elf" ) \
        > "$bdir/build.log" 2>&1
    if [ ! -f "$bdir/$name.elf" ]; then
        printf '%-18s %-9s %12s %12s %10s %9s\n' "$name" BUILDFAIL - - - -
        printf '%s\t%s\t%s\tbuildfail\t\t\t\t\t\n' "$name" "$ARCH" "$OPT" >> "$rows"
        continue
    fi

    # --- static metrics: free, and defined even when the ISS is too slow
    text=$($SIZE -A "$bdir/$name.elf" | awk '$1==".text"{print $2}')
    dis="$bdir/dis.txt"; $OBJDUMP -d "$bdir/$name.elf" > "$dis" 2>/dev/null
    insns=$(grep -cE '^\s+[0-9a-f]+:' "$dis")
    sbundles=$(grep -c ';;' "$dis")

    if [ "$STATIC_ONLY" = 1 ]; then
        printf '%-18s %-9s %12s %12s %10s %9s\n' "$name" static - - "$text" "$insns"
        printf '%s\t%s\t%s\tstatic\t\t\t%s\t%s\t%s\n' \
               "$name" "$ARCH" "$OPT" "$text" "$insns" "$sbundles" >> "$rows"
        continue
    fi

    # --- run in a scratch copy: these benchmarks write beside their inputs
    rdir="$bdir/run"; mkdir -p "$rdir"
    cp -a "$repo/$dir/." "$rdir/" 2>/dev/null || true
    [ "$name" = crc32 ] && cp "$repo/telecomm/adpcm/data/small.pcm" "$rdir/" 2>/dev/null
    runargs=(); [ "$args" != "-" ] && read -ra runargs <<<"$args"

    # stdin MUST be redirected even when the benchmark wants none.  gem5 shares
    # our stdin, and ours is benchmarks.def being read by the while-loop around
    # this -- so without a redirect the guest consumes the rest of the table,
    # takes it as its input, and the loop ends early.  That cost a debugging
    # round: adpcm read the .def file as PCM and the run stopped after it.
    gin=/dev/null
    [ "$stdin" != "-" ] && gin="$repo/$stdin"
    ( cd "$rdir" && timeout "$TIMEOUT" "$GEM5" --outdir=m5out "$GEM5_CFG" \
             "$bdir/$name.elf" "${runargs[@]}" < "$gin" ) \
        > "$bdir/run.log" 2> "$bdir/gem5.log"
    rc=$?

    # The two streams must be kept apart, not merged with 2>&1.  gem5's own
    # info/warn go to stderr -- including "Increasing stack size by one page",
    # which it emits repeatedly mid-run -- while stdout carries only its banner
    # and the guest's bytes.  Merging them interleaves diagnostics into the
    # guest's output and no positional extraction can survive it.
    #
    # LVX's syscalls bypass gem5's FDArray (se_workload.hh: scall is handled in
    # the runtime shim), so process.output cannot redirect the guest instead.
    # See harness/guest-output.py.
    python3 "$here/guest-output.py" "$bdir/run.log" "$bdir/got.txt" 2>/dev/null

    stats="$rdir/m5out/stats.txt"
    cycles=$(awk '$1=="system.cpu.numCycles"{print $2}' "$stats" 2>/dev/null)
    dynb=$(awk '$1=="simInsts"{print $2}' "$stats" 2>/dev/null)
    # -a: a binary guest output (adpcm) makes the log binary, and plain grep
    # then prints "binary file matches" and no match, which read as a failed run.
    exited=$(grep -aoE 'code=-?[0-9]+' "$bdir/run.log" | tail -1)

    # --- correctness.  gem5 prints its banner on stdout, so the guest's own
    # output is whatever follows the "beginning execution" line.
    correct=unchecked
    if [ "$rc" -eq 124 ]; then
        correct=timeout
    elif [ "$exited" != "code=0" ]; then
        correct="exit${exited#code=}"
    elif [ "$ref" != "-" ]; then
        # Benchmarks that write a named file (susan, rijndael) are compared on
        # that file; the rest on the guest's stdout.
        got="$bdir/got.txt"
        [ -f "$rdir/output.pgm" ] && got="$rdir/output.pgm"
        [ -f "$rdir/output.enc" ] && got="$rdir/output.enc"
        if cmp -s "$repo/reference-output/$ref" "$got"; then
            correct=ok
        elif grep -qI . "$repo/reference-output/$ref" 2>/dev/null \
             && diff -q <(grep -v '^$' "$repo/reference-output/$ref") \
                        <(grep -v '^$' "$got") >/dev/null 2>&1; then
            # Text only -- grep -qI fails on a binary reference, where a
            # blank-line-insensitive compare would be meaningless.
            correct=ok-ws
        elif [ "$name" = basicmath_small ]; then
            n=$(diff <(grep -v '^$' "$repo/reference-output/$ref") \
                     <(grep -v '^$' "$got") | grep -c '^[<>]')
            correct="fp-$((n/2))ulp"
        else
            correct=MISMATCH
        fi
    else
        correct=noref
    fi

    printf '%-18s %-9s %12s %12s %10s %9s\n' \
           "$name" "$correct" "${cycles:-?}" "${dynb:-?}" "$text" "$insns"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
           "$name" "$ARCH" "$OPT" "$correct" "${cycles:-}" "${dynb:-}" \
           "$text" "$insns" "$sbundles" >> "$rows"
done < "$here/benchmarks.def"

# Merge: this run's rows win, rows for benchmarks it did not run are kept from
# whatever was already in $tsv, and the order follows benchmarks.def so two
# files always line up for compare.sh.
if [ -f "$tsv" ]; then
    awk -F'\t' 'NR==FNR { if (FNR>1) seen[$1]=1; next }
                 FNR>1 && !($1 in seen) { print }' "$rows" "$tsv" >> "$rows"
fi
{
    printf "$HEADER\n"
    # benchmarks.def order, then anything left (a row whose line was removed).
    awk -F'|' '/^[^#]/ && NF>1 { gsub(/ /,"",$1); if ($1!="") print $1 }' \
        "$here/benchmarks.def" |
    while read -r n; do
        awk -F'\t' -v n="$n" '$1==n' "$rows"
    done
    awk -F'|' '/^[^#]/ && NF>1 { gsub(/ /,"",$1); if ($1!="") print $1 }' \
        "$here/benchmarks.def" > "$work/known"
    awk -F'\t' 'NR==FNR { k[$1]=1; next } !($1 in k) { print }' \
        "$work/known" "$rows"
} > "$tsv.new" && mv "$tsv.new" "$tsv"

echo
echo "wrote $tsv"
