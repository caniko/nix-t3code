{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  jobs = lib.mapAttrs' (
    name: job:
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name != null
    ) "Invalid services.t3codeBackup.jobs name: ${name}";
    lib.nameValuePair "t3code-backup-${name}" job
  ) config.services.t3codeBackup.jobs;
in
{
  options.services.t3codeBackup.jobs = mkOption {
    default = { };
    description = ''
      Scheduled backup commands. Each job produces a service and timer
      named `t3code-backup-<name>` and gets its own private state directory.
    '';
    type = types.attrsOf (
      types.submodule (
        { name, ... }:
        {
          options = {
            description = mkOption {
              type = types.str;
              default = "T3 Code backup: ${name}";
              description = "Description of the backup job in systemd.";
            };
            onCalendar = mkOption {
              type = types.nonEmptyStr;
              example = "daily";
              description = "Systemd calendar expression for the timer.";
            };
            randomizedDelaySec = mkOption {
              type = types.either types.ints.unsigned types.nonEmptyStr;
              default = "15m";
              description = "Maximum randomized delay, in seconds or a systemd timespan.";
            };
            user = mkOption {
              type = types.nonEmptyStr;
              description = "Existing user that runs the backup command.";
            };
            group = mkOption {
              type = types.nullOr types.nonEmptyStr;
              default = null;
              description = "Existing group for the command, or the user's primary group if unset.";
            };
            execStart = mkOption {
              type = types.nonEmptyStr;
              description = "Systemd ExecStart command; use an absolute executable path.";
            };
            environment = mkOption {
              type = types.attrsOf types.str;
              default = { };
              description = "Non-secret environment variables for the backup service.";
            };
            serviceConfig = mkOption {
              type =
                with types;
                attrsOf (oneOf [
                  bool
                  int
                  str
                  path
                  (listOf str)
                ]);
              default = { };
              description = "Additional systemd service settings, overriding the module defaults.";
            };
          };
        }
      )
    );
  };

  config = {
    systemd.services = lib.mapAttrs (unit: job: {
      inherit (job) description environment;
      serviceConfig = {
        Type = "oneshot";
        User = job.user;
        ExecStart = job.execStart;
        StateDirectory = unit;
        StateDirectoryMode = "0700";
        UMask = "0077";
        Nice = 19;
        IOSchedulingClass = "idle";
      }
      // lib.optionalAttrs (job.group != null) { Group = job.group; }
      // job.serviceConfig;
    }) jobs;
    systemd.timers = lib.mapAttrs (unit: job: {
      inherit (job) description;
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Unit = "${unit}.service";
        OnCalendar = job.onCalendar;
        RandomizedDelaySec = job.randomizedDelaySec;
        Persistent = true;
      };
    }) jobs;
  };
}
