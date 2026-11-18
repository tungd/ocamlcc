#include "vectors.h"
#include "peer.h"
#include <assert.h>
#include <stdlib.h>

OcamlccBigarrayView *vectors_native_buffer(unsigned rank);

typedef struct { void *base; int releases; } Owner;

static void release_buffer(void *base, void *context)
{
    Owner *owner = context;
    assert(base == owner->base && owner->releases == 0);
    owner->releases++;
    free(base);
}

static void check_import(void)
{
    ocamlcc_error_t err = {0};
    double *data = malloc(6 * sizeof(*data));
    assert(data);
    Owner owner = {data, 0};
    int64_t dims[] = {2, 3};
    OcamlccBigarrayInfo src = {data, 6 * sizeof(*data), dims, 2, OCAMLCC_BA_FLOAT64, OCAMLCC_BA_C_LAYOUT};
    OcamlccBigarrayView *matrix = ocamlcc_Vectors_view_import(&src, release_buffer, &owner);
    assert(matrix);
    dims[1] = 0; /* The stack dimensions are no longer borrowed. */
    OcamlccBigarrayView *row = vectors_row(matrix, 1, &err);
    assert(row && !err.code);
    double *cells = ocamlcc_Vectors_view_info(row).data;
    assert(cells == data + 3);
    cells[0] = 42.0;
    vectors_save(row, &err);
    assert(!err.code);
    ocamlcc_Vectors_view_release(matrix);
    ocamlcc_Vectors_view_release(row);
    assert(owner.releases == 0 && data[3] == 42.0);
    vectors_write_saved(19.0, &err);
    assert(!err.code && data[3] == 19.0);
    vectors_clear(&err);
    assert(!err.code && owner.releases == 1);
}

static void release_and_collect(void *base, void *context)
{
    release_buffer(base, context);
    ocamlcc_error_t err = {0};
    OcamlccBigarrayView *other = vectors_create(1, &err);
    assert(other && !err.code);
    vectors_leave_cycle(other, &err);
    assert(!err.code);
    ocamlcc_Vectors_view_release(other);
    assert(vectors_collect(&err) > 0 && !err.code);
}

static void check_collected_import(void)
{
    ocamlcc_error_t err = {0};
    int64_t len = 1;
    Owner owner = {malloc(sizeof(double)), 0};
    assert(owner.base);
    OcamlccBigarrayInfo src = {owner.base, sizeof(double), &len, 1, OCAMLCC_BA_FLOAT64, OCAMLCC_BA_C_LAYOUT};
    OcamlccBigarrayView *view = ocamlcc_Vectors_view_import(&src, release_and_collect, &owner);
    assert(view);
    vectors_leave_cycle(view, &err);
    assert(!err.code);
    ocamlcc_Vectors_view_release(view);
    assert(!owner.releases);
    assert(vectors_collect(&err) > 0 && !err.code && owner.releases == 1);
}

static void check_matrix_row(void)
{
    ocamlcc_error_t err = {0};
    OcamlccBigarrayView *matrix = vectors_matrix(2, 3, &err);
    assert(matrix && !err.code);
    OcamlccBigarrayInfo m = ocamlcc_Vectors_view_info(matrix);
    assert(m.rank == 2 && m.dims[0] == 2 && m.dims[1] == 3);
    double *data = m.data;
    data[4] = 42.0;
    assert(vectors_row(matrix, 2, &err) == NULL && err.code);
    OcamlccBigarrayView *row = vectors_row(matrix, 1, &err);
    assert(row && !err.code);
    assert(vectors_row(row, 0, &err) == NULL && err.code);
    OcamlccBigarrayInfo r = ocamlcc_Vectors_view_info(row);
    assert(r.rank == 1 && r.dims[0] == 3 && r.byte_length == 3 * sizeof(double));
    assert(r.data == data + 3);
    ocamlcc_Vectors_view_release(matrix);
    double *cells = r.data;
    assert(cells[1] == 42.0);
    cells[2] = 17.0;
    OcamlccBigarrayView *cell = vectors_sub(row, 2, 1, &err);
    assert(cell && !err.code);
    ocamlcc_Vectors_view_release(row);
    assert(*(double *)ocamlcc_Vectors_view_info(cell).data == 17.0);
    ocamlcc_Vectors_view_release(cell);
}

int main(void)
{
    ocamlcc_error_t err = {0};
    vectors_init();
    peer_init();
    int64_t baseline = vectors_live(&err);
    check_import();
    check_collected_import();
    check_matrix_row();
    OcamlccBigarrayView *matrix = vectors_native_buffer(2);
    assert(matrix && vectors_sub(matrix, 0, 1, &err) == NULL && err.code);
    ocamlcc_Vectors_view_release(matrix);
    OcamlccBigarrayView *buffer = vectors_native_buffer(1);
    OcamlccBigarrayView *borrowed_slice = vectors_sub(buffer, 0, 1, &err);
    assert(borrowed_slice && !err.code);
    ocamlcc_Vectors_view_release(buffer);
    ocamlcc_Vectors_view_release(borrowed_slice);
    OcamlccBigarrayView *foreign = peer_create(2, &err);
    assert(foreign && !err.code);
    assert(vectors_sub(foreign, 0, 1, &err) == NULL && err.code);
    OcamlccBigarrayView *local = peer_sub(foreign, 0, 1, &err);
    assert(local && !err.code);
    ocamlcc_Peer_view_release(foreign);
    ocamlcc_Peer_view_release(local);
    OcamlccBigarrayView *parent = vectors_create(4, &err);
    assert(parent && !err.code);
    double *source = ocamlcc_Vectors_view_info(parent).data;
    source[1] = 42.0;
    assert(vectors_sub(NULL, 0, 1, &err) == NULL && err.code);
    OcamlccBigarrayView *wrong_layout = vectors_fortran(&err);
    assert(wrong_layout && !err.code);
    assert(vectors_sub(wrong_layout, 1, 1, &err) == NULL && err.code);
    ocamlcc_Vectors_view_release(wrong_layout);
    OcamlccBigarrayView *wrong_kind = vectors_singles(&err);
    assert(wrong_kind && !err.code);
    assert(vectors_sub(wrong_kind, 0, 1, &err) == NULL && err.code);
    ocamlcc_Vectors_view_release(wrong_kind);

    /* OCaml raises for this range. The error path leaves parent owned by C. */
    assert(vectors_sub(parent, 4, 1, &err) == NULL && err.code);
    OcamlccBigarrayView *sub = vectors_sub(parent, 1, 2, &err);
    assert(sub && !err.code);
    OcamlccBigarrayInfo info = ocamlcc_Vectors_view_info(sub);
    assert(info.rank == 1 && info.dims[0] == 2 && info.byte_length == 2 * sizeof(double));
    assert(info.data == source + 1);
    ((double *)info.data)[1] = 17.0;
    assert(source[2] == 17.0);
    ocamlcc_Vectors_view_release(parent);
    assert(((double *)info.data)[0] == 42.0);
    ocamlcc_Vectors_view_release(sub);
    assert(vectors_live(&err) == baseline);
    return 0;
}
