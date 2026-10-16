#!/usr/bin/env bash
# MiBench on LVX: compiler performance tracking, with a correctness gate.
#
#   ./harness/run.sh                      # lvx-2, -O2, run + measure
#   ARCH=lvx-1 OPT=3 ./harness/run.sh
#   STATIC_ONLY=1 ./harness/run.sh        # build + static metrics, no ISS
#   ONLY='sha fft' ./harness/run.sh       # a subset
#   COMPILER=clang ./harness/run.sh       # lvx-llvm instead of lvx-gcc
#
# Writes one TSV row per benchmark to results/<arch>-O<opt>-<date>.tsv and a
# human summary to stdout.  Compare two runs with harness/compare.sh.
#
# COMPILER=clang writes results/<arch>-clang-O<opt>-<date>.tsv instead: the
# compiler is part of the configuration name, because a GCC row and a clang row
# of one benchmark are two series, not two samples of one.  GCC stays unmarked
# so the series that predates clang keeps its name.
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
# --- Locating lvx-csw ------------------------------------------------------
#
# This benchmark measures a toolchain that is a BUILD PRODUCT of a *built*
# lvx-csw checkout: lvx-toolchain/bin and lvx-gem5/build are in nobody's git.
# So lvx-csw's location is a PARAMETER of this harness, never an assumption.
#
# It used to be "$repo/..", which held only while this repository was a
# submodule of lvx-csw. It is a submodule of lvx-perf now, so that guess
# resolved to lvx-perf -- which has no toolchain in it at all.
#
# Precedence, highest first:
#   --csw <path>                explicit, for a one-off or a CI job
#   $LVX_CSW                    environment, for a shell session
#   <lvx-perf>/lvx-csw.path     one line, per machine, not committed
#   <lvx-perf>/../lvx-csw       the default: the two checkouts as siblings
#   <this repo>/../lvx-csw      same idea, for a standalone clone
#
# A path given explicitly is never silently replaced by a fallback: name a
# tree and get told which mechanism named it, rather than measuring another
# checkout's compiler by accident.

csw_from=
csw_path=
_rest=()
while [ $# -gt 0 ]; do
    case "$1" in
        --csw)   [ $# -ge 2 ] || { echo "--csw needs a path" >&2; exit 2; }
                 csw_path=$2; csw_from='--csw'; shift 2 ;;
        --csw=*) csw_path=${1#--csw=}; csw_from='--csw'; shift ;;
        *)       _rest+=("$1"); shift ;;
    esac
done
set -- ${_rest[@]+"${_rest[@]}"}

_super=$(git -C "$repo" rev-parse --show-superproject-working-tree 2>/dev/null) || _super=
[ -n "${_super:-}" ] || _super=

if [ -z "$csw_path" ] && [ -n "${LVX_CSW:-}" ]; then
    csw_path=$LVX_CSW; csw_from='$LVX_CSW'
