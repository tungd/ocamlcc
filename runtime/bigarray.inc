/* ARC-native Bigarray. Included by arc.c to share allocation and I/O helpers.
 * Views own the backing descriptor; descriptors own PAL pages, never views. */
#define BA_MAX_DIMS 16
static char ba_runtime_id;
static const uint8_t ba_sizes[] = {4,8,1,1,2,2,4,8,8,8,8,16,1,2};

static int64_t ba_invalid(const char *message)
{
    size_t n = 0; while (message[n]) n++;
    char *s = arc_alloc_bytes(n);
    pal_memcpy(s, message, n);
    /* The exception owns the freshly allocated string. */
    raise_invalid_arg_imm(s);
    return 1;
}

static size_t ba_count(const ArcBigarray *a)
{
    size_t count = 1;
    for (int i = 0; i < a->ndims; i++) count *= (size_t)a->dims[i];
    return count;
}

OcamlccBigarrayView *ocamlcc_bigarray_view_acquire(int64_t value)
{
    if (!is_heap_ptr(value))
        return NULL;
    int entered = arc_mutator_enter();
    ArcBigarray *view = (ArcBigarray *)(uintptr_t)value;
    const ArcHeader *header = (const ArcHeader *)view - 1;
    if (header->tag == ARC_TAG_CUSTOM && header->reserved == ARC_CUSTOM_BIGARRAY)
        arc_retain(view);
    else
        view = NULL;
    arc_mutator_leave(entered);
    return view;
}

OcamlccBigarrayView *ocamlcc_bigarray_view_retain(OcamlccBigarrayView *view)
{
    if (view != NULL) {
        int entered = arc_mutator_enter();
        arc_retain(view);
        arc_mutator_leave(entered);
    }
    return view;
}

/* Generated shims validate all borrowed inputs before retaining any.
 * Rank -1 accepts any rank for a Genarray signature. */
int ocamlcc_bigarray_view_matches(const OcamlccBigarrayView *view, int rank,
                                  int kind, int layout)
{
    return view && view->runtime_id == &ba_runtime_id && (rank == -1 || view->ndims == rank) &&
           view->kind == kind && view->layout == layout;
}

int64_t ocamlcc_bigarray_view_to_value(OcamlccBigarrayView *view)
{
    return (int64_t)(uintptr_t)ocamlcc_bigarray_view_retain(view);
}

void ocamlcc_bigarray_view_release(OcamlccBigarrayView *view)
{
    if (view != NULL) {
        int entered = arc_mutator_enter();
        arc_release(view);
        arc_mutator_leave(entered);
    }
}

OcamlccBigarrayInfo ocamlcc_bigarray_view_info(const OcamlccBigarrayView *view)
{
    if (view == NULL)
        return (OcamlccBigarrayInfo){0};
    return (OcamlccBigarrayInfo){
        .data = view->data,
        .byte_length = ba_count(view) * ba_sizes[view->kind],
        .dims = view->dims,
        .rank = view->ndims,
        .kind = view->kind,
        .layout = view->layout
    };
}

static inline double ba_load_f16(const uint8_t *p)
{
#ifdef __FLT16_MANT_DIG__
    return (double)*(const _Float16 *)p;
#else
    uint16_t h;
    pal_memcpy(&h, p, 2);
    uint32_t sign = (uint32_t)(h & 0x8000u) << 16;
    uint32_t exp = (h >> 10) & 0x1fu;
    uint32_t frac = h & 0x3ffu;
    uint32_t fbits;
    if (exp == 0u) {
        if (frac == 0u) {
            fbits = sign;
        } else {
            exp = 127u - 14u;
            while ((frac & 0x400u) == 0u) {
                frac <<= 1;
                exp--;
            }
            fbits = sign | (exp << 23) | ((frac & 0x3ffu) << 13);
        }
    } else if (exp == 0x1fu) {
        fbits = sign | 0x7f800000u | (frac << 13);
    } else {
        fbits = sign | ((exp + 127u - 15u) << 23) | (frac << 13);
    }
    float f;
    pal_memcpy(&f, &fbits, 4);
    return (double)f;
#endif
}

