#define _POSIX_C_SOURCE 200809L
#include "arc.h"
#include <math.h>
#include <stdint.h>
#include <time.h>

int64_t ocpkg_test_gmtime(int64_t value)
{
    double seconds = *(double *)(uintptr_t)value;
    /* Ptime's calendar interval, including its final fractional second. */
    if (!isfinite(seconds) || seconds < -62167219200.0 || seconds >= 253402300800.0)
        return 1;
    time_t timestamp = (time_t)floor(seconds);
    struct tm tm;
    if (!gmtime_r(&timestamp, &tm)) return 1;
    int values[9] = {tm.tm_sec, tm.tm_min, tm.tm_hour, tm.tm_mday, tm.tm_mon,
                     tm.tm_year, tm.tm_wday, tm.tm_yday, tm.tm_isdst > 0};
    int64_t *record = arc_alloc(0, 9, 9 * sizeof(int64_t));
    for (int i = 0; i < 9; ++i) record[i] = (int64_t)(((uint64_t)(int64_t)values[i] << 1) | 1);
    int64_t *some = arc_alloc(0, 1, sizeof(int64_t));
    some[0] = (int64_t)(uintptr_t)record;
    return (int64_t)(uintptr_t)some;
}
