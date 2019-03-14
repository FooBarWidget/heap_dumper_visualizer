
CFLAGS  = -g -fPIC -DPIC -Wall -fno-strict-aliasing
LDFLAGS =
CC      = gcc -std=c99
RM      = rm -f

DUMPER_SRC = ptmallocdump.c
DUMPER_LIB = libptmallocdump.so

TARGETS = $(DUMPER_LIB)


all: build
build: $(TARGETS)

$(DUMPER_LIB): $(DUMPER_SRC)
	$(CC) $(CFLAGS) -shared $^ $(LDFLAGS) -o $@

clean:
	@for file in $(TARGETS) ; do \
	    if test -f "$$file" ; then \
	        echo "$(RM) \"$$file\"" ; \
	        $(RM) "$$file" ; \
	    fi ; \
	done

.PHONY: all build clean