static inline void ba_store_f16(uint8_t *p, double v)
{
#ifdef __FLT16_MANT_DIG__
    *(_Float16 *)p = (_Float16)v;
#else
    float f = (float)v;
    uint32_t fbits;
    pal_memcpy(&fbits, &f, 4);
    uint16_t sign = (uint16_t)((fbits >> 16) & 0x8000u);
    int32_t exp = (int32_t)((fbits >> 23) & 0xffu) - 127 + 15;
    uint32_t frac = fbits & 0x7fffffu;
    uint16_t h;
    if (exp <= 0) {
        if (exp < -10) {
            h = sign;
        } else {
            frac |= 0x800000u;
            uint32_t shift = (uint32_t)(14 - exp);
            h = (uint16_t)(sign | (frac >> shift));
        }
    } else if (exp >= 31) {
        h = (uint16_t)(sign | 0x7c00u | (frac ? 0x0200u : 0u));
    } else {
        h = (uint16_t)(sign | ((uint32_t)exp << 10) | (frac >> 13));
    }
    pal_memcpy(p, &h, 2);
#endif
}

/* Takes one backing reference. */
static ArcBigarray *ba_wrap(ArcBigarrayBuffer *backing, uint8_t *data, int kind,
                            int layout, int ndims, const int64_t *dims)
{
    ArcBigarray *a = arc_alloc(ARC_TAG_CUSTOM, 0, sizeof(ArcBigarray));
    ((ArcHeader *)a - 1)->reserved = ARC_CUSTOM_BIGARRAY;
    a->runtime_id = &ba_runtime_id;
    a->backing = backing;
    a->data = data;
    a->kind = kind; a->layout = layout; a->ndims = ndims;
    for (int i = 0; i < ndims; i++) a->dims[i] = dims[i];
    return a;
}

static ArcBigarray *ba_view(ArcBigarray *source, int ndims, const int64_t *dims,
                            size_t offset, int layout)
{
    arc_retain(source->backing);
    return ba_wrap(source->backing, source->data + offset * ba_sizes[source->kind],
                   source->kind, layout, ndims, dims);
}

static ArcBigarrayBuffer *ba_backing(void)
{
    ArcBigarrayBuffer *b = arc_alloc(ARC_TAG_CUSTOM, 0, sizeof(*b));
    ((ArcHeader *)b - 1)->reserved = ARC_CUSTOM_BIGARRAY_BUFFER;
    return b;
}

OcamlccBigarrayView *ocamlcc_bigarray_view_import(const OcamlccBigarrayInfo *src,
    OcamlccBigarrayRelease release, void *context)
{
    if (!src || !release || !src->data || src->rank < 0 || src->rank > BA_MAX_DIMS ||
        (src->rank && !src->dims) || src->kind < 0 || src->kind >= (int)sizeof(ba_sizes) ||
        (src->layout != OCAMLCC_BA_C_LAYOUT && src->layout != OCAMLCC_BA_FORTRAN_LAYOUT))
        return NULL;
    size_t width = ba_sizes[src->kind];
    size_t alignment = (src->kind == OCAMLCC_BA_COMPLEX32 || src->kind == OCAMLCC_BA_COMPLEX64)
                       ? width / 2 : width;
    if ((uintptr_t)src->data % alignment) return NULL;
    size_t bytes = width;
    for (int i = 0; i < src->rank; i++) {
        int64_t dim = src->dims[i];
        if (dim < 0 || dim > INT64_MAX / 2 || (dim && bytes > SIZE_MAX / (size_t)dim))
            return NULL;
        bytes *= (size_t)dim;
    }
    if (bytes > src->byte_length) return NULL;
    int entered = arc_mutator_enter();
    ForeignRelease *owner = arc_alloc(0, 0, sizeof(*owner));
    *owner = (ForeignRelease){ .release = release, .base = src->data, .context = context };
    ArcBigarrayBuffer *b = ba_backing();
    *b = (ArcBigarrayBuffer){ .data = src->data, .bytes = src->byte_length, .owner = owner };
    ArcBigarray *a = ba_wrap(b, b->data, src->kind, src->layout, src->rank, src->dims);
    arc_mutator_leave(entered);
    return a;
}

