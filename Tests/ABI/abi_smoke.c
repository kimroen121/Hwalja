#include "HwpEngineABI.h"
#include <assert.h>
#include <stddef.h>

int main(void) {
    assert(hwp_engine_abi_version() == 1);
    hwp_engine_string_free(NULL);
    return 0;
}
