# Leak Detector #

This tool is designed to help detect memory leaks in Ada programs, particularly on macOS.

The inspiration was the AdaCore tool [`gnatmem`](https://docs.adacore.com/gnat_ugn-docs/html/gnat_ugn/gnat_ugn/gnat_and_program_execution.html#the-gnatmem-tool), which isn't available on macOS and appears to be no longer available to the community. This tool offers _many_ fewer options.

## Installation ##

Build with `alr build`. This should end with an invocation of the tool on a sample data file, which was generated on macOS from this program:
``` ada
with Ada.Text_IO; use Ada.Text_IO;
procedure Leak_Detector_Check is
   type IP is access Integer;
   File : File_Type;
   IA : IP := new Integer'(42);
begin
   Open (File, Name => "leak_detector_check.adb", Mode => In_File);
end Leak_Detector_Check;
```
and report this information:
```
start time: 2023-01-12 15:50:32.09
a: 600000004030  4 100003B64
a: 600002C00080  128 100009C6C
a: 600000004040  12 100010219
a: 6000026000C0  92 100010271
d: 6000026000C0 100010493
d: 600000004040 1000104BB
d: 600002C00080 1000104E5
 4 allocated from 100003B64 in 1 call(s)
100003B64
```

## Use ##

The program under test needs to be linked against a special version of the memory management package, in the library `libgmem.a`.

On macOS (and probably on other operating systems) the normal linking process generates position-independent executables (PIE), which are loaded to addresses randomly allocated by the OS so as to make hacking more difficult. We don't want that to happen in this case, since the addresses output by `libgmem.a` are absolute.

To build the sample program (see above; source in `share/leak_detector/leak_detector_check.adb`) for checking, say
```
gnatmake -g leak_detector_check -largs -no-pie -lgmem
```

Running the program generates a log file `gmem.out`.

Processing the log file with this program gives
```
$ leak_detector gmem.out
100003B64
```

We can see allocations and deletions using
```
$ leak_detector -v
start time: 2023-01-12 15:50:32.09
a: 600000004030  4 100003B64
a: 600002C00080  128 100009C6C
a: 600000004040  12 100010219
a: 6000026000C0  92 100010271
d: 6000026000C0 100010493
d: 600000004040 1000104BB
d: 600002C00080 1000104E5
 4 allocated from 100003B64 in 1 call(s)
100003B64
```
where

* the `start time` line gives the time when the program was run (will this be correct in daylight saving time?),
* the `a` lines show the address of allocated memory, the number of bytes allocated, and the program address from which the allocation was made
* the `d` lines show the address of deallocated memory and the program address from which the allocation was freed
* unfreed allocations are reported (all the above to standard error)
* finally, to standard output, the addresses from which allocations were made.

Translating this using `atos` (a rough macOS equivalent of `addr2ine`) gives
```
$ atos -o leak_detector_check 100003B64 100009C6C 100010219 100010271 100010493 1000104BB 1000104E5
_ada_leak_detector_check (in leak_detector_check) (leak_detector_check.adb:5)
ada__text_io__afcb_allocate__2 (in leak_detector_check) (a-textio.adb:161)
system__file_io__open__record_afcb.3 (in leak_detector_check) (s-fileio.adb:841)
system__file_io__open__record_afcb.3 (in leak_detector_check) (s-fileio.adb:842)
system__file_io__close (in leak_detector_check) (s-fileio.adb:317)
system__file_io__close (in leak_detector_check) (s-fileio.adb:318)
system__file_io__close (in leak_detector_check) (s-fileio.adb:319)
```
in which the actual leak is reported where one would expect; the remaining allocations, all properly deallocated, are in the runtime.
