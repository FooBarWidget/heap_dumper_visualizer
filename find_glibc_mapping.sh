#!/bin/sh

die() {
    echo "$0: ERROR - $*" 1>&2
    exit 1
}

show_usage() {
    echo "Usage: $0 [options] <pid>"
    echo
    echo "OPTIONS"
    echo "    -a, --add OFFSET  Add the given hexidecimal offset"
    echo "                        to the mapped base address."
}

if test $# -lt 1 ; then
    show_usage
    exit 1
fi

mode=print
offset=0

if type getopt 2>&1 >/dev/null ; then
    # have GNU getopt (allows nicer options)
    SOPT="ha:"
    LOPT="help,add:"
    OPTIONS=$(getopt -o "$SOPT" --long "$LOPT" -n "$0" -- "$@") || exit 1
    eval set -- "$OPTIONS"
fi

while true ; do
    case "$1" in
        -h | --help)  show_usage ;  exit 0 ;;
        -a | --add)   mode=add ; offset=$2 ; shift 2 ;;
        --) shift ; break ;;
        -*) die "bad opt: $1" ;;
        *) break ;;
    esac
done

pid=$1

find_mapping_addr() {
    grep '/libc-[0-9.]*\.so$' /proc/${pid}/maps |
        grep ' r-xp ' |
        cut -d- -f 1
}

mapping_addr="$(find_mapping_addr)"

sum_base_and_offset() {
    echo "ibase = 16; obase = 10; ${offset} + ${mapping_addr}" | bc
}

case $mode in
    print) echo "${mapping_addr}"        ;;
    add)   sum_base_and_offset           ;;
    *)     die "not a mode: \"${mode}\"" ;;
esac
