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

intptr_t ffi_digits_native(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e,
                           int64_t f, int64_t g, int64_t h, intptr_t i) {
    const int64_t tagged[] = {a, b, c, d, e, f, g, h};
    intptr_t prefix = 0;
    for (unsigned j = 0; j < sizeof tagged / sizeof *tagged; j++)
        prefix = prefix * 10 + (tagged[j] >> 1);
    return prefix * 10 + i;
}

int64_t ffi_null_value(int64_t unit) {
    (void)unit;
    return 0;
}

int64_t ffi_observe(int64_t value) {
    (void)value;
    return 1;
}
