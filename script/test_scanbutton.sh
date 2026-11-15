#!/usr/bin/env bash
# Offline protocol/lifecycle tests: mock SANE never discovers or opens hardware.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/script/backend-versions.sh"
TEMP="$(mktemp -d /private/tmp/canonscan-button-tests.XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT
# Use the pinned upstream public headers without needing a backend rebuild.
mkdir -p "$TEMP/headers"
tar -xzf "$ROOT/.dependencies/downloads/$SANE_ARCHIVE" -C "$TEMP/headers" "sane-backends-$SANE_VERSION/include/sane/sane.h"
cat > "$TEMP/mock.c" <<'C'
#include <sane/sane.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int reads;
static int closed;
SANE_Status sane_init(SANE_Int *version, SANE_Auth_Callback callback) {
    (void)version; (void)callback; return SANE_STATUS_GOOD;
}
SANE_Status sane_open(SANE_String_Const device, SANE_Handle *handle) {
    (void)device; *handle = (void *)1; return SANE_STATUS_GOOD;
}
void sane_close(SANE_Handle handle) { (void)handle; closed = 1; }
void sane_exit(void) {
    if (!closed) abort();
    /* Same pipe as protocol output so ordering is observable across cleanup. */
    puts("MOCK_CLOSED");
}
SANE_String_Const sane_strstatus(SANE_Status status) { (void)status; return "mock error"; }
const SANE_Option_Descriptor *sane_get_option_descriptor(SANE_Handle handle, SANE_Int index) {
    (void)handle; (void)index;
    static SANE_Option_Descriptor option = {
        .name = "start", .type = SANE_TYPE_BOOL,
        .size = sizeof(SANE_Bool), .cap = SANE_CAP_SOFT_DETECT
    };
    if (getenv("MOCK_UNSUPPORTED")) option.cap = SANE_CAP_INACTIVE;
    return &option;
}
SANE_Status sane_control_option(SANE_Handle handle, SANE_Int index,
                               SANE_Action action, void *value, SANE_Int *info) {
    (void)handle; (void)action; (void)info;
    if (!index) { *(SANE_Int *)value = 2; return SANE_STATUS_GOOD; }
    const char *sequence = getenv("MOCK_SEQUENCE");
    if (!sequence) sequence = "001";
    if (getenv("MOCK_CANCEL") && reads == 1) raise(SIGTERM);
    if (getenv("MOCK_ERROR") && reads == 1) return SANE_STATUS_IO_ERROR;
    size_t position = (size_t)reads++;
    size_t length = strlen(sequence);
    *(SANE_Bool *)value = sequence[position < length ? position : length - 1] == '1';
    fprintf(stderr, "MOCK_READ_%d\n", reads);
    return SANE_STATUS_GOOD;
}
C
xcrun clang -Wall -Wextra -Werror \
  -I"$TEMP/headers/sane-backends-$SANE_VERSION/include" \
  "$ROOT/Backend/scanbutton.c" "$TEMP/mock.c" -o "$TEMP/scanbutton-test"
python3 - "$TEMP/scanbutton-test" <<'PY'
import os
import subprocess
import sys

binary = sys.argv[1]
cases = [
    ('new press', {'MOCK_SEQUENCE': '001'}, 0, 'READY\nMOCK_CLOSED\nSTART\n', 3),
    ('startup latch and held button', {'MOCK_SEQUENCE': '11001'}, 0,
     'READY\nMOCK_CLOSED\nSTART\n', 5),
    ('unsupported', {'MOCK_UNSUPPORTED': '1'}, 1, 'MOCK_CLOSED\n', 0),
    ('SIGTERM', {'MOCK_CANCEL': '1'}, 2, 'READY\nMOCK_CLOSED\n', 2),
    ('read error', {'MOCK_ERROR': '1'}, 9, 'READY\nMOCK_CLOSED\n', 1),
]
for name, environment, code, output, reads in cases:
    result = subprocess.run(
        [binary, '--device-name', 'mock'],
        env={**os.environ, **environment}, capture_output=True, text=True, timeout=4,
    )
    assert (result.returncode, result.stdout) == (code, output), (name, result)
    assert result.stderr.count('MOCK_READ_') == reads, (name, result)
    print('PASS:', name)
for arguments, code in [(['--version'], 0), ([], 4), (['--device-name', ''], 4)]:
    result = subprocess.run([binary, *arguments], capture_output=True, text=True, timeout=1)
    assert result.returncode == code, result
    assert 'MOCK_CLOSED' not in result.stdout, result
print('PASS: offline CLI bypasses SANE')
PY