int64_t caml_ba_create(int64_t kind, int64_t layout, int64_t dimensions)
{
    int n = arr_len_of(dimensions), k = kind >> 1, l = layout >> 1;
    const int64_t *d = (void *)(uintptr_t)dimensions;
    if (n > BA_MAX_DIMS || k < 0 || k >= 14 || l < 0 || l > 1)
        return ba_invalid("Bigarray.create: invalid dimensions");
    int64_t dims[BA_MAX_DIMS];
    size_t count = 1;
    for (int i = 0; i < n; i++) {
        int64_t dim = d[i] >> 1;
        if (dim < 0) return ba_invalid("Bigarray.create: negative dimension");
        if (dim != 0 && count > (SIZE_MAX / ba_sizes[k]) / (uint64_t)dim)
            return ba_invalid("Bigarray.create: size overflow");
        count *= (size_t)dim;
        dims[i] = dim;
    }
    ArcBigarrayBuffer *b = ba_backing();
    b->owner = NULL;
    b->bytes = count * ba_sizes[k];
    if (b->bytes == 0) b->bytes = 1;
    b->data = pal_page_alloc(b->bytes);
    if (b->data == NULL) pal_abort();
    return (int64_t)(uintptr_t)ba_wrap(b, b->data, k, l, n, dims);
}

static int ba_offset(const ArcBigarray *a, int n, const int64_t *indices, size_t *out)
{
    if (n != a->ndims) { ba_invalid("Bigarray.get/set: wrong number of indices"); return 0; }
    size_t offset = 0, stride = 1;
    for (int step = 0; step < n; step++) {
        int i = a->layout ? step : n - step - 1;
        int64_t index = (indices[i] >> 1) - a->layout;
        if (index < 0 || index >= a->dims[i]) {
            ocamlcc_raise_invalid_arg_oob(); return 0;
        }
        offset += (size_t)index * stride;
        stride *= (size_t)a->dims[i];
    }
    *out = offset; return 1;
}

static int64_t ba_read(const ArcBigarray *a, size_t offset)
{
    const uint8_t *p = a->data + offset * ba_sizes[a->kind];
    switch (a->kind) {
    case 0: return ocamlcc_alloc_float(*(const float *)p);
    case 1: return ocamlcc_alloc_float(*(const double *)p);
    case 2: return tag_int(*(const int8_t *)p);
    case 3: case 12: return tag_int(*p);
    case 4: return tag_int(*(const int16_t *)p);
    case 5: return tag_int(*(const uint16_t *)p);
    case 6: return ocamlcc_alloc_custom(ARC_CUSTOM_INT32, (uint64_t)(int64_t)*(const int32_t *)p);
    case 7: return ocamlcc_alloc_custom(ARC_CUSTOM_INT64, *(const uint64_t *)p);
    case 8: return tag_int(*(const int64_t *)p);
    case 9: return ocamlcc_alloc_custom(ARC_CUSTOM_NATIVEINT, *(const uint64_t *)p);
    case 10: case 11: {
        double *z = arc_alloc(ARC_TAG_FLOAT_ARRAY, 0, 16);
        z[0] = a->kind == 10 ? ((const float *)p)[0] : ((const double *)p)[0];
        z[1] = a->kind == 10 ? ((const float *)p)[1] : ((const double *)p)[1];
        return (int64_t)(uintptr_t)z;
    }
    case 13: return ocamlcc_alloc_float(ba_load_f16(p));
    default: pal_abort();
    }
}

static void ba_write(ArcBigarray *a, size_t offset, int64_t value)
{
    uint8_t *p = a->data + offset * ba_sizes[a->kind];
    switch (a->kind) {
    case 0: *(float *)p = (float)unbox_float(value); break;
    case 1: *(double *)p = unbox_float(value); break;
    case 2: case 3: case 12: *p = (uint8_t)(value >> 1); break;
    case 4: case 5: *(uint16_t *)p = (uint16_t)(value >> 1); break;
    case 6: *(int32_t *)p = (int32_t)unbox_custom_i64(value); break;
    case 7: case 9: *(int64_t *)p = unbox_custom_i64(value); break;
    case 8: *(int64_t *)p = value >> 1; break;
    case 10: case 11: {
        const double *z = (const void *)(uintptr_t)value;
        if (a->kind == 10) { ((float *)p)[0] = (float)z[0]; ((float *)p)[1] = (float)z[1]; }
        else { ((double *)p)[0] = z[0]; ((double *)p)[1] = z[1]; }
        break;
    }
    case 13: ba_store_f16(p, unbox_float(value)); break;
    }
}

