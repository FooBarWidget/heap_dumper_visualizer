#!/bin/sh

DEBUG_FILE_DIR="/usr/lib/debug"

die() {
    echo "$0: ERROR - $*" 1>&2
    exit 1
}

DUMPER_LIB="$( grep ^DUMPER_LIB Makefile | awk '{ print $3 }' )"
if ! test -f "${DUMPER_LIB}" ; then
    die "missing DUMPER_LIB (\"${DUMPER_LIB}\")"
fi

libc_soname_path() {
    ldd "${DUMPER_LIB}" |
        tr -d '\t'      |
        grep ^libc.so.6  |
        awk '{ print $3 }'
}

real_libc_path="$( readlink -e "$(libc_soname_path)" )"
libc_debug_path="${DEBUG_FILE_DIR}/${real_libc_path}.debug"

if ! test -f "${libc_debug_path}" ; then
    die "missing libc debug symbols \"${libc_debug_path}\""
fi

objdump -t "${libc_debug_path}" | grep ' main_arena' | awk '{ print $1 }'
