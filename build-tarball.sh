#!/bin/bash
# Builds the nixos-subspace rootfs tarball.
#
# Runs as root on a NixOS live ISO (the config in configuration.nix must be
# active via `nixos-rebuild switch` first). Output: nixos-rootfs.tar.xz next
# to this script's working dir (see OUT below), plus a .sha256.
#
# Pipeline: closureInfo -> rsync rootfs + closure -> hygiene (out-of-box
# fixes) -> nix DB registration -> tar/xz -> extract -> chroot verification.
set -euo pipefail

STAGE=/data/stage
OUT=/data/nixos-rootfs.tar.xz

log() { echo; echo "=== $* ==="; }

# ---------- 0. fresh stage ----------
log "stage: fresh directory"
rm -rf "$STAGE" /data/verify
mkdir -p "$STAGE"

# ---------- 1. closure info (system + channel => nixos-rebuild works inside) ----------
log "closureInfo"
# Resolve the running system as a STORE PATH (a Nix path literal like
# /run/current-system would copy the symlink itself into the store instead of
# referencing the system closure). builtins.storePath adds input context so
# exportReferencesGraph accepts it — a bare string has no context and the
# build fails with "not in the input closure".
SYSPATH=$(readlink -f /run/current-system)
[[ "$SYSPATH" == /nix/store/* ]] || { echo "ABORT: cannot resolve system: $SYSPATH"; exit 1; }
echo "system: $SYSPATH"

# The channel symlink may point at <store>/nixpkgs-subdir; find the nixpkgs
# root (has default.nix) and the enclosing store path separately.
CH=$(readlink -f /nix/var/nix/profiles/per-user/root/channels/nixos)
CH_ROOT="$CH"
while [ ! -e "$CH_ROOT/default.nix" ] && [ "$CH_ROOT" != "/nix/store" ]; do
  CH_ROOT=$(dirname "$CH_ROOT")
done
[ -e "$CH_ROOT/default.nix" ] || { echo "ABORT: cannot locate nixpkgs root from $CH"; exit 1; }
CH_STORE=$(echo "$CH_ROOT" | cut -d/ -f1-4)
echo "channel root: $CH_ROOT (store: $CH_STORE)"

# Profile symlinks (manifest) must resolve inside the image, otherwise
# nix-channel/NIX_PATH/nixos-rebuild break after extraction.
ROOTPATHS="\"$SYSPATH\" \"$CH_STORE\""
t=$(readlink -f /nix/var/nix/profiles/per-user/root/channels/manifest.nix 2>/dev/null || true)
if [[ "$t" == /nix/store/* ]]; then
  ROOTPATHS="$ROOTPATHS \"$t\""
  echo "extra root: $t"
fi

INFO=$(nix-build -o /data/closure-info -E "
  with import $CH_ROOT {};
  closureInfo {
    rootPaths = map builtins.storePath [ $ROOTPATHS ];
  }")
echo "info: $INFO"
NPATHS=$(wc -l < "$INFO/store-paths")
echo "store paths in closure: $NPATHS"
[ "$NPATHS" -gt 500 ] || { echo "ABORT: closure suspiciously small"; exit 1; }

# ---------- 2. copy root filesystem ----------
log "rsync rootfs"
rsync -aH \
  --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
  --exclude='/tmp/*' --exclude='/data' --exclude='/iso' --exclude='/mnt/*' \
  --exclude='/nix/store' --exclude='/nix/.ro-store' --exclude='/nix/.rw-store' \
  --exclude='/nix/var/nix/db' \
  --exclude='/nix/var/nix/daemon-socket/socket' \
  --exclude='/nix/var/nix/gc.lock' --exclude='/nix/var/nix/temproots' \
  --exclude='/nix/var/nix/gcroots' \
  --exclude='/var/log/journal/*' \
  --exclude='/var/lib/systemd/random-seed' --exclude='/var/lib/systemd/credential.secret' \
  --exclude='/var/lib/NetworkManager/*' \
  --exclude='/etc/ssh/ssh_host_*' \
  --exclude='/root/.bash_history' --exclude='/home/nixos/.bash_history' \
  --exclude='/root/.cache' --exclude='/home/nixos/.cache' \
  / "$STAGE/"

# ---------- 3. copy exactly the closure into the store ----------
# NOTE: --files-from implies --no-recursive; -r must come AFTER it or the
# store dirs are created empty (silent failure caught by the size check).
log "rsync store closure"
sed 's|^/||' "$INFO/store-paths" > /data/store-paths.rel
install -d -m 1775 -o root -g nixbld "$STAGE/nix/store"
rsync -aH --files-from=/data/store-paths.rel -r / "$STAGE/"
[ "$(du -sb "$STAGE/nix/store" | cut -f1)" -gt 800000000 ] || { echo "ABORT: store copy too small"; exit 1; }

# ---------- 4. image hygiene + out-of-box fixes ----------
log "hygiene"
: > "$STAGE/etc/machine-id"; chmod 644 "$STAGE/etc/machine-id"
rm -f "$STAGE/etc/ssh/ssh_host_"*            # sshd-keygen.service regenerates on boot
rm -rf "$STAGE/var/log/journal"/* 2>/dev/null || true
rm -f "$STAGE/var/lib/dbus/machine-id"
find "$STAGE" -name '.bash_history' -delete
install -d -m 0755 "$STAGE/nix/var/nix/daemon-socket"
rm -f "$STAGE/nix/var/nix/daemon-socket/socket"

# /run is excluded above; without /run/current-system the profile PATH
# (…/sw/bin) and LOCALE_ARCHIVE are dead for no-boot entries (bwrap/chroot).
ln -sfn /nix/var/nix/profiles/system "$STAGE/run/current-system"

# The channels profile was a symlink chain to a user-environment store path
# that may not be in the closure, and the channel is named 'nixos' only —
# so `nix-env -A nixpkgs.htop` couldn't resolve. Rebuild it as a real dir
# with both names pointing at the same (in-closure) channel source.
CHL=/nix/var/nix/profiles/per-user/root/channels
NIXOS_T=$(readlink "$CHL/nixos")
MAN_T=$(readlink "$CHL/manifest.nix" 2>/dev/null || echo "")
[[ "$NIXOS_T" == /nix/store/* ]] || { echo "ABORT: cannot read live channel target"; exit 1; }
CHD="$STAGE/nix/var/nix/profiles/per-user/root/channels"
rm -f "$CHD" "$STAGE/nix/var/nix/profiles/per-user/root/channels-1-link"
mkdir -p "$CHD"
ln -s "$NIXOS_T" "$CHD/nixos"
ln -s "$NIXOS_T" "$CHD/nixpkgs"       # attr-name alias: -A nixpkgs.htop works
[ -n "$MAN_T" ] && ln -s "$MAN_T" "$CHD/manifest.nix"
cat > "$STAGE/root/.nix-channels" <<CEOF
https://channels.nixos.org/nixos-26.05 nixos
https://channels.nixos.org/nixos-26.05 nixpkgs
CEOF

# Kitty terminfo so `clear` works with TERM=xterm-kitty. NOTE: /etc/terminfo
# is a symlink into the store — never write through it; TERMINFO (set in
# configuration.nix) points at /usr/share/terminfo and ~/.terminfo is the
# ncurses home fallback.
install -d -m 755 "$STAGE/usr/share/terminfo/x" "$STAGE/root/.terminfo/x"
install -m 644 /data/xterm-kitty "$STAGE/usr/share/terminfo/x/xterm-kitty"
install -m 644 /data/xterm-kitty "$STAGE/root/.terminfo/x/xterm-kitty"

# sanity: the chains the fixes depend on must resolve INSIDE the stage
for l in "$STAGE/run/current-system" "$STAGE/usr/bin/nix" "$STAGE/bin/sh"; do
  [ -e "$l" ] || { echo "ABORT: broken link after hygiene: $l"; exit 1; }
done
[ -e "$STAGE$NIXOS_T" ] || { echo "ABORT: channel target missing in stage"; exit 1; }
echo "hygiene OK"

# ---------- 5. nix DB: register exactly what ships ----------
log "nix DB registration"
install -d -m 0755 "$STAGE/nix/var/nix/db"
loaded=0
if NIX_REMOTE="local?root=$STAGE" nix-store --load-db < "$INFO/registration"; then
  loaded=1
else
  echo "rooted load-db exited nonzero"
fi
if [ "$loaded" -ne 1 ] || [ ! -s "$STAGE/nix/var/nix/db/db.sqlite" ]; then
  echo "falling back to nspawn load-db"
  rm -rf "$STAGE/nix/var/nix/db"
  install -d -m 0755 "$STAGE/nix/var/nix/db"
  systemd-nspawn -D "$STAGE" --register=no /usr/bin/env -i NIX_REMOTE=local \
    PATH=/usr/bin:/bin HOME=/root /usr/bin/nix-store --load-db < "$INFO/registration"
fi
[ -s "$STAGE/nix/var/nix/db/db.sqlite" ] || { echo "ABORT: no db.sqlite in stage"; exit 1; }
echo "DB OK: $(ls -lh "$STAGE/nix/var/nix/db/db.sqlite" | awk '{print $5}')"

# ---------- 6. tarball ----------
log "tar | xz"
tar --numeric-owner -C "$STAGE" -cf - . | xz -T0 -9 > "$OUT"
sha256sum "$OUT" > "$OUT.sha256"
ls -lh "$OUT"

# ---------- 7. verify: extract + login shell via chroot ----------
# chroot, not systemd-nspawn: nspawn mounts tmpfs over /run, hiding the
# baked run/current-system and breaking the profile PATH — exactly the
# semantics difference between nspawn and the bwrap/subspace entry path.
log "extract for verification"
mkdir -p /data/verify
xz -dc "$OUT" | tar --numeric-owner -x -C /data/verify

log "out-of-box test (login shell in chroot = bwrap semantics)"
mount -t proc proc /data/verify/proc 2>/dev/null || true
out=$(chroot /data/verify /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root USER=root LOGNAME=root TERM=xterm-kitty SHELL=/bin/bash \
  /bin/bash -lc '
  set -e
  echo "os:       $(. /etc/os-release && echo $PRETTY_NAME)"
  if [ "${NIX_REMOTE+x}" = x ] && [ -z "$NIX_REMOTE" ]; then
    echo "FIX1-OK: NIX_REMOTE exported but empty (auto: daemon-if-present, local otherwise)"
  else
    echo "FIX1-FAIL: NIX_REMOTE=[${NIX_REMOTE:-UNSET}]"; exit 1
  fi
  nix-store -q --references "$(readlink -f /run/current-system)" > /dev/null \
    && echo "FIX1b-OK: local store query, no daemon" || { echo FIX1b-FAIL; exit 1; }
  nix-env -qaA nixpkgs.htop | grep -q htop \
    && echo "FIX2-OK: -A nixpkgs.htop resolves" || { echo FIX2-FAIL; exit 1; }
  nix-env -qaA nixos.htop | grep -q htop \
    && echo "FIX2b-OK: -A nixos.htop resolves" || { echo FIX2b-FAIL; exit 1; }
  nix-instantiate --eval -E "with import <nixpkgs> {}; lib.version" > /dev/null \
    && echo "FIX2c-OK: <nixpkgs> import (NIX_PATH)" || { echo FIX2c-FAIL; exit 1; }
  clear && echo "FIX3-OK: clear with TERM=xterm-kitty" || { echo FIX3-FAIL; exit 1; }
  test -e /run/current-system/sw/bin/ls \
    && echo "FIX4-OK: run/current-system resolves" || { echo FIX4-FAIL; exit 1; }
  test -e "$LOCALE_ARCHIVE" \
    && echo "FIX5-OK: LOCALE_ARCHIVE exists" || { echo FIX5-FAIL; exit 1; }
  if LC_ALL=en_US.UTF-8 bash -ic true 2>&1 | grep -q setlocale; then
    echo "FIX5b-FAIL: setlocale warnings remain"; exit 1
  else
    echo "FIX5b-OK: no setlocale warnings"
  fi
  command -v nixos-rebuild git vim curl > /dev/null && echo "TOOLS-OK"
  echo ALL-FIXES-VERIFIED
')
rc=$?
umount /data/verify/proc 2>/dev/null || true
echo "$out"
[ $rc -eq 0 ] && echo "$out" | grep -q ALL-FIXES-VERIFIED || { echo "VERIFY FAILED"; exit 1; }

log "ALL DONE"
ls -lh "$OUT" "$OUT.sha256"
cat "$OUT.sha256"
