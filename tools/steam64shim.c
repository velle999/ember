/* steam64shim.c — make uname(2) report x86_64.
 *
 * Steam's client calls Is64BitOS() (in steamui.so) which reads uname() and
 * compares utsname.machine. On a 32-bit-only host that is "i686", the check
 * fails and the client asserts. Every other part of the 32-bit client works:
 * it downloads, extracts, loads the 32-bit steamui.so and reports
 * "Running Steam on void  32-bit".
 *
 * This overrides only utsname.machine, and only for processes it is preloaded
 * into. It is a compatibility shim for running the client on the hardware it
 * is installed on — it changes no Steam file on disk.
 *
 * ⚠ This does NOT make the machine 64-bit. Anything that actually needs to
 * execute a 64-bit binary (Steam's ubuntu12_64 helpers, and any 64-bit game)
 * still cannot. It only gets past the check.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#define _GNU_SOURCE
#include <sys/utsname.h>
#include <string.h>
#include <dlfcn.h>

static int (*real_uname)(struct utsname *) = 0;

int uname(struct utsname *buf)
{
    if (!real_uname)
        real_uname = (int (*)(struct utsname *))dlsym(RTLD_NEXT, "uname");
    if (!real_uname)
        return -1;
    int r = real_uname(buf);
    if (r == 0 && buf) {
        /* strncpy, not strcpy: utsname.machine is a fixed 65-byte field and
         * glibc does not guarantee it is the last member. */
        strncpy(buf->machine, "x86_64", sizeof(buf->machine) - 1);
        buf->machine[sizeof(buf->machine) - 1] = '\0';
    }
    return r;
}
