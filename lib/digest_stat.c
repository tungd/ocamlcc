#if !defined(__APPLE__) && !defined(_WIN32)
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdint.h>
#include <sys/stat.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>

CAMLprim value ocpkg_digest_stat(value path)
{
    CAMLparam1(path);
    CAMLlocal4(result, device, inode, size);
    struct stat info;
    caml_unix_check_path(path, "stat");
    if (stat(String_val(path), &info) != 0) caml_uerror("stat", path);

    device = caml_copy_int64((int64_t) info.st_dev);
    inode = caml_copy_int64((int64_t) info.st_ino);
    size = caml_copy_int64((int64_t) info.st_size);
    result = caml_alloc_tuple(7);
    Store_field(result, 0, device);
    Store_field(result, 1, inode);
    Store_field(result, 2, size);
    Store_field(result, 3, Val_long(info.st_mtime));
    Store_field(result, 5, Val_long(info.st_ctime));
#if defined(__APPLE__)
    Store_field(result, 4, Val_long(info.st_mtimespec.tv_nsec));
    Store_field(result, 6, Val_long(info.st_ctimespec.tv_nsec));
#elif defined(_WIN32)
    Store_field(result, 4, Val_long(0));
    Store_field(result, 6, Val_long(0));
#else
    Store_field(result, 4, Val_long(info.st_mtim.tv_nsec));
    Store_field(result, 6, Val_long(info.st_ctim.tv_nsec));
#endif
    CAMLreturn(result);
}
