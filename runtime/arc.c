/* arc.c — bootstrap allocator + retain/release over ArcHeader.
 *
 * Phase 2 replaces malloc with the freestanding slab allocator and adds
 * Perceus reuse (in-place mutation of dead blocks). The scan_fields
 * recursive drop and weak/cycle hooks land with the ARC pass in the
 * middle-end. */
#include "arc.h"

#include <stdlib.h>

#include "pal.h"

void *arc_alloc(uint16_t tag, uint16_t scan_fields, uint32_t byte_size)
{
    ArcHeader *hdr = malloc(sizeof(ArcHeader) + byte_size);
    if (hdr == NULL)
        pal_abort();
    hdr->refcount = 1;
    hdr->tag = tag;
    hdr->scan_fields = scan_fields;
    hdr->byte_size = byte_size;
    hdr->reserved = 0;
    return hdr + 1;
}

void arc_retain(void *obj)
{
    ArcHeader *hdr = (ArcHeader *)obj - 1;
    if (hdr->refcount != ARC_IMMORTAL)
        hdr->refcount++;
}

void arc_release(void *obj)
{
    ArcHeader *hdr = (ArcHeader *)obj - 1;
    if (hdr->refcount == ARC_IMMORTAL)
        return;
    if (--hdr->refcount == 0)
        free(hdr);
}
