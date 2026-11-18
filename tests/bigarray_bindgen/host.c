#include "vectors.h"
#include "peer.h"
#include <assert.h>

OcamlccBigarrayView *vectors_native_buffer(unsigned rank);

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