static int64_t ba_get(int64_t v, int n, const int64_t *idx)
{
    ArcBigarray *a = (void *)(uintptr_t)v; size_t offset;
    return ba_offset(a, n, idx, &offset) ? ba_read(a, offset) : 1;
}
static int64_t ba_set(int64_t v, int n, const int64_t *idx, int64_t value)
{
    ArcBigarray *a = (void *)(uintptr_t)v; size_t offset;
    if (ba_offset(a, n, idx, &offset)) ba_write(a, offset, value);
    return 1;
}
int64_t caml_ba_get_generic(int64_t a, int64_t idx) { return ba_get(a, arr_len_of(idx), (void *)(uintptr_t)idx); }
int64_t caml_ba_set_generic(int64_t a, int64_t idx, int64_t v) { return ba_set(a, arr_len_of(idx), (void *)(uintptr_t)idx, v); }
/* Internal typed ABI. The compiler proves the element kind. Use the same
 * index and exception conventions as the boxed get/set primitives. */
double ocamlcc_ba_get_float64_1(int64_t value, int64_t index)
{
    ArcBigarray *a = (void *)(uintptr_t)value;
    size_t offset;
    return ba_offset(a, 1, &index, &offset) ? ((const double *)a->data)[offset] : 0.0;
}

void ocamlcc_ba_set_float64_1(int64_t value, int64_t index, double x)
{
    ArcBigarray *a = (void *)(uintptr_t)value;
    size_t offset;
    if (ba_offset(a, 1, &index, &offset)) ((double *)a->data)[offset] = x;
}

double ocamlcc_ba_get_float32_1(int64_t value, int64_t index)
{
    ArcBigarray *a = (void *)(uintptr_t)value;
    size_t offset;
    return ba_offset(a, 1, &index, &offset) ? (double)((const float *)a->data)[offset] : 0.0;
}

void ocamlcc_ba_set_float32_1(int64_t value, int64_t index, double x)
{
    ArcBigarray *a = (void *)(uintptr_t)value;
    size_t offset;
    if (ba_offset(a, 1, &index, &offset)) ((float *)a->data)[offset] = (float)x;
}

int32_t ocamlcc_ba_get_int32_1(int64_t value, int64_t index)
{
    ArcBigarray *a = (void *)(uintptr_t)value;
    size_t offset;
    return ba_offset(a, 1, &index, &offset) ? ((const int32_t *)a->data)[offset] : 0;
}

void ocamlcc_ba_set_int32_1(int64_t value, int64_t index, int32_t x)
{
    ArcBigarray *a = (void *)(uintptr_t)value;
    size_t offset;
    if (ba_offset(a, 1, &index, &offset)) ((int32_t *)a->data)[offset] = x;
}

int64_t ocamlcc_ba_get_int64_1(int64_t value, int64_t index)
{
    ArcBigarray *a = (void *)(uintptr_t)value;
    size_t offset;
    return ba_offset(a, 1, &index, &offset) ? ((const int64_t *)a->data)[offset] : 0;
}

void ocamlcc_ba_set_int64_1(int64_t value, int64_t index, int64_t x)
{
    ArcBigarray *a = (void *)(uintptr_t)value;
    size_t offset;
    if (ba_offset(a, 1, &index, &offset)) ((int64_t *)a->data)[offset] = x;
}

