# ember-egl-glx — build the EGL-over-GLX translator for the 304 stack.
#
# ⚠ Builds ON the target (i686); the P4 has gcc and make but no -devel
# packages, which is why the source declares the ABI itself and links nothing.
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -fPIC
PREFIX  ?= /opt/x11-19/lib/nvidia

all: libEGL.so.1

libEGL.so.1: ember-egl-glx.c
	$(CC) $(CFLAGS) -shared -o $@ $< -Wl,-soname,libEGL.so.1 -ldl
	@echo "built $@"

# ⛔ Installed into the 304 directory ONLY. 50-ember-gl.sh puts that directory
# on LD_LIBRARY_PATH when, and only when, /run/ember-gpu says nvidia304 — so on
# a nouveau boot this library is never on any search path and Mesa's real EGL
# is used untouched.
install: libEGL.so.1
	install -Dm755 libEGL.so.1 $(DESTDIR)$(PREFIX)/libEGL.so.1
	ln -sf libEGL.so.1 $(DESTDIR)$(PREFIX)/libEGL.so

clean:
	rm -f libEGL.so.1

.PHONY: all install clean
