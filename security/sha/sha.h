#ifndef SHA_H
#define SHA_H

/* NIST Secure Hash Algorithm */
/* heavily modified from Peter C. Gutmann's implementation */

/* Useful defines & typedefs */

#include <stdint.h>	/* LVX: for uint32_t, see LONG below */

/* LVX: sha.c byte-reverses its input words under `#ifdef LITTLE_ENDIAN', and
   nothing in the three headers it includes -- stdlib.h, stdio.h, string.h --
   is specified to define that.  glibc leaks it anyway, newlib does not, so the
   same source silently computed two different digests on the two libcs and
   only the glibc one matched MiBench's reference output.  Decide from the
   compiler's own macro instead of a libc accident.  Guarded, so a libc that
   did define it first still wins and the value stays whatever that libc chose.  */
#if !defined(LITTLE_ENDIAN) \
    && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define LITTLE_ENDIAN 1234
#endif

typedef unsigned char BYTE;
/* LVX: was `unsigned long', which the algorithm requires to be exactly 32
   bits.  True on the ILP32 hosts of 1996 and on the 32-bit x86 that produced
   MiBench's reference output; false on every LP64 target, where SHA_INFO.data
   becomes 128 bytes while sha_update memcpy's 64 into it and sha_final writes
   the bit counts to data[14]/data[15] at the wrong byte offsets.  No LP64
   build computed a correct digest -- not LVX, and not a modern x86-64.  */
typedef uint32_t LONG;

#define SHA_BLOCKSIZE		64
#define SHA_DIGESTSIZE		20

typedef struct {
    LONG digest[5];		/* message digest */
    LONG count_lo, count_hi;	/* 64-bit bit count */
    LONG data[16];		/* SHA data buffer */
} SHA_INFO;

void sha_init(SHA_INFO *);
void sha_update(SHA_INFO *, BYTE *, int);
void sha_final(SHA_INFO *);

void sha_stream(SHA_INFO *, FILE *);
void sha_print(SHA_INFO *);

#endif /* SHA_H */