int64_t caml_ba_get_1(int64_t a, int64_t i) { return ba_get(a, 1, &i); }
int64_t caml_ba_get_2(int64_t a, int64_t i, int64_t j) { int64_t idx[] = {i,j}; return ba_get(a, 2, idx); }
int64_t caml_ba_get_3(int64_t a, int64_t i, int64_t j, int64_t k) { int64_t idx[] = {i,j,k}; return ba_get(a, 3, idx); }
int64_t caml_ba_set_1(int64_t a, int64_t i, int64_t v) { return ba_set(a, 1, &i, v); }
int64_t caml_ba_set_2(int64_t a, int64_t i, int64_t j, int64_t v) { int64_t idx[] = {i,j}; return ba_set(a, 2, idx, v); }
int64_t caml_ba_set_3(int64_t a, int64_t i, int64_t j, int64_t k, int64_t v) { int64_t idx[] = {i,j,k}; return ba_set(a, 3, idx, v); }
int64_t caml_ba_num_dims(int64_t v) { return tag_int(((ArcBigarray *)(uintptr_t)v)->ndims); }
int64_t caml_ba_kind(int64_t v) { return tag_int(((ArcBigarray *)(uintptr_t)v)->kind); }
int64_t caml_ba_layout(int64_t v) { return tag_int(((ArcBigarray *)(uintptr_t)v)->layout); }
int64_t caml_ba_dim(int64_t v, int64_t d)
{
    ArcBigarray *a = (void *)(uintptr_t)v; int64_t i = d >> 1;
    if (i < 0 || i >= a->ndims) return ba_invalid("Bigarray.dim");
    return tag_int(a->dims[i]);
}
int64_t caml_ba_change_layout(int64_t v, int64_t l)
{
    ArcBigarray *a = (void *)(uintptr_t)v; int layout = l >> 1;
    if (layout == a->layout) { arc_retain(a); return v; }
    if (layout != 0 && layout != 1) return ba_invalid("Bigarray.change_layout");
    int64_t dims[BA_MAX_DIMS];
    for (int i = 0; i < a->ndims; i++) dims[i] = a->dims[a->ndims - i - 1];
    return (int64_t)(uintptr_t)ba_view(a, a->ndims, dims, 0, layout);
}
int64_t caml_ba_sub(int64_t v, int64_t start, int64_t length)
{
    ArcBigarray *a = (void *)(uintptr_t)v;
    if (a->ndims == 0) return ba_invalid("Bigarray.sub: bad sub-array");
    int dim = a->layout ? a->ndims - 1 : 0;
    int64_t offset = (start >> 1) - a->layout, len = length >> 1;
    if (offset < 0 || len < 0 || offset > a->dims[dim] || len > a->dims[dim] - offset)
        return ba_invalid("Bigarray.sub: bad sub-array");
    size_t stride = 1;
    for (int i = 0; i < a->ndims; i++) if (i != dim) stride *= a->dims[i];
    ArcBigarray *b = ba_view(a, a->ndims, a->dims, (size_t)offset * stride, a->layout);
    b->dims[dim] = len;
    return (int64_t)(uintptr_t)b;
}
int64_t caml_ba_slice(int64_t v, int64_t indices)
{
    ArcBigarray *a = (void *)(uintptr_t)v;
    int n = arr_len_of(indices);
    if (n > a->ndims) return ba_invalid("Bigarray.slice: too many indices");
    const int64_t *idx = (void *)(uintptr_t)indices;
    size_t offset = 0, stride = 1;
    for (int step = 0; step < a->ndims; step++) {
        int i = a->layout ? step : a->ndims - step - 1;
        int fixed = a->layout ? i >= a->ndims - n : i < n;
        if (fixed) {
            int j = a->layout ? i - (a->ndims - n) : i;
            int64_t x = (idx[j] >> 1) - a->layout;
            if (x < 0 || x >= a->dims[i]) { ocamlcc_raise_invalid_arg_oob(); return 1; }
            offset += (size_t)x * stride;
        }
        stride *= a->dims[i];
    }
    return (int64_t)(uintptr_t)ba_view(a, a->ndims - n, a->dims + (a->layout ? 0 : n), offset, a->layout);
}
int64_t caml_ba_reshape(int64_t v, int64_t dimensions)
{
    ArcBigarray *a = (void *)(uintptr_t)v; int n = arr_len_of(dimensions);
    if (n > BA_MAX_DIMS) return ba_invalid("Bigarray.reshape: bad number of dimensions");
    int64_t dims[BA_MAX_DIMS]; size_t count = 1;
    const int64_t *idx = (void *)(uintptr_t)dimensions;
    for (int i = 0; i < n; i++) {
        dims[i] = idx[i] >> 1;
        if (dims[i] < 0 || (dims[i] && count > SIZE_MAX / (uint64_t)dims[i]))
            return ba_invalid("Bigarray.reshape: size mismatch");
        count *= (size_t)dims[i];
    }
    if (count != ba_count(a)) return ba_invalid("Bigarray.reshape: size mismatch");
    return (int64_t)(uintptr_t)ba_view(a, n, dims, 0, a->layout);
}
int64_t caml_ba_fill(int64_t v, int64_t x)
{
    ArcBigarray *a = (void *)(uintptr_t)v;
    size_t n = ba_count(a);
    for (size_t i = 0; i < n; i++) ba_write(a, i, x);
    return 1;
}
int64_t caml_ba_blit(int64_t src, int64_t dst)
{
    ArcBigarray *s = (void *)(uintptr_t)src, *d = (void *)(uintptr_t)dst;
    if (s->ndims != d->ndims || s->kind != d->kind || s->layout != d->layout)
        return ba_invalid("Bigarray.blit: dimension mismatch");
    for (int i = 0; i < s->ndims; i++) if (s->dims[i] != d->dims[i])
        return ba_invalid("Bigarray.blit: dimension mismatch");
    size_t n = ba_count(s) * ba_sizes[s->kind];
    if ((uintptr_t)d->data > (uintptr_t)s->data) {
        for (size_t i = n; i > 0; i--) d->data[i - 1] = s->data[i - 1];
    } else {
        for (size_t i = 0; i < n; i++) d->data[i] = s->data[i];
    }
    return 1;
}

