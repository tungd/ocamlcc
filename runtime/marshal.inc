/* OCaml's uncompressed Marshal wire format, interpreted over ArcHeader.
 * All traversal state is local. No object header is modified while encoding. */
typedef struct MBuffer { uint8_t *data; size_t len, cap; } MBuffer;
typedef struct MEntry { uintptr_t key; size_t index; } MEntry;
typedef struct MMap { MEntry *data; size_t cap, used; } MMap;
typedef struct MTask { int64_t value; int leave; } MTask;
typedef struct MWriter {
    MBuffer output;
    MMap seen;
    MTask *tasks; size_t count, cap;
    uint64_t objects, words32, words64;
    int no_sharing, compat32, invalid;
    const char *error;
} MWriter;

static void m_grow(void **data, size_t *cap, size_t width, size_t need)
{
    if (need <= *cap) return;
    size_t next = *cap ? *cap : 256;
    while (next < need) {
        if (next > SIZE_MAX / 2) pal_abort();
        next *= 2;
    }
    if (next > SIZE_MAX / width) pal_abort();
    void *p = pal_page_alloc(next * width);
    if (!p) pal_abort();
    if (*data) { pal_memcpy(p, *data, *cap * width); pal_page_free(*data, *cap * width); }
    *data = p; *cap = next;
}
static size_t m_hash(uintptr_t key) { key >>= 3; key ^= key >> 33; key *= UINT64_C(0xff51afd7ed558ccd); return key ^ (key >> 33); }
static size_t m_lookup(const MMap *m, uintptr_t key)
{
    if (!m->cap) return SIZE_MAX;
    size_t i = m_hash(key) & (m->cap - 1);
    while (m->data[i].key) {
        if (m->data[i].key == key) return m->data[i].index;
        i = (i + 1) & (m->cap - 1);
    }
    return SIZE_MAX;
}
static void m_insert(MMap *m, uintptr_t key, size_t index)
{
    if (!m->cap || (m->used + 1) * 2 >= m->cap) {
        size_t oldcap = m->cap; MEntry *old = m->data;
        m->cap = oldcap ? oldcap * 2 : 256;
        m->data = pal_page_alloc(m->cap * sizeof(MEntry)); if (!m->data) pal_abort();
        pal_memset(m->data, 0, m->cap * sizeof(MEntry)); m->used = 0;
        for (size_t j = 0; j < oldcap; j++) if (old[j].key > 1) m_insert(m, old[j].key, old[j].index);
        if (old) pal_page_free(old, oldcap * sizeof(MEntry));
    }
    size_t i = m_hash(key) & (m->cap - 1);
    while (m->data[i].key > 1) i = (i + 1) & (m->cap - 1);
    if (!m->data[i].key) m->used++;
    m->data[i] = (MEntry){key, index};
}
static void m_remove(MMap *m, uintptr_t key)
{
    size_t i = m_hash(key) & (m->cap - 1);
    while (m->data[i].key != key) i = (i + 1) & (m->cap - 1);
    m->data[i].key = 1;
}
static void m_put(MWriter *w, uint64_t value, int bytes)
{
    m_grow((void **)&w->output.data, &w->output.cap, 1, w->output.len + (size_t)bytes);
    for (int i = bytes - 1; i >= 0; i--) w->output.data[w->output.len++] = (uint8_t)(value >> (i * 8));
}
static void m_bytes(MWriter *w, const void *p, size_t n)
{
    if (n > UINT32_MAX || w->output.len > UINT32_MAX - n) { w->error = "output_value: object too big"; return; }
    m_grow((void **)&w->output.data, &w->output.cap, 1, w->output.len + n);
    pal_memcpy(w->output.data + w->output.len, p, n); w->output.len += n;
}
static void m_code(MWriter *w, int code, uint64_t value, int bytes) { m_put(w, code, 1); m_put(w, value, bytes); }
static void m_header(MWriter *w, uint64_t size, uint16_t tag)
{
    if (size < 8 && tag < 16) m_put(w, 0x80 + tag + (size << 4), 1);
    else { uint64_t hd = size << 10 | tag; m_code(w, hd <= UINT32_MAX ? 8 : 0x13, hd, hd <= UINT32_MAX ? 4 : 8); }
}
static void m_push(MWriter *w, int64_t value, int leave)
{
    m_grow((void **)&w->tasks, &w->cap, sizeof(MTask), w->count + 1);
    w->tasks[w->count++] = (MTask){value, leave};
}
static void m_write_int(MWriter *w, int64_t n)
{
    if (n >= 0 && n < 64) m_put(w, 0x40 + n, 1);
    else if (n >= -128 && n < 128) m_code(w, 0, (uint64_t)n, 1);
    else if (n >= -32768 && n < 32768) m_code(w, 1, (uint64_t)n, 2);
    else if (n < -(INT64_C(1) << 30) || n >= (INT64_C(1) << 30)) {
        if (w->compat32) w->error = "output_value: integer cannot be read back on 32-bit platform";
        else m_code(w, 3, (uint64_t)n, 8);
    } else m_code(w, 2, (uint64_t)n, 4);
}
static void m_float(MWriter *w, const void *p)
{
    uint64_t bits; pal_memcpy(&bits, p, 8);
    for (int j = 0; j < 8; j++) m_put(w, bits >> (8*j), 1);
}
static void m_write_bigarray(MWriter *w, const ArcBigarray *a)
{
    m_put(w, 0x18, 1); m_bytes(w, "_bigarr02", 10);
    m_put(w, (4 + a->ndims) * 4, 4); m_put(w, (4 + a->ndims) * 8, 8);
    m_put(w, a->ndims, 4); m_put(w, a->kind | (a->layout << 8), 4);
    for (int i = 0; i < a->ndims; i++) {
        if (a->dims[i] < 65535) m_put(w, a->dims[i], 2);
        else { m_put(w, 65535, 2); m_put(w, a->dims[i], 8); }
    }
    size_t count = ba_count(a); int width = ba_sizes[a->kind];
    if (a->kind == 10 || a->kind == 11) { count *= 2; width /= 2; }
    if (a->kind == 8 || a->kind == 9) {
        const int64_t *data = (const void *)a->data;
        int64_t min = a->kind == 8 ? INT32_MIN / 2 : INT32_MIN;
        int64_t max = a->kind == 8 ? INT32_MAX / 2 : INT32_MAX;
        width = 4;
        for (size_t i = 0; i < count; i++) if (data[i] < min || data[i] > max) { width = 8; break; }
        m_put(w, width == 8, 1);
        for (size_t i = 0; i < count; i++) m_put(w, data[i], width);
    } else {
        for (size_t i = 0; i < count; i++) {
            uint64_t bits = 0;
            /* Copy into a same-width unsigned type for host byte order. */
            const uint8_t *p = a->data + i * width;
            if (width == 1) bits = *p;
            else if (width == 2) { uint16_t x; pal_memcpy(&x, p, 2); bits = x; }
            else if (width == 4) { uint32_t x; pal_memcpy(&x, p, 4); bits = x; }
            else pal_memcpy(&bits, p, 8);
            m_put(w, bits, width);
        }
    }
    w->words32 += 6 + a->ndims; w->words64 += 6 + a->ndims;
}
static void m_write_value(MWriter *w, int64_t root)
{
    m_push(w, root, 0);
    while (w->count && !w->error) {
        MTask task = w->tasks[--w->count]; int64_t v = task.value;
        if (task.leave) { m_remove(&w->seen, (uintptr_t)v); continue; }
        if (v & 1) { m_write_int(w, v >> 1); continue; }
        if (!v) { w->error = "output_value: abstract value"; w->invalid = 1; break; }
        const ArcHeader *h = (void *)((uintptr_t)v - sizeof(ArcHeader));
        uint16_t tag = h->tag;
        uint64_t n = h->byte_size / 8;
        if (tag == ARC_TAG_CLOSURE || tag == ARC_TAG_PAP) {
            w->error = "output_value: functional value"; w->invalid = 1; break;
        }
        if (tag == ARC_TAG_ARRAY) tag = 0;
        else if (tag == ARC_TAG_LAZY) tag = 246;
        else if (tag == ARC_TAG_FORWARD) tag = 250;
        else if (tag == ARC_TAG_FORCING || tag == ARC_TAG_WEAK || tag == ARC_TAG_FIBER || tag == ARC_TAG_CHANNEL) {
            w->error = "output_value: abstract value"; w->invalid = 1; break;
        }
        if (h->byte_size == 0) { m_header(w, 0, tag); continue; }
        size_t previous = m_lookup(&w->seen, (uintptr_t)v);
        if (previous != SIZE_MAX) {
            if (w->no_sharing) { w->error = "output_value: cyclic value with No_sharing"; w->invalid = 1; break; }
            uint64_t distance = w->objects - previous;
            m_code(w, distance < 256 ? 4 : distance < 65536 ? 5 : 6, distance, distance < 256 ? 1 : distance < 65536 ? 2 : 4);
            continue;
        }
        if (!w->no_sharing) m_insert(&w->seen, (uintptr_t)v, w->objects++);
        if (tag == ARC_TAG_STRING) {
            n = h->reserved;
            if (n < 32) m_put(w, 0x20 + n, 1);
            else m_code(w, n < 256 ? 9 : 10, n, n < 256 ? 1 : 4);
            m_bytes(w, (void *)(uintptr_t)v, n);
            w->words32 += 1 + (n + 4) / 4; w->words64 += 1 + (n + 8) / 8;
        } else if (tag == ARC_TAG_FLOAT) {
            m_put(w, 12, 1); m_float(w, (void *)(uintptr_t)v);
            w->words32 += 3; w->words64 += 2;
        } else if (tag == ARC_TAG_FLOAT_ARRAY) {
            m_code(w, n < 256 ? 14 : 7, n, n < 256 ? 1 : 4);
            for (uint64_t i = 0; i < n; i++) m_float(w, (uint8_t *)(uintptr_t)v + 8*i);
            w->words32 += 1 + 2*n; w->words64 += 1 + n;
        } else if (tag == ARC_TAG_CUSTOM) {
            if (h->reserved == ARC_CUSTOM_BIGARRAY) { m_write_bigarray(w, (void *)(uintptr_t)v); continue; }
            if (h->reserved > ARC_CUSTOM_NATIVEINT) {
                w->error = "output_value: abstract value (Custom)"; w->invalid = 1; break;
            }
            int kind = h->reserved;
            const char *id = kind == ARC_CUSTOM_INT32 ? "_i" : kind == ARC_CUSTOM_INT64 ? "_j" : "_n";
            m_put(w, 0x19, 1); m_bytes(w, id, 3);
            int64_t x = unbox_custom_i64(v);
            if (kind == ARC_CUSTOM_INT32) m_put(w, x, 4);
            else if (kind == ARC_CUSTOM_INT64) m_put(w, x, 8);
            else if (x >= INT32_MIN && x <= INT32_MAX) { m_put(w, 1, 1); m_put(w, x, 4); }
            else if (w->compat32) w->error = "output_value: native integer cannot be read back on 32-bit platform";
            else { m_put(w, 2, 1); m_put(w, x, 8); }
            w->words32 += kind == ARC_CUSTOM_INT64 ? 4 : 3; w->words64 += 3;
        } else {
            if (tag > 250) { w->error = "output_value: abstract value"; w->invalid = 1; break; }
            m_header(w, n, tag); w->words32 += 1+n; w->words64 += 1+n;
            if (w->no_sharing) { m_insert(&w->seen, (uintptr_t)v, 0); m_push(w, v, 1); }
            const int64_t *fields = (void *)(uintptr_t)v;
            for (uint64_t i = n; i > 0; i--) m_push(w, fields[i - 1], 0);
        }
    }
}
static void m_writer_free(MWriter *w)
{
    if (w->output.data) pal_page_free(w->output.data, w->output.cap);
    if (w->tasks) pal_page_free(w->tasks, w->cap * sizeof(MTask));
    if (w->seen.data) pal_page_free(w->seen.data, w->seen.cap * sizeof(MEntry));
}
static int64_t m_raise(const char *message, int invalid)
{
    if (invalid) return ba_invalid(message);
    size_t n = 0; while (message[n]) n++;
    raise_failure_cstr(message, n); return 1;
}
static int m_encode(MWriter *w, int64_t value, int64_t flags)
{
    for (int64_t cur = flags; cur != 1; cur = ((int64_t *)(uintptr_t)cur)[1]) {
        int flag = ((int64_t *)(uintptr_t)cur)[0] >> 1;
        if (flag == 0) w->no_sharing = 1;
        if (flag == 2) w->compat32 = 1;
    }
    for (int i = 0; i < 20; i++) m_put(w, 0, 1);
    m_write_value(w, value);
    if (w->error) return 0;
    if (w->output.len > UINT32_MAX || w->words32 > UINT32_MAX || w->words64 > UINT32_MAX) {
        w->error = "output_value: object too big"; return 0;
    }
    size_t end = w->output.len; w->output.len = 0;
    m_put(w, UINT32_C(0x8495a6be), 4); m_put(w, end - 20, 4); m_put(w, w->objects, 4);
    m_put(w, w->words32, 4); m_put(w, w->words64, 4); w->output.len = end;
    return 1;
}
int64_t caml_output_value_to_bytes(int64_t value, int64_t flags)
{
    MWriter w = {0}; int64_t result;
    if (m_encode(&w, value, flags)) {
        void *p = arc_alloc_bytes(w.output.len); pal_memcpy(p, w.output.data, w.output.len);
        result = (int64_t)(uintptr_t)p;
    } else result = m_raise(w.error, w.invalid);
    m_writer_free(&w); return result;
}
int64_t caml_output_value_to_string(int64_t value, int64_t flags) { return caml_output_value_to_bytes(value, flags); }
int64_t caml_output_value_to_buffer(int64_t buffer, int64_t offset, int64_t length, int64_t value, int64_t flags)
{
    MWriter w = {0}; int64_t result = 1;
    if (!m_encode(&w, value, flags)) result = m_raise(w.error, w.invalid);
    else if (w.output.len > (uint64_t)(length >> 1)) result = m_raise("Marshal.to_buffer: buffer overflow", 0);
    else { pal_memcpy((uint8_t *)(uintptr_t)buffer + (offset >> 1), w.output.data, w.output.len); result = tag_int(w.output.len); }
    m_writer_free(&w); return result;
}

