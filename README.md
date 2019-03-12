# ptmalloc2 heap dumper and visualizer

This is a tool for dumping the ptmalloc2 heap into a file, and for visualizing that dump. I wrote this as part of my research into [what causes memory bloating in Ruby](https://vimeo.com/322007980).

## Dumper

ptmallocdump.c is a library responsible for dumping the heap to a file.

### Warning

This dumper has only been tested on Ubuntu 18.04. The dumper relies on specific glibc/ptmalloc2 internals, so it will most likely break if you use it on any other OS/distro/glibc version.

This dumper is also *not thread-safe*. It does not acquire any ptmalloc2 mutexes. When using it, make sure that the process you're dumping is idling in all threads.

### Compilation

Compile it as follows:

    gcc -shared -g ptmallocdump.c -fPIC -o libptmallocdump.so -Wall -fno-strict-aliasing

### Usage

This library contains two functions that you must call in order to dump the heap of the current process:

    void dump_main_heap(const char *path, void *main_arena);
    void dump_non_main_heaps(const char *path, void *main_arena);

If you want to call this library from Ruby then you can use FFI to load it:

~~~ruby
require 'ffi'

module PtmallocDumper
  extend FFI::Library
  ffi_lib '/path-to/libptmallocdump.so'

  attach_function :dump_non_main_heaps, [:string, :size_t], :void
  attach_function :dump_main_heap, [:string, :size_t], :void
end
~~~

`dump_main_heap` dumps the ptmalloc2 main heap, while `dump_non_main_heaps` dumps all the other (i.e. non-main) heaps. For a full dump, you must call both functions.

`path` is the file to which to dump to. That file will be opened in append mode so it's fine if you pass the same filename to both functions.

`main_arena` is the address of the `main_arena` static global variable in glibc's malloc/arena.c. You can find out what that address is through the following method. It is required to have the glibc debugging symbols installed (`libc6-dbg` package).

 1. Obtain the relative address of the 'main_arena' variable within glibc:

        objdump -t /usr/lib/debug/lib/x86_64-linux-gnu/libc-2.27.so | grep ' main_arena' | awk '{ print $1 }'

 2. Obtain the base address of the glibc library mapping in the process that you want to dump:

        grep '/libc-2.27.so$' /proc/<PID>/maps | grep ' r-xp ' | cut -d- -f 1

 3. Sum both addresses. That's the address to pass to the `main_arena` argument for those function calls.

## Visualizer

### Requirements

    gem install oily_png --no-document

### Usage

    ruby ./visualize_heap.rb <DUMPFILE> <OUTPUT DIR>