static int ba_compare(const ArcBigarray *a, const ArcBigarray *b, int total)
{
    int fa = a->kind + 256 * a->layout, fb = b->kind + 256 * b->layout;
    if (fa != fb) return fb < fa ? -1 : 1;
    if (a->ndims != b->ndims) return b->ndims < a->ndims ? -1 : 1;
    for (int i = 0; i < a->ndims; i++) if (a->dims[i] != b->dims[i])
        return a->dims[i] < b->dims[i] ? -1 : 1;
    size_t count = ba_count(a);
#define BA_CMP(T) do { const T *x = (const void *)a->data, *y = (const void *)b->data; \
    for (size_t i = 0; i < count; i++) { if (x[i] < y[i]) return -1; if (x[i] > y[i]) return 1; } return 0; } while (0)
#define BA_FCMP(T) do { const T *x = (const void *)a->data, *y = (const void *)b->data; \
    for (size_t i = 0; i < count; i++) { int c = compare_f64_raw(x[i], y[i], total); if (c) return c; } return 0; } while (0)
    switch (a->kind) {
    case 2: BA_CMP(int8_t);
    case 3: case 12: BA_CMP(uint8_t);
    case 4: BA_CMP(int16_t);
    case 5: BA_CMP(uint16_t);
    case 6: BA_CMP(int32_t);
    case 7: case 8: case 9: BA_CMP(int64_t);
    case 10: count *= 2; /* fall through */
    case 0: BA_FCMP(float);
    case 11: count *= 2; /* fall through */
    case 1: BA_FCMP(double);
    case 13: {
        for (size_t i = 0; i < count; i++) {
            double x = ba_load_f16(a->data + i * 2);
            double y = ba_load_f16(b->data + i * 2);
            int c = compare_f64_raw(x, y, total);
            if (c != 0) return c;
        }
        return 0;
    }
    default: pal_abort();
    }
#undef BA_CMP
#undef BA_FCMP
}

static uint32_t ba_hash(const ArcBigarray *a)
{
    size_t n = ba_count(a); uint32_t h = 0;
    int k = a->kind;
    if (k == 2 || k == 3 || k == 12 || k == 4 || k == 5) {
        size_t bytes = n * ba_sizes[k]; if (bytes > 256) bytes = 256;
        for (size_t i = 0; i < bytes; i += 4) {
            uint32_t word = 0;
            for (size_t j = 0; j < 4 && i + j < bytes; j++) word |= (uint32_t)a->data[i+j] << (8*j);
            h = hash_mix32(h, word);
        }
    } else {
        if (k == 10 || k == 11) n *= 2;
        size_t limit = (k == 7 || k == 1 || k == 11) ? 32 : (k == 13 ? 128 : 64);
        if (n > limit) n = limit;
        for (size_t i = 0; i < n; i++) {
            switch (k) {
            case 6: h = hash_mix32(h, ((const uint32_t *)a->data)[i]); break;
            case 7: h = hash_mix_int64(h, ((const int64_t *)a->data)[i]); break;
            case 8: case 9: h = hash_mix_intnat(h, ((const int64_t *)a->data)[i]); break;
            case 1: case 11: h = hash_mix_f64(h, ((const double *)a->data)[i]); break;
            case 0: case 10: h = hash_mix_f64(h, ((const float *)a->data)[i]); break;
            case 13: h = hash_mix_f64(h, ba_load_f16(a->data + i * 2)); break;
            }
        }
    }
    return h;
}