fi
if [ -z "$csw_path" ] && [ -n "$_super" ] && [ -r "$_super/lvx-csw.path" ]; then
    # One path per file, '#' comments allowed; a relative path is relative to
    # lvx-perf, so a committed-by-accident file still means the same thing.
    csw_path=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$_super/lvx-csw.path" \
               | grep -v '^[[:space:]]*$' | head -1)
    if [ -n "$csw_path" ]; then
        csw_from="$_super/lvx-csw.path"
        case $csw_path in /*) ;; *) csw_path=$_super/$csw_path ;; esac
    fi
fi
if [ -z "$csw_path" ]; then
    for _c in ${_super:+"$_super/../lvx-csw"} "$repo/../lvx-csw"; do
        if [ -d "$_c/lvx-mds" ] || [ -d "$_c/validation" ]; then
            csw_path=$_c; csw_from='default sibling'; break
        fi
    done
fi

if [ -z "$csw_path" ]; then
    _hint=${_super:-<lvx-perf>}
    cat >&2 <<EOM
error: cannot find lvx-csw, and this benchmark cannot run without it: it
       measures the toolchain that lvx-csw builds.

Name a location -- highest precedence first:
    $(basename "$0") --csw /path/to/lvx-csw
    LVX_CSW=/path/to/lvx-csw $(basename "$0")
    echo /path/to/lvx-csw > $_hint/lvx-csw.path
or put the two checkouts side by side, which is the default:
    $_hint/../lvx-csw
EOM
    exit 2
fi

[ -d "$csw_path" ] || {
    echo "error: lvx-csw path does not exist: $csw_path  (from $csw_from)" >&2
    exit 2
}
CSW=$(cd "$csw_path" && pwd)
if [ ! -d "$CSW/lvx-mds" ] && [ ! -d "$CSW/validation" ]; then
    echo "error: $CSW does not look like an lvx-csw checkout  (from $csw_from)" >&2
    echo "       expected lvx-mds/ and validation/ inside it" >&2
    exit 2
fi
# lvx-toolchain/ is a build product and is not versioned, so "there but not
# built" is the ordinary failure here, not a broken tree. Say which it is.
if [ -z "${LVX_TOOLS:-}" ] && [ ! -x "$CSW/lvx-toolchain/bin/lvx-mbr-gcc" ]; then
    echo "error: $CSW has no built cross-toolchain  (from $csw_from)" >&2
    echo "       expected lvx-toolchain/bin/lvx-mbr-gcc" >&2
    echo "       build it:  make -C '$CSW' install-minimal-toolchain" >&2
    echo "       or point past it:  LVX_TOOLS=<dir>" >&2
    exit 2
fi
# Children and recursive invocations inherit the decision rather than redoing
# it -- a child must not re-resolve to a different tree midway.
export LVX_CSW="$CSW"
# --- end locating lvx-csw --------------------------------------------------

ARCH=${ARCH:-lvx-2}
OPT=${OPT:-2}
core=${ARCH#lvx-}
STATIC_ONLY=${STATIC_ONLY:-0}
ONLY=${ONLY:-}
TIMEOUT=${TIMEOUT:-5400}

TOOLS=${LVX_TOOLS:-$CSW/lvx-toolchain/bin}
# The core is spelled -march by lvx-gcc and -mcpu by clang, so the flag is
# chosen here with the compiler, never by a caller.  It mattered: until
# lvx-llvm d7a03955 (2026-10-16) clang took -march=lvx-2 as an unused argument,
# warned, and built for its default core -- lvx-1 code, timed as lvx-2.  -march
# is an alias there now, but -mcpu is clang's own spelling and right on every
# build.
COMPILER=${COMPILER:-gcc}
case "$COMPILER" in
    gcc)   XCC=$TOOLS/lvx-mbr-gcc;   cpuflag="-march=$ARCH"; ctag="" ;;
    clang) XCC=$TOOLS/lvx-mbr-clang; cpuflag="-mcpu=$ARCH";  ctag="-clang" ;;
    *) echo "COMPILER must be gcc or clang (got $COMPILER)" >&2; exit 2 ;;
esac
OBJDUMP=$TOOLS/lvx-mbr-objdump
SIZE=$TOOLS/lvx-mbr-size
GEM5=${GEM5:-$CSW/lvx-gem5/build/gem5-lvx$core.opt}
GEM5_CFG=${GEM5_CFG:-$CSW/lvx-gem5/tests/lvx/run_lvx.py}
LDSCRIPTS=${LDSCRIPTS:-$CSW/lvx-newlib/libgloss/lvx-mbr/linker_scripts}

# -std=gnu89 -fpermissive is not optional: MiBench is 1990s C and GCC 17
# rejects implicit declarations, implicit int and return-type mismatches by
# default.  Without these flags 11 of 18 targets fail to compile, which says
# nothing about LVX.  clang takes the same pair: gnu89 permits implicit
# declarations and implicit int, and -fpermissive is accepted and ignored.
# -T lvx-sim.ld supplies sbrk's _heap_start/_heap_end;
# without it a hosted link leaves them undefined and malloc has no heap.
CFLAGS="-O$OPT $cpuflag -std=gnu89 -fpermissive -ffreestanding -fno-strict-aliasing"
LDFLAGS="-T lvx-sim.ld -L$LDSCRIPTS -lm"

for t in "$XCC" "$OBJDUMP" "$SIZE"; do
    [ -x "$t" ] || { echo "missing tool: $t" >&2; exit 2; }
done
if [ "$STATIC_ONLY" != 1 ]; then
    [ -x "$GEM5" ] || { echo "missing ISS: $GEM5 (build-cores.sh)" >&2; exit 2; }
fi

stamp=$(date +%Y-%m-%d)
outdir="$repo/results"; mkdir -p "$outdir"
tsv="$outdir/$ARCH$ctag-O$OPT-$stamp.tsv"
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
    ( cd "$repo/$dir" && $XCC $CFLAGS -I. $srcs $LDFLAGS -o "$bdir/$name.elf" ) \
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
    # NOT `if (FNR>1)' on $rows: $rows carries no header line, so that guard
    # skipped its FIRST row and left that one unmarked -- the baseline's copy
    # was then appended as well and the kernel appeared TWICE in the merged
    # file, with the stale row sorting first.  The merge exists to stop an
    # ONLY= re-run from destroying a baseline, which it did; it was silently
    # duplicating instead.  Found 2026-10-09 by an ONLY=gramschmidt re-run.
    awk -F'\t' 'NR==FNR { seen[$1]=1; next }
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
