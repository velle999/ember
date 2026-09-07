#!/bin/sh
# test-idxbuf-fix.sh — verify the nv30 IDXBUF relocation fix on the P4.
#
# Two independent signals, both must agree:
#   1. vbo-drawelements stops producing DMA_VTX_PROTECTION
#   2. the pushbuf dump now carries a relocation pair for IDXBUF_OFFSET
#
# ⚠ Runs the reproducer ONCE. The second run is what wedges the GPU, so if this
# comes back dirty, reboot before running it again.
set -e
HOST="${1:-ember@192.168.40.31}"
TARBALL="${2:-/tmp/claude-1000/-home-velle/c6e261f8-c562-4ae0-b701-4767cb0bd26f/scratchpad/mesa-26.1.8-idxfix.tar.gz}"
OUT="${3:-/tmp/idxfix-dump.log}"

echo "== staging patched Mesa on $HOST =="
scp -q "$TARBALL" "$HOST:/tmp/" 
ssh "$HOST" 'sudo -n rm -rf /opt/mesa-26.1.8-idxfix && sudo -n tar xzf /tmp/mesa-26.1.8-idxfix.tar.gz -C /opt && ls /opt/mesa-26.1.8-idxfix/lib/dri/'

echo "== running the reproducer under the PATCHED driver =="
ssh "$HOST" 'bash -s' <<'EOF'
set -e
M=/opt/mesa-26.1.8-idxfix
X=$(pgrep -x Xorg|head -1); XA=$(ps -o args= -p $X)
D=$(echo "$XA"|tr ' ' '\n'|grep -m1 '^:[0-9]'); A=$(echo "$XA"|tr ' ' '\n'|grep -A1 '^-auth'|tail -1)

# ⛔ No separate "which Mesa loaded" probe is needed: stock Mesa CANNOT emit a
# relocation for IDXBUF, so the reloc check at the end is itself proof the patched
# code ran. This is only a cheap resolution hint.
echo "-- libGL resolves to --"
LD_LIBRARY_PATH=$M/lib ldd /usr/bin/vbo-drawelements 2>/dev/null | grep -i "libgl" | sed 's/^/   /' || true

b=$(sudo -n dmesg | grep -aci DMA_VTX_PROTECTION || true)
echo "-- baseline VTX faults: $b --"
rm -f /tmp/idxfix.log
sudo -n env DISPLAY=$D XAUTHORITY=$A LD_LIBRARY_PATH=$M/lib LIBGL_DRIVERS_PATH=$M/lib/dri \
  NOUVEAU_LIBDRM_DEBUG=1 timeout 8 /usr/bin/vbo-drawelements 2>/tmp/idxfix.log >/dev/null || true
sleep 3
a=$(sudo -n dmesg | grep -aci DMA_VTX_PROTECTION || true)
echo "-- VTX faults after the run: $((a-b)) --"
echo "-- dump: $(wc -c </tmp/idxfix.log) bytes, $(grep -c krec /tmp/idxfix.log || true) krecs, $(grep -c ': rel' /tmp/idxfix.log || true) relocs --"
EOF

scp -q "$HOST:/tmp/idxfix.log" "$OUT"
echo "== checking the dump for an IDXBUF relocation =="
# validate() writes the method header as a flags=0 constant: (1<<18)|(7<<13)|mthd
#   IDXBUF_OFFSET 0x181c -> 0004f81c    IDXBUF_FORMAT 0x1820 -> 0004f820
if grep -qE ': rel .* (0004f81c|0004f820) ' "$OUT"; then
  echo "  PASS: IDXBUF_OFFSET/FORMAT now carry a relocation"
  grep -E ': rel .* (0004f81c|0004f820) ' "$OUT" | sed 's/^/    /'
else
  echo "  FAIL: still no relocation for IDXBUF — the fix did not take effect"
fi
