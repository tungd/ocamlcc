/*
 * arc.h — Perceus-style Automatic Reference Counting (design doc §4.2).
 *
 * Object layout: the header precedes the user data pointer. Reference
 * counts are non-atomic in this phase (single-threaded scheduler); the
 * 0xFFFFFFFF sentinel marks immortal/static objects.
 */
#ifndef OCAMLCC_ARC_H
#define OCAMLCC_ARC_H

#include <stddef.h>
#include <stdint.h>

#define ARC_IMMORTAL 0xFFFFFFFFu

typedef struct ArcHeader {
    uint32_t refcount;   /* 0xFFFFFFFF = immortal/static */
    uint16_t tag;        /* constructor tag / object kind */
    uint16_t scan_fields;/* pointer fields to dec_ref on drop */
    uint32_t byte_size;  /* total size, for slab reuse */
    uint32_t reserved;
} ArcHeader;

void *arc_alloc(uint16_t tag, uint16_t scan_fields, uint32_t byte_size);
void  arc_retain(void *obj);
void  arc_release(void *obj);

#endif /* OCAMLCC_ARC_H */
