#!/usr/bin/env bash
# Compare two harness runs, per benchmark.
#
#   ./harness/compare.sh results/lvx-2-O2-2026-10-01.tsv results/lvx-2-O2-2026-10-09.tsv
#
# Reports every metric that moved by more than THRESH (default 2%), and every
# change in the correctness column.  Per benchmark, deliberately: an aggregate
# hides exactly what matters.  A vect.exp A/B during this project read as
# +8/-8 -- apparently neutral -- while concealing a real regression and a
# separate set of gains; only the per-test diff found it.
#
# A correctness change is reported first and loudly, because a cycle count from
# a run whose output is wrong is not a performance result.  A benchmark that
# "got 40% faster" and stopped matching its reference did not get faster.
set -u
THRESH=${THRESH:-2}
[ $# -eq 2 ] || { sed -n '2,12p' "$0"; exit 2; }
old=$1; new=$2

awk -v thresh="$THRESH" -v oldf="$old" -v newf="$new" '
function pct(o, n) { return (o == 0) ? 0 : (n - o) * 100.0 / o }
BEGIN {
    FS = "\t"
    while ((getline line < oldf) > 0) {
        split(line, f, FS)
        if (f[1] == "benchmark") continue
        oc[f[1]] = f[4]; ocyc[f[1]] = f[5]; obun[f[1]] = f[6]
        otext[f[1]] = f[7]; oins[f[1]] = f[8]; osb[f[1]] = f[9]
    }
    nb = 0
    while ((getline line < newf) > 0) {
        split(line, f, FS)
        if (f[1] == "benchmark") continue
        order[++nb] = f[1]
        nc[f[1]] = f[4]; ncyc[f[1]] = f[5]; nbun[f[1]] = f[6]
        ntext[f[1]] = f[7]; nins[f[1]] = f[8]; nsb[f[1]] = f[9]
    }

    hdr = 0
    for (i = 1; i <= nb; i++) {
        b = order[i]
        if (!(b in oc)) { printf("  NEW       %-18s (not in the baseline)\n", b); continue }
        if (oc[b] != nc[b]) {
            if (!hdr) { print "CORRECTNESS CHANGED:"; hdr = 1 }
            printf("  %-18s %s -> %s\n", b, oc[b], nc[b])
        }
    }
    for (b in oc) if (!(b in nc)) printf("  GONE      %-18s (in the baseline, not in this run)\n", b)
    if (hdr) print ""

    print "METRICS (only moves beyond " thresh "%):"
    any = 0
    for (i = 1; i <= nb; i++) {
        b = order[i]
        if (!(b in oc)) continue
        if (ncyc[b] == "" || ocyc[b] == "") continue
        pc = pct(ocyc[b], ncyc[b]); pb = pct(obun[b], nbun[b])
        pt = pct(otext[b], ntext[b]); pi = pct(oins[b], nins[b])
        if (pc >  thresh || pc < -thresh || pb >  thresh || pb < -thresh || \
            pt >  thresh || pt < -thresh || pi >  thresh || pi < -thresh) {
            any = 1
            printf("  %-18s cycles %+6.1f%%  bundles %+6.1f%%  text %+6.1f%%  insns %+6.1f%%", \
                   b, pc, pb, pt, pi)
            if (nc[b] != "ok" && nc[b] != "") printf("   [correct=%s]", nc[b])
            printf("\n")
        }
    }
    if (!any) print "  (nothing moved beyond the threshold)"
}' /dev/null
