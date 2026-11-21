#include <stdint.h>

double ffi_double(double number) {
    return number * 2.0;
}

int64_t ffi_mixed(intptr_t offset, double scale, int32_t narrow,
                  int64_t wide, intptr_t native) {
    return (int64_t)((double)offset / scale) + narrow + wide + native;
}

intptr_t ffi_step(intptr_t number) {
    return number - 3;
}

int64_t ffi_null_value(int64_t unit) {
    (void)unit;
    return 0;
}

int64_t ffi_observe(int64_t value) {
    (void)value;
    return 1;
}
