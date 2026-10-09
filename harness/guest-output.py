#!/usr/bin/env python3
"""Extract a guest program's own bytes from a gem5 run log.

LVX's SE-mode syscalls are implemented inline in the runtime shim
(lvx-gem5 src/arch/lvx/se_workload.hh: "scall is handled inline in the runtime
shim (Behavior_syscall) ... the workload's syscall entry is currently unused"),
so they bypass gem5's SyscallDesc table and with it the Process FDArray.  That
means gem5's own per-process redirection -- process.output / process.input --
has no effect: the guest writes straight to the host's stdout, mixed in with
gem5's banner.  Until scall is routed through SyscallDesc, the guest's bytes
have to be cut out of the combined stream.

Doing that by line is unsafe for a binary output such as adpcm's, so this works
on bytes: the guest's output starts just after the newline ending gem5's
"beginning execution of ..." line and ends where its "== Exiting @" marker
begins.  Everything between is the guest's, byte for byte.

This only works because the caller keeps the two streams apart.  gem5's own
info/warn go to stderr -- "Increasing stack size by one page" among them,
emitted repeatedly mid-run -- so a caller that merges with 2>&1 interleaves
diagnostics into the guest's bytes and no extraction can recover them.

    guest-output.py <run.log> <out-file>
"""
import sys

START = b"beginning execution of"
# No leading newline: gem5 appends this directly after the guest's last byte
# and adds no separator of its own.  A text guest ends with its own newline, so
# the line break before "== Exiting" is the guest's and belongs to its output;
# a binary guest (adpcm) ends mid-byte and gets the marker glued on.  Cutting at
# the marker itself is therefore right for both -- requiring "\n== Exiting"
# silently kept gem5's whole 75-byte exit line in adpcm's output.
END = b"== Exiting @"


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    raw = open(sys.argv[1], "rb").read()

    i = raw.find(START)
    if i < 0:
        # No banner: either gem5 died before starting the guest, or a future
        # version changed the line.  Emit nothing rather than guess, so the
        # caller reports a mismatch instead of comparing noise.
        open(sys.argv[2], "wb").close()
        return 1
    nl = raw.find(b"\n", i)
    begin = len(raw) if nl < 0 else nl + 1

    j = raw.find(END, begin)
    end = len(raw) if j < 0 else j

    open(sys.argv[2], "wb").write(raw[begin:end])
    return 0


if __name__ == "__main__":
    sys.exit(main())