typedef struct MReader {
    const uint8_t *data; size_t pos, end;
    int64_t *objects, *owners; size_t count, cap, owned, ownercap;
    int64_t **tasks; size_t pending, taskcap;
    uint64_t expected;
    int64_t atoms[256];
    const char *error;
} MReader;
static uint64_t m_get(MReader *r, int bytes)
{
    if ((size_t)bytes > r->end - r->pos) { r->error = "input_value: truncated object"; return 0; }
    uint64_t n = 0;
    for (int i = 0; i < bytes; i++) n = n << 8 | r->data[r->pos++];
    return n;
}
static void m_own(MReader *r, int64_t value, int shared)
{
    m_grow((void **)&r->owners, &r->ownercap, sizeof(int64_t), r->owned + 1);
    r->owners[r->owned++] = value;
    if (shared && r->expected) {
        if (r->count >= r->expected) { r->error = "input_value: ill-formed message"; return; }
        m_grow((void **)&r->objects, &r->cap, sizeof(int64_t), r->count + 1);
        r->objects[r->count++] = value;
    }
}
static void m_slot(MReader *r, int64_t *slot)
{
    m_grow((void **)&r->tasks, &r->taskcap, sizeof(int64_t *), r->pending + 1);
    r->tasks[r->pending++] = slot;
}
static uint64_t m_float_bits(MReader *r, int little)
{
    uint64_t n = m_get(r, 8);
    if (little) { uint64_t rev = 0; for (int i = 0; i < 8; i++) { rev = rev << 8 | (n & 255); n >>= 8; } return rev; }
    return n;
}
static int m_read_header(MReader *r, size_t *header, uint64_t *length)
{
    uint64_t magic = m_get(r, 4);
    if (r->error) return 0;
    if (magic == UINT32_C(0x8495a6be)) {
        *length = m_get(r, 4); r->expected = m_get(r, 4); m_get(r, 4); m_get(r, 4); *header = 20;
    } else if (magic == UINT32_C(0x8495a6bf)) {
        m_get(r, 4); *length = m_get(r, 8); r->expected = m_get(r, 8); m_get(r, 8); *header = 32;
    } else { r->error = "input_value: bad object"; return 0; }
    return !r->error;
}
static int64_t m_read_bigarray(MReader *r, uint64_t size32, uint64_t size64)
{
    uint64_t n = m_get(r, 4), flags = m_get(r, 4);
    int kind = flags & 255, layout = (flags >> 8) & 1;
    if (n > BA_MAX_DIMS || kind >= 14 || flags != (uint64_t)(kind | layout << 8)
        || size32 != (4 + n) * 4 || size64 != (4 + n) * 8) {
        r->error = "input_value: invalid bigarray descriptor"; return 1;
    }
    int64_t dims[BA_MAX_DIMS]; size_t count = 1;
    for (uint64_t i = 0; i < n; i++) {
        uint64_t d = m_get(r, 2); if (d == 65535) d = m_get(r, 8);
        if (d > (uint64_t)(INT64_MAX >> 1) || (d && count > (SIZE_MAX / ba_sizes[kind]) / d)) {
            r->error = "input_value: bigarray size overflow"; return 1;
        }
        dims[i] = tag_int(d); count *= d;
    }
    int width = ba_sizes[kind]; size_t elements = count;
    if (kind == 10 || kind == 11) { elements *= 2; width /= 2; }
    if (kind == 8 || kind == 9) {
        int wide = m_get(r, 1);
        if (wide != 0 && wide != 1) { r->error = "input_value: invalid bigarray integer size"; return 1; }
        width = wide ? 8 : 4;
    }
    if (r->error || elements > (r->end - r->pos) / width) { r->error = "input_value: truncated object"; return 1; }
    int64_t dimensions = (int64_t)(uintptr_t)arc_alloc_array(n, 1);
    pal_memcpy((void *)(uintptr_t)dimensions, dims, n * 8);
    int64_t value = caml_ba_create(tag_int(kind), tag_int(layout), dimensions);
    arc_release_val(dimensions);
    if (ocamlcc_get_exn()) { r->error = "input_value: invalid bigarray"; return 1; }
    ArcBigarray *a = (void *)(uintptr_t)value;
    for (size_t i = 0; i < elements; i++) {
        uint64_t bits = m_get(r, width);
        if (kind == 8 || kind == 9) ((int64_t *)a->data)[i] = width == 4 ? (int64_t)(int32_t)bits : (int64_t)bits;
        else if (width == 1) a->data[i] = bits;
        else if (width == 2) { uint16_t x = bits; pal_memcpy(a->data + i * 2, &x, 2); }
        else if (width == 4) { uint32_t x = bits; pal_memcpy(a->data + i * 4, &x, 4); }
        else pal_memcpy(a->data + i * 8, &bits, 8);
    }
    m_own(r, value, 1); return value;
}
static int64_t m_decode(MReader *r)
{
    int64_t root = 1; m_slot(r, &root);
    while (r->pending && !r->error) {
        int64_t *slot = r->tasks[--r->pending], value = 1;
        uint64_t n = 0; uint16_t tag = 0; int block = 0, string = 0, floats = 0, little = 0;
        int code = (int)m_get(r, 1);
        if (r->error) break;
        if (code >= 0x80) { tag = code & 15; n = (code >> 4) & 7; block = 1; }
        else if (code >= 0x40) value = tag_int(code - 0x40);
        else if (code >= 0x20) { n = code - 0x20; string = 1; }
        else switch (code) {
        case 0: value = tag_int((int8_t)m_get(r, 1)); break;
        case 1: value = tag_int((int16_t)m_get(r, 2)); break;
        case 2: value = tag_int((int32_t)m_get(r, 4)); break;
        case 3: value = tag_int((int64_t)m_get(r, 8)); break;
        case 4: case 5: case 6: case 0x14:
            n = m_get(r, code == 4 ? 1 : code == 5 ? 2 : code == 6 ? 4 : 8);
            if (!n || n > r->count) r->error = "input_value: invalid shared reference";
            else value = r->objects[r->count - n];
            break;
        case 8: case 0x13: {
            uint64_t hd = m_get(r, code == 8 ? 4 : 8); tag = hd & 255; n = hd >> 10; block = 1; break;
        }
        case 9: case 10: case 0x15: n = m_get(r, code == 9 ? 1 : code == 10 ? 4 : 8); string = 1; break;
        case 11: case 12: n = 1; floats = 1; little = code == 12; break;
        case 13: case 14: case 15: case 7: case 0x16: case 0x17:
            n = m_get(r, code == 13 || code == 14 ? 1 : code == 15 || code == 7 ? 4 : 8);
            floats = 2; little = code == 14 || code == 7 || code == 0x17; break;
        case 0x18: case 0x19: {
            char id[64] = {0}; size_t i = 0;
            do { id[i] = (char)m_get(r, 1); } while (!r->error && id[i] && ++i < sizeof(id)-1);
            id[sizeof(id)-1] = 0;
            if (r->error) break;
            uint64_t size32 = 0, size64 = 0;
            if (code == 0x18) { size32 = m_get(r, 4); size64 = m_get(r, 8); }
            if (id[0] == '_' && id[1] == 'b' && id[2] == 'i' && id[3] == 'g' && id[4] == 'a' && id[5] == 'r' && id[6] == 'r' && id[7] == '0' && id[8] == '2' && id[9] == 0) {
                if (code != 0x18) { r->error = "input_value: invalid custom block length"; break; }
                value = m_read_bigarray(r, size32, size64); break;
            }
            if (code != 0x19) { r->error = "input_value: invalid custom block length"; break; }
            int kind = id[0] == '_' && id[2] == 0 ? (id[1] == 'i' ? 0 : id[1] == 'j' ? 1 : id[1] == 'n' ? 2 : -1) : -1;
            if (kind < 0) { r->error = "input_value: unknown custom block identifier"; break; }
            int64_t bits;
            if (kind == 0) bits = (int32_t)m_get(r, 4);
            else if (kind == 1) bits = (int64_t)m_get(r, 8);
            else {
                int size = m_get(r, 1);
                if (size != 1 && size != 2) { r->error = "input_value: ill-formed native integer"; break; }
                bits = size == 1 ? (int32_t)m_get(r, 4) : (int64_t)m_get(r, 8);
            }
            if (!r->error) { value = ocamlcc_alloc_custom(kind, bits); m_own(r, value, 1); }
            break;
        }
        default: r->error = "input_value: ill-formed message"; break;
        }
        if (r->error) break;
        if (block) {
            if (tag >= 245 && tag != 246 && tag != 248 && tag != 250 && !(n == 0 && tag == 254)) { r->error = "input_value: unsupported block tag"; break; }
            if (n > (UINT32_MAX - sizeof(ArcHeader)) / 8 || (tag != 0 && n > UINT16_MAX)) { r->error = "input_value: block too large"; break; }
            if (!n && r->atoms[tag]) value = r->atoms[tag];
            else {
                uint16_t arc_tag = tag == 246 ? ARC_TAG_LAZY : tag == 250 ? ARC_TAG_FORWARD : tag;
                if (tag == 0 && n > UINT16_MAX) arc_tag = ARC_TAG_ARRAY;
                int64_t *p = arc_alloc(arc_tag, n > UINT16_MAX ? 0 : n, (uint32_t)n * 8);
                for (uint64_t i = 0; i < n; i++) p[i] = 1;
                value = (int64_t)(uintptr_t)p; m_own(r, value, n != 0);
                if (!n) r->atoms[tag] = value;
                for (uint64_t i = n; i > 0; i--) m_slot(r, p + i - 1);
            }
        } else if (string) {
            if (n > r->end - r->pos || n > UINT32_MAX - sizeof(ArcHeader) - 1) { r->error = "input_value: truncated object"; break; }
            void *p = arc_alloc_bytes(n); pal_memcpy(p, r->data + r->pos, n); r->pos += n;
            value = (int64_t)(uintptr_t)p; m_own(r, value, 1);
        } else if (floats) {
            if (n > (r->end - r->pos) / 8 || n > (UINT32_MAX - sizeof(ArcHeader)) / 8) { r->error = "input_value: truncated object"; break; }
            uint64_t *p = arc_alloc(floats == 1 ? ARC_TAG_FLOAT : ARC_TAG_FLOAT_ARRAY, 0, (uint32_t)n * 8);
            for (uint64_t i = 0; i < n; i++) p[i] = m_float_bits(r, little);
            value = (int64_t)(uintptr_t)p; m_own(r, value, 1);
        }
        arc_retain_val(value); *slot = value;
    }
    if (!r->error && (r->pos != r->end || (r->expected && r->count != r->expected)))
        r->error = "input_value: ill-formed message";
    if (r->error) {
        /* Owners keep all nodes alive while partial edges (including cycles)
           are severed, then ordinary ARC destruction releases each node. */
        for (size_t j = 0; j < r->owned; j++) {
            ArcHeader *h = (ArcHeader *)(uintptr_t)r->owners[j] - 1;
            if (h->tag == ARC_TAG_ARRAY || h->scan_fields) {
                size_t n = h->tag == ARC_TAG_ARRAY ? h->byte_size / 8 : h->scan_fields;
                int64_t *p = (void *)(h + 1);
                for (size_t i = 0; i < n; i++) { int64_t child = p[i]; p[i] = 1; arc_release_val(child); }
            }
        }
        arc_release_val(root); root = 1;
    }
    for (size_t j = 0; j < r->owned; j++) arc_release_val(r->owners[j]);
    return root;
}
static void m_reader_free(MReader *r)
{
    if (r->objects) pal_page_free(r->objects, r->cap * sizeof(int64_t));
    if (r->owners) pal_page_free(r->owners, r->ownercap * sizeof(int64_t));
    if (r->tasks) pal_page_free(r->tasks, r->taskcap * sizeof(int64_t *));
}
int64_t caml_marshal_data_size(int64_t buffer, int64_t offset)
{
    const ArcHeader *h = (ArcHeader *)(uintptr_t)buffer - 1; int64_t o = offset >> 1;
    if (o < 0 || (uint64_t)o > h->reserved) return m_raise("Marshal.data_size", 1);
    MReader r = {.data = (uint8_t *)(uintptr_t)buffer + o, .end = h->reserved - (size_t)o};
    size_t header = 0; uint64_t length = 0;
    if (!m_read_header(&r, &header, &length)) return m_raise(r.error, 0);
    if (length > (uint64_t)(INT64_MAX >> 1) - header) return m_raise("input_value: object too large", 0);
    /* Marshal.header_size is 16; data_size includes the remaining header. */
    return tag_int((int64_t)(length + header - 16));
}
static int64_t m_from_block(const uint8_t *data, size_t available)
{
    MReader r = {.data = data, .end = available}; size_t header = 0; uint64_t length = 0;
    if (!m_read_header(&r, &header, &length)) return m_raise(r.error, 0);
    if (length > available - header) return m_raise("input_value: truncated object", 0);
    r.end = header + length;
    int64_t value = m_decode(&r); m_reader_free(&r);
    if (r.error) return m_raise(r.error, 0);
    return value;
}
int64_t caml_input_value_from_bytes(int64_t buffer, int64_t offset)
{
    const ArcHeader *h = (ArcHeader *)(uintptr_t)buffer - 1; int64_t o = offset >> 1;
    if (o < 0 || (uint64_t)o > h->reserved) return m_raise("Marshal.from_bytes", 1);
    return m_from_block((uint8_t *)(uintptr_t)buffer + o, h->reserved - (size_t)o);
}
int64_t caml_output_value(int64_t channel, int64_t value, int64_t flags)
{
    MWriter w = {0};
    if (m_encode(&w, value, flags)) chan_write_bytes((void *)(uintptr_t)channel, w.output.data, w.output.len);
    else m_raise(w.error, w.invalid);
    m_writer_free(&w); return 1;
}
static int m_channel_read(int64_t channel, uint8_t *buffer, size_t n, int initial)
{
    size_t read = 0;
    while (read < n) {
        int64_t value = caml_ml_input_char(channel);
        if (ocamlcc_get_exn()) {
            if (read || !initial) {
                int64_t exn = ocamlcc_get_exn(); ocamlcc_set_exn(0); arc_release_val(exn);
                m_raise("input_value: truncated object", 0);
            }
            return 0;
        }
        buffer[read++] = (uint8_t)(value >> 1);
    }
    return 1;
}
int64_t caml_input_value(int64_t channel)
{
    uint8_t header[32];
    if (!m_channel_read(channel, header, 20, 1)) return 1;
    size_t n = header[3] == 0xbf ? 32 : 20;
    if (n == 32 && !m_channel_read(channel, header + 20, 12, 0)) return 1;
    MReader r = {.data = header, .end = n}; size_t size = 0; uint64_t length = 0;
    if (!m_read_header(&r, &size, &length)) return m_raise(r.error, 0);
    if (length > UINT32_MAX - n) return m_raise("input_value: object too large", 0);
    size_t total = n + (size_t)length;
    uint8_t *data = pal_page_alloc(total); if (!data) pal_abort();
    pal_memcpy(data, header, n); int64_t value = 1;
    if (m_channel_read(channel, data + n, length, 0)) value = m_from_block(data, total);
    pal_page_free(data, total); return value;
}
