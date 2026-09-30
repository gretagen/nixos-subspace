# nixos-subspace

A minimal **NixOS 26.05 (Yarara)** rootfs, packaged for the
[subspace](https://github.com/gretagen/subspace-scripts) container tooling
(bwrap entry, no boot required).

## Install

```sh
sudo subspace-cli install nixos
subspace-enter nixos
```

Or manually: download the release tarball, extract it into a directory, and
enter it with `subspace-run <dir> /bin/sh`.

## What's inside

- NixOS 26.05 minimal system: bash, coreutils, git, curl, vim, dnsutils,
  iproute2, procps — no desktop, no audio, no bootloader, no kernel
  (`boot.isContainer = true`); host kernel is used by the container runtime
- Full nix toolchain (`nix`, `nix-env`, `nix-channel`, `nixos-rebuild`) with
  flakes enabled, and the nixpkgs channel shipped in the closure, so
  `nix-shell -p <pkg>` / `nix-env -iA nixpkgs.<pkg>` work out of the box
- **No nix-daemon required**: `NIX_REMOTE` is left empty, nix auto-detects
  (daemon socket when booted under systemd-nspawn, direct store access
  otherwise)
- FHS shims for container entry tooling: `/bin/sh`, `/bin/bash`,
  `/usr/bin/*` (723 tools), `/sbin/init` → system profile
- `/run/current-system` → `/nix/var/nix/profiles/system`, so the profile
  `PATH` and `LOCALE_ARCHIVE` resolve without ever booting
- Fresh `/etc/machine-id`, no SSH host keys (regenerated on first boot),
  empty journal

## Verify a downloaded tarball

```sh
sha256sum -c <<< "<sha256 from the release notes>"   # after renaming to match
```

## Rebuild

Built from `configuration.nix` (included) with `nixos-rebuild switch` on a
NixOS live ISO, then packed by `build-tarball.sh` (also included): closure
extraction via `closureInfo`, hygiene pass, nix DB registration, tar + compress.

Release assets are hosted via GitHub Releases — rootfs tarballs are far too
large for git history (>100 MB hard limit).
