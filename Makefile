
CFLAGS  = -g -fPIC -DPIC -Wall -fno-strict-aliasing
LDFLAGS =
CC      = gcc -std=c99
RM      = rm -f

DUMPER_SRC = ptmallocdump.c
DUMPER_LIB = libptmallocdump.so

GLIBC_MAIN_ARENA_CACHE = glibc_main_arena_address

TARGETS = $(DUMPER_LIB) $(GLIBC_MAIN_ARENA_CACHE)


all: build
build: $(TARGETS)

$(DUMPER_LIB): $(DUMPER_SRC)
	$(CC) $(CFLAGS) -shared $^ $(LDFLAGS) -o $@

$(GLIBC_MAIN_ARENA_CACHE): $(DUMPER_LIB)
	./find_main_arena.sh > $@

clean:
	@for file in $(TARGETS) ; do \
	    if test -f "$$file" ; then \
	        echo "$(RM) \"$$file\"" ; \
	        $(RM) "$$file" ; \
	    fi ; \
	done

.PHONY: all build clean
