# Provenance

Pristine import of **MiBench**, the embedded benchmark suite of Guthaus et al.,
*"MiBench: A free, commercially representative embedded benchmark suite"*
(IEEE 4th Annual Workshop on Workload Characterization, 2001).

Downloaded **2026-10-09** from <https://vhosts.eecs.umich.edu/mibench/source.html>,
six group tarballs, unpacked exactly as shipped and committed unmodified in the
first commit of this repository. SHA-256 of what was downloaded is in
`ORIGIN-checksums.txt`, so the import can be re-verified against the upstream
files.

| group | tarball | benchmarks |
|---|---|---|
| automotive | `automotive.tar.gz` | basicmath, bitcount, qsort, susan |
| consumer | `consumer.tar.gz` | jpeg, lame, mad, tiff2bw, tiff2rgba, tiffdither, tiffmedian, typeset |
| network | `network.tar.gz` | dijkstra, patricia |
| office | `office.tar.gz` | ghostscript, ispell, rsynth, sphinx, stringsearch |
| security | `security.tar.gz` | blowfish, pgp, rijndael, sha |
| telecomm | `telecomm.tar.gz` | adpcm, CRC32, FFT, gsm |

`consumer/tiff-data` and `consumer/tiff-v3.5.4` are shipped alongside the tiff
benchmarks: the former is their input data, the latter the libtiff they link.

## Licensing

Per the upstream page, each benchmark carries its own `LICENSE` in its home
directory and "as a general rule, all benchmarks are considered to be covered
by GNU's GPL". Those files are imported untouched; nothing here relicenses
them. This repository adds only build and harness files of its own, and those
are LVX project files under the licence the rest of the project uses.

## Why the first commit is unmodified

Everything LVX needs — cross-compilation, a freestanding or newlib-hosted
runtime, timing — is a *change* to this code. Keeping the import pristine makes
every one of those changes a reviewable diff against upstream rather than part
of an opaque drop, which is the same reason `lvx-binutils` and `lvx-gcc` are
forks with upstream as their base.

## Size

180 MB, 3953 files, dominated by input data: `consumer/tiff-data/large.tif` is
27 MB, `telecomm/adpcm/data/large.pcm` 25 MB, `office/sphinx/model` 20 MB. The
data is part of the benchmark — the small/large pairs are what `runme_small.sh`
and `runme_large.sh` drive — so it is imported rather than fetched.
