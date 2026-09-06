/* steam64shim.c — make uname(2) report x86_64.
 *
 * Steam's client calls Is64BitOS() (in steamui.so) which reads uname() and
 * compares utsname.machine. On a 32-bit-only host that is "i686", the check
 * fails and the client asserts. Every other part of the 32-bit client works:
 * it downloads, extracts, loads the 32-bit steamui.so and reports
 * "Running Steam on void  32-bit".
 *
 * ⛔ THIS DOES NOT WORK, AND IS KEPT ONLY AS A DOCUMENTED FAILURE.
 *
 * It does get past the assert. Steam then tries to start what the check was
 * gating — steamwebhelper under the 64-bit pressure-vessel runtime — and those
 * are 64-bit ELFs a 32-bit kernel cannot execute, so the shell parses them as
 * text ("ELF: not found", "Syntax error: ')' unexpected"). Since the 2023 UI
 * rewrite steamwebhelper IS the interface, so it never renders, the main loop
 * stalls, and the machine appears to freeze.
 *
 * The check is load-bearing. Do not reach for this again.
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
