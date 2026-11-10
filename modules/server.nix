# One shared T3 Code server per machine (system service `t3code`) and one
# socket-activated runner per user. Agents, PTYs and Git run in the owner's
# runner (`t3 runner`), so they carry that user's environment and credentials;
# the server itself only reaches project roots through a traverse-only ACL.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.services.t3code;
  jsonFormat = pkgs.formats.json { };
  t3 = "${cfg.package}/bin/t3";
  # Fixed: the T3 CLI, the runner socket path and StateDirectory agree on them.
  user = "t3code";
  stateDir = "/var/lib/t3code";
  runnerUnits = map (name: "t3-runner@${name}") (builtins.attrNames cfg.runners);

  oidcModule.options = {
    issuer = mkOption {
      type = types.str;
      example = "https://auth.example.org/oauth2/openid/t3code";
      description = "OpenID Connect issuer URL.";
    };
    clientId = mkOption {
      type = types.str;
      example = "t3code";
      description = "OAuth client id registered with the issuer.";
    };
    clientSecretFile = mkOption {
      type = types.path;
      example = "/run/agenix/t3code-oidc-client-secret";
      description = "File holding the client secret, readable by the `t3code` user.";
    };
    publicOrigins = mkOption {
      type = types.nonEmptyListOf types.str;
      example = [ "https://t3.example.org" ];
      description = "Origins clients reach the server through; each needs a redirect URI at the issuer.";
    };
    allowedGroup = mkOption {
      type = types.str;
      example = "t3code_users";
      description = "Group claim a user must carry to sign in.";
    };
  };

  runnerModule.options = {
    roots = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/home/alice" ];
      description = ''
        Project roots this user's runner may touch ({command}`t3 runner
        --allow-root`). The server gets a traverse-only ACL on each, so it can
        stat projects below them while file access stays with the runner.
      '';
    };
    environment = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "PATH=/etc/profiles/per-user/alice/bin:/run/current-system/sw/bin" ];
      description = ''
        `Environment=` entries of this user's runner (see
        {manpage}`systemd.exec(5)`). The runner starts from a system unit, so
        it has no login environment unless given one here.
      '';
    };
  };
in
{
  options.services.t3code = {
    enable = lib.mkEnableOption "the shared T3 Code server with per-user runners";

    package = mkOption {
      type = types.package;
      default = pkgs.t3code;
      defaultText = lib.literalExpression "pkgs.t3code";
      description = "The T3 Code package; it must provide {command}`t3` with `serve` and `runner`.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = "Address the server binds. Opening the firewall is left to the host.";
    };

    port = mkOption {
      type = types.port;
      default = 3773;
      description = "Port the server listens on.";
    };

    stateDir = mkOption {
      type = types.str;
      readOnly = true;
      default = stateDir;
      description = "The server's T3 home ({env}`T3CODE_HOME`).";
    };

    initialSettings = mkOption {
      inherit (jsonFormat) type;
      default = { };
      example = {
        providerInstances.opencode = {
          driver = "opencode";
          enabled = true;
        };
      };
      description = ''
        Server settings copied to {file}`userdata/settings.json` when that file
        does not exist yet. The app owns the file afterwards.
      '';
    };

    oidc = mkOption {
      type = types.nullOr (types.submodule oidcModule);
      default = null;
      description = "Sign-in through an OpenID Connect provider. `null` keeps T3 Code's own pairing.";
    };

    runners = mkOption {
      type = types.attrsOf (types.submodule runnerModule);
      default = { };
      example = lib.literalExpression ''{ alice.roots = [ "/home/alice" ]; }'';
      description = ''
        Users who get a runner, keyed by user name. Each gets the socket
        {file}`/run/t3code/runner-<user>.sock` and a service that starts on
        first use, as that user, in their home directory.
      '';
    };

    operators = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        Users who may run {file}`/etc/t3code/t3` as the `t3code` user without
        a password, to administer the server's state (pairing, sessions).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = stateDir;
    };
    users.groups.${user} = { };

    # sudo injects T3CODE_HOME itself (env_file for runas t3code), so the rule
    # needs no SETENV and takes no caller-controlled environment.
    environment.etc."t3code/t3".source = t3;
    security.sudo.extraConfig = "Defaults>${user} env_file=${pkgs.writeText "t3code-sudo-env" "T3CODE_HOME=${stateDir}\n"}";
    security.sudo.extraRules = lib.optional (cfg.operators != [ ]) {
      users = cfg.operators;
      runAs = user;
      commands = [
        {
          command = "/etc/t3code/t3";
          options = [ "NOPASSWD" ];
        }
      ];
    };

    systemd.tmpfiles.rules = [
      "d /run/t3code 0750 root ${user} -"
      "d ${stateDir}/userdata 0750 ${user} ${user} -"
    ]
    ++
      lib.optional (cfg.initialSettings != { })
        "C ${stateDir}/userdata/settings.json 0640 ${user} ${user} - ${pkgs.writeText "t3code-settings.json" (builtins.toJSON cfg.initialSettings)}"
    ++ lib.concatMap (runner: map (root: "a+ ${root} - - - - u:${user}:--x") runner.roots) (
      builtins.attrValues cfg.runners
    );

    systemd.services = {
      t3code = {
        description = "T3 Code server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment = {
          SHELL = "${pkgs.bashInteractive}/bin/bash";
          T3CODE_HOME = stateDir;
          T3CODE_RUNNER_SOCKET_TEMPLATE = "/run/t3code/runner-%u.sock";
        }
        // lib.optionalAttrs (cfg.oidc != null) {
          T3CODE_OIDC_ISSUER = cfg.oidc.issuer;
          T3CODE_OIDC_CLIENT_ID = cfg.oidc.clientId;
          T3CODE_OIDC_CLIENT_SECRET_FILE = toString cfg.oidc.clientSecretFile;
          T3CODE_OIDC_PUBLIC_ORIGINS = lib.concatStringsSep "," cfg.oidc.publicOrigins;
          T3CODE_OIDC_ALLOWED_GROUP = cfg.oidc.allowedGroup;
        };
        serviceConfig = {
          ExecStart = "${t3} ${
            lib.escapeShellArgs [
              "serve"
              "--host"
              cfg.host
              "--port"
              (toString cfg.port)
            ]
          }";
          User = user;
          Group = user;
          StateDirectory = "t3code";
          StateDirectoryMode = "0751";
          Restart = "on-failure";
          RestartSec = "5s";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/run/t3code" ];
        };
      };

      "t3-runner@" = {
        description = "T3 Code runner for %i";
        serviceConfig = {
          ExecStart = "${t3} runner";
          User = "%i";
          Restart = "on-failure";
          RestartSec = "2s";
        };
      };
    }
    # Per-user instances: roots and the user's own environment as drop-ins.
    // lib.mapAttrs' (
      name: runner:
      lib.nameValuePair "t3-runner@${name}" {
        overrideStrategy = "asDropin";
        serviceConfig = {
          # Empty ExecStart resets the template's, which has no roots.
          ExecStart = [
            ""
            "${t3} ${
              lib.escapeShellArgs (
                [ "runner" ]
                ++ lib.concatMap (root: [
                  "--allow-root"
                  root
                ]) runner.roots
              )
            }"
          ];
          Environment = runner.environment;
          WorkingDirectory = config.users.users.${name}.home;
        };
      }
    ) cfg.runners;

    systemd.sockets = {
      "t3-runner@" = {
        description = "T3 Code runner socket for %i";
        listenStreams = [ "/run/t3code/runner-%i.sock" ];
        socketConfig = {
          SocketUser = "%i";
          SocketGroup = user;
          SocketMode = "0660";
        };
      };
    }
    // lib.genAttrs runnerUnits (_: {
      overrideStrategy = "asDropin";
      wantedBy = [ "sockets.target" ];
    });
  };
}
