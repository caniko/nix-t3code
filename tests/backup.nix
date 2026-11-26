{ pkgs, module }:
let
  inherit (pkgs) lib;
  systemWith =
    extra:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = null;
      modules = [
        module
        {
          nixpkgs.pkgs = pkgs;
          system.stateVersion = "26.11";
        }
        extra
      ];
    }).config;
  empty = systemWith { };
  configured = systemWith {
    services.t3codeBackup.jobs.snapshot = {
      description = "Snapshot T3 Code data";
      onCalendar = "daily";
      randomizedDelaySec = "3m";
      user = "backup";
      group = "archive";
      execStart = "${pkgs.coreutils}/bin/true";
      environment.MODE = "snapshot";
      serviceConfig.Nice = 10;
    };
    services.t3codeBackup.jobs.copy = {
      onCalendar = "weekly";
      user = "backup";
      execStart = "${pkgs.coreutils}/bin/true";
    };
  };
  service = configured.systemd.services.t3code-backup-snapshot;
  timer = configured.systemd.timers.t3code-backup-snapshot;
  copy = configured.systemd.services.t3code-backup-copy;
in
assert !(lib.any (lib.hasPrefix "t3code-backup-") (builtins.attrNames empty.systemd.services));
assert service.description == "Snapshot T3 Code data";
assert service.environment.MODE == "snapshot";
assert
  service.serviceConfig == {
    Type = "oneshot";
    User = "backup";
    Group = "archive";
    ExecStart = "${pkgs.coreutils}/bin/true";
    StateDirectory = "t3code-backup-snapshot";
    StateDirectoryMode = "0700";
    UMask = "0077";
    IOSchedulingClass = "idle";
    Nice = 10;
  };
assert timer.wantedBy == [ "timers.target" ];
assert
  timer.timerConfig == {
    OnCalendar = "daily";
    RandomizedDelaySec = "3m";
    Persistent = true;
    Unit = "t3code-backup-snapshot.service";
  };
assert !(copy.serviceConfig ? Group);
assert copy.serviceConfig.StateDirectory == "t3code-backup-copy";
assert configured.systemd.timers.t3code-backup-copy.timerConfig.RandomizedDelaySec == "15m";
pkgs.runCommand "t3code-backup-eval" { } "touch $out"
