{ config, pkgs, lib, ... }:

{
  # ---------- minimal NixOS, container-oriented ----------
  system.stateVersion = "26.05";

  # No kernel, no bootloader install, no udev, no audit:
  # the artifact is booted by the container runtime / host kernel.
  boot.isContainer = true;

  # Keep the live VM reachable through the switch (and DHCP in general).
  networking.networkmanager.enable = true;

  # ---------- access ----------
  services.openssh.enable = true;

  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    initialHashedPassword = "";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC1kFzuN0/xubWinY85wq7J0xQ8DsunNgjDhnJrijXt+ besternet91@gmail.com"
    ];
  };
  users.users.root.initialHashedPassword = "";

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  # ---------- tooling (small but useful) ----------
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    dnsutils
    iproute2
    procps
  ];

  # ---------- nix ----------
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "nixos" ];
  };

  # boot.isContainer bakes NIX_REMOTE=daemon, but the artifact ships its OWN
  # store and is primarily entered without boot (bwrap/subspace) where no
  # daemon exists. Empty = nix auto-detects: daemon socket if present (nspawn
  # boot), local store otherwise.
  environment.variables.NIX_REMOTE = lib.mkForce "";

  # Host kitty terminal's terminfo is baked into the image at
  # /usr/share/terminfo; make sure ncurses finds it.
  environment.variables.TERMINFO = "/usr/share/terminfo";

  # ---------- FHS shims for container entry ----------
  # Entry tooling (subspace-enter, bwrap PATH, systemd-nspawn) expects
  # /bin/sh and /usr/bin to exist. /sbin/init is what nspawn execs as
  # PID 1; it points at the system profile so it tracks rebuilds.
  system.activationScripts.fhsShims.text = ''
    mkdir -p /bin /sbin /usr/bin
    ln -sfn ${pkgs.bash}/bin/sh /bin/sh
    ln -sfn ${pkgs.bash}/bin/bash /bin/bash
    ln -sfn /nix/var/nix/profiles/system/init /sbin/init
    for f in ${config.system.path}/bin/*; do
      ln -sfn "$f" "/usr/bin/$(basename "$f")"
    done
  '';
}
