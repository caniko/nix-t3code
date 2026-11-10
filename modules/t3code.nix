{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    literalExpression
    mkIf
    mkMerge
    mkOption
    types
    ;

  cfg = config.programs.t3code;
  jsonFormat = pkgs.formats.json { };
  json5 = pkgs.python3Packages.toPythonApplication pkgs.python3Packages.json5;
  inherit (cfg) stateDir;

  forgeKinds = [
    "github"
    "gitlab"
    "forgejo"
  ];
  hostsOfKind = kind: lib.filterAttrs (_: host: host.kind == kind) cfg.sourceControl.hosts;
  hasKind = kind: hostsOfKind kind != { };

  forgejoCredential = pkgs.writeShellApplication {
    name = "t3code-forgejo-credential";
    runtimeInputs = [
      pkgs.jq
      cfg.sourceControl.forgejoPackage
    ];
    text = builtins.readFile ./forgejo-credential.sh;
  };

  credentialHelpers = {
    github = "!${lib.getExe' cfg.sourceControl.githubPackage "gh"} auth git-credential";
    gitlab = "!${lib.getExe' cfg.sourceControl.gitlabPackage "glab"} auth git-credential";
    forgejo = lib.getExe forgejoCredential;
  };
  # programs.gh already installs its helper for these hosts.
  ghManagedHosts = lib.optionals (
    (config.programs.gh.enable or false) && (config.programs.gh.gitCredentialHelper.enable or false)
  ) (config.programs.gh.gitCredentialHelper.hosts or [ ]);
  credentialHosts = lib.filterAttrs (
    name: host:
    host.gitCredentialHelper
    && !(host.kind == "github" && builtins.elem "https://${name}" ghManagedHosts)
  ) cfg.sourceControl.hosts;

  githubAccounts = lib.mapAttrs (_: host: { inherit (host) account; }) (
    lib.filterAttrs (_: host: host.account != null) (hostsOfKind "github")
  );

  # The settings key clients compare to decide whether to (re)adopt the default theme.
  defaultThemeSetAt =
    "nix-"
    + builtins.substring 0 32 (
      builtins.hashString "sha256" (
        builtins.toJSON [
          cfg.defaultTheme
          (cfg.themes.${cfg.defaultTheme} or null)
        ]
      )
    );

  effectiveUserSettings = lib.recursiveUpdate (
    lib.optionalAttrs (cfg.defaultTheme != null) {
      defaultTheme = cfg.defaultTheme;
      inherit defaultThemeSetAt;
    }
    // lib.optionalAttrs (cfg.linkedEnvironments != { }) { linkedEnvironmentsEnabled = true; }
  ) cfg.userSettings;

  effectiveUserSettingsDefaults = lib.recursiveUpdate (lib.optionalAttrs (githubAccounts != { }) {
    sourceControlHosts.github.hosts = githubAccounts;
  }) cfg.userSettingsDefaults;

  # Nix-owned keys win over the app's, the app's win over defaults.
  objectOperation = "$defaults * $dynamic * $static";
  files = [
    {
      name = "settings";
      static = effectiveUserSettings;
      defaults = effectiveUserSettingsDefaults;
      mutable = cfg.mutableUserSettings;
      empty = "{}";
      operation = objectOperation;
    }
    {
      name = "client-settings";
      static = cfg.clientSettings;
      defaults = cfg.clientSettingsDefaults;
      mutable = cfg.mutableClientSettings;
      empty = "{}";
      # Older desktop builds wrapped the document in `settings`; the reader accepts both.
      operation = ''(if ($dynamic | has("settings")) then $dynamic.settings else $dynamic end) as $dynamic | ${objectOperation}'';
    }
    {
      name = "desktop-settings";
      static = cfg.desktopSettings;
      defaults = cfg.desktopSettingsDefaults;
      mutable = cfg.mutableDesktopSettings;
      empty = "{}";
      operation = objectOperation;
    }
    {
      name = "keybindings";
      static = cfg.keybindings;
      defaults = [ ];
      mutable = cfg.mutableKeybindings;
      empty = "[]";
      # A Nix rule replaces the app's rule for the same (key, when) in place: T3 matches
      # the last rule first, so other rules keep their order.
      operation = ''
        reduce $static[] as $rule ($dynamic;
          if any(.[]; .key == $rule.key and .when == $rule.when)
          then map(if .key == $rule.key and .when == $rule.when then . * $rule else . end)
          else . + [$rule] end)
      '';
    }
  ];
  # Like upstream, an empty declaration leaves the file alone even when immutable.
  managedFiles = builtins.filter (
    file: file.static != builtins.fromJSON file.empty || file.defaults != builtins.fromJSON file.empty
  ) files;

  mergeFile =
    file:
    lib.escapeShellArgs [
      "t3codeMerge"
      "${stateDir}/${file.name}.json"
      file.empty
      file.operation
      (jsonFormat.generate "t3code-${file.name}.json" file.static)
      (jsonFormat.generate "t3code-${file.name}-defaults.json" file.defaults)
      (if file.mutable then "0" else "1")
    ];

  themeIds = builtins.attrNames cfg.themes;
  themeFiles = pkgs.linkFarm "t3code-themes" (
    lib.mapAttrsToList (id: theme: {
      name = "${id}.json";
      path = jsonFormat.generate "t3code-theme-${id}.json" theme;
    }) cfg.themes
  );
  validThemeId =
    id:
    builtins.match "[a-z0-9][a-z0-9-]{0,47}" id != null
    # T3 Code's UNPUBLISHABLE_THEME_IDS (packages/shared/src/themePalettes.ts).
    && !builtins.elem id [
      "system"
      "light"
      "dark"
      "t3-chat"
      "grove"
      "ocean"
      "ember"
      "iris"
      "t3-chat-dark"
      "t3-grove"
      "t3-ocean"
      "t3-ember"
      "t3-iris"
      "t3-code"
    ];

  serverArgs = [
    "serve"
    "--base-dir"
    cfg.baseDir
    "--no-browser"
  ]
  ++ lib.optionals (cfg.server.host != null) [
    "--host"
    cfg.server.host
  ]
  ++ lib.optionals (cfg.server.port != null) [
    "--port"
    (toString cfg.server.port)
  ]
  ++ cfg.server.extraArgs;

  tunnelUnit = name: "t3code-tunnel-${name}";
  linkPeers = jsonFormat.generate "t3code-linked-environments.json" (
    lib.mapAttrsToList (_: peer: {
      url = "http://127.0.0.1:${toString peer.localPort}";
      destinations = peer.sshHost;
      # Run by the peer's login shell; single quotes read the same in POSIX shells and Nushell.
      pairing = "${peer.command} auth pairing create --json --ttl 5m --base-dir ${lib.escapeShellArg peer.baseDir}";
      inherit (peer) access;
    }) cfg.linkedEnvironments
  );
  linkEnvironments = pkgs.writeShellApplication {
    name = "t3code-link-environments";
    runtimeInputs = [
      cfg.package
      pkgs.coreutils
      pkgs.jq
      pkgs.openssh
    ];
    text = builtins.readFile ./link-environments.sh;
  };
  # Holds the forward ($1) through each SSH destination in turn; the unit
  # restarts from the first one when all have failed or dropped.
  tunnel = pkgs.writeShellScript "t3code-tunnel" ''
    forward="$1"
    shift
    for destination; do
      # A multiplexed client hands the forward to its master and exits at once.
      ${lib.getExe pkgs.openssh} -N -o BatchMode=yes -o ConnectTimeout=10 \
        -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -o ControlMaster=no -o ControlPath=none -L "$forward" "$destination" || true
    done
    exit 1
  '';
  localPorts = lib.mapAttrsToList (_: peer: peer.localPort) cfg.linkedEnvironments;

  linkModule = {
    options = {
      sshHost = mkOption {
        type = types.coercedTo types.str lib.singleton (types.nonEmptyListOf types.str);
        example = [
          "alice@workstation.lan"
          "alice@workstation.vpn"
        ];
        description = ''
          SSH destination of the peer machine, as the same user, or a list of
          routes to it tried in order (LAN first, then VPN). Login must work
          without a prompt (a key or agent), because a user service holds the
          tunnel.
        '';
      };

      port = mkOption {
        type = types.port;
        example = 3773;
        description = "Port the peer's T3 Code server listens on, on its loopback.";
      };

      localPort = mkOption {
        type = types.port;
        example = 37731;
        description = ''
          Loopback port here that the tunnel forwards to the peer's server. The
          link is made to `http://127.0.0.1:<localPort>`, so keep it stable.
        '';
      };

      baseDir = mkOption {
        type = types.strMatching "[^']+";
        default = cfg.baseDir;
        defaultText = literalExpression "config.programs.t3code.baseDir";
        description = "The peer's T3 Code base directory.";
      };

      command = mkOption {
        type = types.str;
        default = "t3";
        description = "How the peer's login shell runs the T3 Code CLI.";
      };

      access = mkOption {
        type = types.enum [
          "read-only"
          "approval-required"
          "auto-accept-edits"
          "auto"
          "full-access"
        ];
        default = "approval-required";
        description = "What agents here may do on the peer: read-only, or the broadest runtime mode.";
      };
    };
  };

  hostModule =
    { name, ... }:
    {
      options = {
        kind = mkOption {
          type = types.enum forgeKinds;
          example = "forgejo";
          description = ''
            The forge software running on this host. T3 Code recognizes
            `github.com`, `gitlab.com`, `codeberg.org` and host names with a
            `github`, `gitlab`, `forgejo` or `gitea` label by name. It
            recognizes any other host (such as `codefloe.com`) only through a
            login of the forge's CLI ({command}`fj` or {command}`tea` for
            Forgejo, {command}`glab` for GitLab).
          '';
        };

        account = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "octocat";
          description = ''
            GitHub only: the {command}`gh` account T3 Code uses on this host
            when several are signed in. Seeded into
            `sourceControlHosts.github.hosts.<host>.account` without replacing
            a choice made in the app.
          '';
        };

        gitCredentialHelper = mkOption {
          type = types.bool;
          default = cfg.sourceControl.gitCredentialHelpers;
          defaultText = literalExpression "config.programs.t3code.sourceControl.gitCredentialHelpers";
          description = ''
            Whether Git authenticates HTTPS operations on `https://${name}`
            with this forge's CLI login: {command}`gh auth git-credential`,
            {command}`glab auth git-credential`, or the application/OAuth token
            {command}`fj` holds for the host. T3 Code clones over HTTPS by
            default for GitHub and Forgejo, and its forge CLIs never lend their
            tokens to Git themselves.
          '';
        };
      };
    };
in
{
  # The upstream module hardcodes ~/.t3 and links immutable files into the
  # store, which the T3 Code server cannot rewrite. This module replaces it.
  disabledModules = [ "programs/t3code.nix" ];

  options.programs.t3code = {
    enable = lib.mkEnableOption "T3 Code, a minimal web GUI for coding agents";

    package = mkOption {
      type = types.nullOr types.package;
      default = pkgs.t3code or null;
      defaultText = literalExpression "pkgs.t3code";
      description = ''
        The T3 Code package. It must provide the {command}`t3` server binary
        when {option}`programs.t3code.server.enable` is set. `null` manages
        configuration only.
      '';
    };

    baseDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.t3";
      defaultText = literalExpression ''"''${config.home.homeDirectory}/.t3"'';
      example = literalExpression ''"''${config.xdg.dataHome}/t3code"'';
      description = ''
        The T3 home ({env}`T3CODE_HOME`, {command}`t3 --base-dir`). A value
        other than the default is exported as {env}`T3CODE_HOME` so the
        desktop app and the {command}`t3` CLI use it too.
      '';
    };

    stateDir = mkOption {
      type = types.str;
      readOnly = true;
      default = "${cfg.baseDir}/userdata";
      defaultText = literalExpression ''"''${config.programs.t3code.baseDir}/userdata"'';
      description = "The directory holding T3 Code's settings files and state.";
    };

    userSettings = mkOption {
      inherit (jsonFormat) type;
      default = { };
      example = {
        enableProviderUpdateChecks = false;
        defaultThreadEnvMode = "worktree";
        providerInstances.opencode = {
          driver = "opencode";
          enabled = true;
        };
      };
      description = ''
        Server settings enforced in {file}`settings.json`. Merged recursively
        over the file on every activation; keys not set here keep the values
        the app wrote. The server watches the file, so changes apply without a
        restart. Do not put secrets here: they would land in the Nix store
        (the server moves inline secrets into its secret store on load).
      '';
    };

    userSettingsDefaults = mkOption {
      inherit (jsonFormat) type;
      default = { };
      example = {
        providerInstances.opencode = {
          driver = "opencode";
          enabled = true;
        };
      };
      description = ''
        Server settings seeded into {file}`settings.json`: applied for keys the
        file does not set, so later changes made in the app are kept.
      '';
    };

    mutableUserSettings = mkOption {
      type = types.bool;
      default = true;
      example = false;
      description = ''
        Whether {file}`settings.json` keeps keys the app wrote. When `false`,
        every activation resets it to exactly the declared settings. The file
        stays a regular file either way, because the server rewrites it.
      '';
    };

    keybindings = mkOption {
      inherit (jsonFormat) type;
      default = [ ];
      example = [
        {
          key = "mod+j";
          command = "terminal.toggle";
        }
        {
          key = "mod+d";
          command = "diff.toggle";
          when = "!terminalFocus";
        }
      ];
      description = ''
        Rules enforced in {file}`keybindings.json`. A rule replaces the app's
        rule with the same `key` and `when`.
      '';
    };

    mutableKeybindings = mkOption {
      type = types.bool;
      default = true;
      example = false;
      description = ''
        Whether {file}`keybindings.json` keeps rules the app wrote. When
        `false`, every activation resets it to exactly the declared rules (the
        server then backfills its defaults).
      '';
    };

    clientSettings = mkOption {
      inherit (jsonFormat) type;
      default = { };
      example = {
        fontFamilyCode = "Fira Mono";
        sidebarProjectGroupingMode = "repository";
        timestampFormat = "24-hour";
      };
      description = ''
        Desktop client settings enforced in {file}`client-settings.json`.
        The desktop app reads the file at startup. Web clients keep their
        settings in browser storage instead.
      '';
    };

    clientSettingsDefaults = mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = ''
        Desktop client settings seeded into {file}`client-settings.json`
        without replacing values changed in the app.
      '';
    };

    mutableClientSettings = mkOption {
      type = types.bool;
      default = true;
      example = false;
      description = ''
        Whether {file}`client-settings.json` keeps keys the app wrote.
      '';
    };

    desktopSettings = mkOption {
      inherit (jsonFormat) type;
      default = { };
      example = {
        localEnvironmentEnabled = false;
        updateChannel = "nightly";
      };
      description = ''
        Desktop shell settings enforced in {file}`desktop-settings.json`,
        read when the desktop app starts.
      '';
    };

    desktopSettingsDefaults = mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = ''
        Desktop shell settings seeded into {file}`desktop-settings.json`
        without replacing values changed in the app.
      '';
    };

    mutableDesktopSettings = mkOption {
      type = types.bool;
      default = true;
      example = false;
      description = ''
        Whether {file}`desktop-settings.json` keeps keys the app wrote, such
        as window bounds.
      '';
    };

    themes = mkOption {
      type = types.attrsOf jsonFormat.type;
      default = { };
      example = {
        midnight = {
          version = 1;
          name = "Midnight";
          appearance = "dark";
          canvas = "#101418";
          accent = "#7aa2f7";
          colors.terminalBackground = "#0b0e11";
        };
      };
      description = ''
        Themes published by this environment, keyed by theme id. Each value is
        a T3 Code theme file (`name`, `appearance`, and `canvas`+`accent` or
        `colors`) written to {file}`themes/<id>.json`. The server reloads
        them live and offers them to every client. Themes added with
        {command}`t3 theme set` are left alone.
      '';
    };

    defaultTheme = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "midnight";
      description = ''
        The environment's default theme: a built-in id or a key of
        {option}`programs.t3code.themes`. Clients connected to the environment
        adopt it, and adopt it again whenever the id or that theme's content
        changes, replacing a theme picked in the client meanwhile.
      '';
    };

    sourceControl = {
      hosts = mkOption {
        type = types.attrsOf (types.submodule hostModule);
        default = { };
        example = literalExpression ''
          {
            "github.com".kind = "github";
            "gitlab.com".kind = "gitlab";
            "codeberg.org".kind = "forgejo";
            "codefloe.com".kind = "forgejo";
          }
        '';
        description = ''
          Forge hosts T3 Code works with, keyed by host name. Their CLIs are
          installed, and with {option}`gitCredentialHelper` Git authenticates
          to them with the CLI's login. Sign in with {command}`gh auth login`,
          {command}`glab auth login` or {command}`fj auth login`, or manage
          those logins declaratively elsewhere.
        '';
      };

      gitCredentialHelpers = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Default for every host's {option}`gitCredentialHelper`.
        '';
      };

      githubPackage = lib.mkPackageOption pkgs "gh" { };
      gitlabPackage = lib.mkPackageOption pkgs "glab" { };
      forgejoPackage = lib.mkPackageOption pkgs "forgejo-cli" { };
    };

    linkedEnvironments = mkOption {
      type = types.attrsOf (types.submodule linkModule);
      default = { };
      example = literalExpression ''
        {
          workstation = {
            sshHost = "alice@workstation";
            port = 3773;
            localPort = 37731;
          };
        }
      '';
      description = ''
        Other T3 Code environments to link this one to, so agents here can work
        there. Each peer gets an SSH tunnel user service from a loopback port
        here to its server, and {file}`t3code-link.timer` pairs over SSH and
        runs {command}`t3 environment link` whenever a link is missing or
        expires within a week. The peer lists the link under Settings →
        Connections, where it can be revoked. Sets
        `linkedEnvironmentsEnabled`; the peer needs it too.
      '';
    };

    server = {
      enable = lib.mkEnableOption "the T3 Code server as a user service";

      host = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "127.0.0.1";
        description = "Address the server binds ({command}`t3 serve --host`). `null` keeps T3 Code's default.";
      };

      port = mkOption {
        type = types.nullOr types.port;
        default = null;
        example = 3773;
        description = "Port the server listens on. `null` keeps T3 Code's default (the first free port from 3773).";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "--tailscale-serve"
          "--log-websocket-events"
        ];
        description = ''
          Extra arguments to {command}`t3 serve`. Run {command}`t3 serve --help`
          for the full list.
        '';
      };

      path = mkOption {
        type = types.listOf types.package;
        default = [ ];
        example = literalExpression "[ pkgs.tea ]";
        description = ''
          Packages placed first on the server's {env}`PATH`, ahead of the
          user's profile. Agent and forge CLIs the server runs are found on
          {env}`PATH` only.
        '';
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          T3CODE_LOG_LEVEL = "Debug";
          T3CODE_OTLP_TRACES_URL = "http://127.0.0.1:4318/v1/traces";
        };
        description = ''
          Environment of the server. {env}`T3CODE_HOME` and {env}`PATH` are
          set by default and can be overridden here.
        '';
      };

      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/t3code";
        description = ''
          An environment file (see {manpage}`systemd.exec(5)`) loaded by the
          service, for secrets such as {env}`GH_TOKEN` that must stay out of
          the Nix store.
        '';
      };

      serviceConfig = mkOption {
        type = types.attrsOf (
          types.oneOf [
            types.str
            types.int
            types.bool
            (types.listOf types.str)
          ]
        );
        default = { };
        example = {
          Slice = "app.slice";
          UMask = "0077";
        };
        description = "Extra `[Service]` settings of the {file}`t3code.service` user unit.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.server.enable || cfg.package != null;
          message = "programs.t3code.server.enable requires programs.t3code.package.";
        }
        {
          assertion = !cfg.server.enable || pkgs.stdenv.hostPlatform.isLinux;
          message = "programs.t3code.server is only supported on Linux (systemd).";
        }
        {
          assertion = builtins.all validThemeId themeIds;
          message = "programs.t3code.themes: ids must match [a-z0-9][a-z0-9-]{0,47} and not be a reserved or built-in theme id.";
        }
        {
          assertion = builtins.length themeIds <= 32;
          message = "programs.t3code.themes: T3 Code reads at most 32 theme files.";
        }
      ];

      home.packages =
        lib.optional (cfg.package != null) cfg.package
        ++ lib.optional (hasKind "github") cfg.sourceControl.githubPackage
        ++ lib.optional (hasKind "gitlab") cfg.sourceControl.gitlabPackage
        ++ lib.optional (hasKind "forgejo") cfg.sourceControl.forgejoPackage;

      home.sessionVariables = mkIf (cfg.baseDir != "${config.home.homeDirectory}/.t3") {
        T3CODE_HOME = cfg.baseDir;
      };

      programs.git.settings.credential = lib.mapAttrs' (
        name: host:
        lib.nameValuePair "https://${name}" {
          # The empty entry drops helpers inherited from broader scopes.
          helper = [
            ""
            credentialHelpers.${host.kind}
          ];
        }
      ) credentialHosts;

      home.activation.t3codeConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        t3codeMerge() {
          local path="$1" empty="$2" operation="$3" static="$4" defaults="$5" replace="$6"
          local target dynamic result temporary
          target="$(${pkgs.coreutils}/bin/readlink -m -- "$path")"
          # A link into the store is a leftover of an immutable file; replace the link.
          if [[ $target == ${builtins.storeDir}/* ]]; then
            target="$path"
          fi
          if [[ $replace == 1 || ! -e $target ]]; then
            dynamic="$empty"
          elif ! dynamic="$(${lib.getExe json5} --as-json "$target")"; then
            errorEcho "T3 Code: $target is not valid JSON; leaving it unchanged."
            return 1
          fi
          if ! result="$(${lib.getExe pkgs.jq} -n "$operation" \
            --argjson dynamic "$dynamic" \
            --argjson static "$(< "$static")" \
            --argjson defaults "$(< "$defaults")")"; then
            errorEcho "T3 Code: could not merge settings into $target; leaving it unchanged."
            return 1
          fi
          if [[ -v DRY_RUN ]]; then
            verboseEcho "T3 Code: would update $target"
            return 0
          fi
          ${pkgs.coreutils}/bin/install -d -m 0700 -- "$(${pkgs.coreutils}/bin/dirname -- "$target")"
          temporary="$(${pkgs.coreutils}/bin/mktemp -- "$target.XXXXXX")"
          printf '%s\n' "$result" > "$temporary"
          ${pkgs.coreutils}/bin/chmod 0600 -- "$temporary"
          ${pkgs.coreutils}/bin/mv -fT -- "$temporary" "$target"
        }

        ${lib.concatMapStringsSep "\n" mergeFile managedFiles}

        t3codeThemes() {
          local dir=${lib.escapeShellArg "${stateDir}/themes"} manifest id
          manifest="$dir/.home-manager"
          if [[ -v DRY_RUN ]]; then
            verboseEcho "T3 Code: would publish themes in $dir"
            return 0
          fi
          ${pkgs.coreutils}/bin/install -d -m 0700 -- "$dir"
          # Remove themes this module published before and no longer declares.
          if [[ -f $manifest ]]; then
            while IFS= read -r id; do
              if [[ $id =~ ^[a-z0-9][a-z0-9-]*$ && ! -e ${themeFiles}/$id.json ]]; then
                ${pkgs.coreutils}/bin/rm -f -- "$dir/$id.json"
              fi
            done < "$manifest"
          fi
          # Real files: the server refuses symlinked theme files.
          for id in ${lib.escapeShellArgs themeIds}; do
            ${pkgs.coreutils}/bin/install -m 0600 -T -- "${themeFiles}/$id.json" "$dir/$id.json"
          done
          printf '%s\n' ${lib.escapeShellArgs themeIds} > "$manifest"
        }
        if ${
          lib.boolToString (themeIds != [ ])
        } || [[ -f ${lib.escapeShellArg "${stateDir}/themes/.home-manager"} ]]; then
          t3codeThemes
        fi
      '';
    }

    (mkIf cfg.server.enable {
      programs.t3code.server.environment = {
        T3CODE_HOME = lib.mkDefault cfg.baseDir;
        PATH = lib.mkDefault (
          lib.concatStringsSep ":" (
            lib.optional (cfg.server.path != [ ]) (lib.makeBinPath cfg.server.path)
            ++ [
              "${config.home.profileDirectory}/bin"
              "/etc/profiles/per-user/${config.home.username}/bin"
              "/run/current-system/sw/bin"
              "/nix/var/nix/profiles/default/bin"
              "/usr/local/bin"
              "/usr/bin"
              "/bin"
            ]
          )
        );
      };

      systemd.user.services.t3code = {
        Unit = {
          Description = "T3 Code server";
          Documentation = "https://t3.codes";
          After = [ "network.target" ];
        };

        Service = {
          ExecStart = "${lib.getExe' cfg.package "t3"} ${lib.escapeShellArgs serverArgs}";
          Restart = "on-failure";
          RestartSec = 5;
        }
        // lib.optionalAttrs (cfg.server.environmentFile != null) {
          EnvironmentFile = toString cfg.server.environmentFile;
        }
        // cfg.server.serviceConfig
        // {
          # Raw entries come last, so they win per variable without dropping the others.
          Environment =
            lib.mapAttrsToList (name: value: "${name}=${value}") cfg.server.environment
            ++ lib.toList (cfg.server.serviceConfig.Environment or [ ]);
        };

        Install.WantedBy = [ "default.target" ];
      };
    })

    (mkIf (cfg.linkedEnvironments != { }) {
      assertions = [
        {
          assertion = cfg.package != null && pkgs.stdenv.hostPlatform.isLinux;
          message = "programs.t3code.linkedEnvironments requires programs.t3code.package and Linux (systemd).";
        }
        {
          assertion =
            lib.allUnique localPorts
            && !(builtins.elem cfg.server.port localPorts)
            && builtins.all (name: builtins.match "[A-Za-z0-9_-]+" name != null) (
              builtins.attrNames cfg.linkedEnvironments
            );
          message = "programs.t3code.linkedEnvironments: names must match [A-Za-z0-9_-]+ and local ports must be unique and differ from server.port.";
        }
      ];

      systemd.user.services =
        lib.mapAttrs' (
          name: peer:
          lib.nameValuePair (tunnelUnit name) {
            Unit = {
              Description = "SSH tunnel to the ${name} T3 Code environment";
              After = [ "network.target" ];
              # A peer that is off keeps retrying instead of giving up.
              StartLimitIntervalSec = 0;
            };
            Service = {
              ExecStart = lib.escapeShellArgs (
                [
                  tunnel
                  "127.0.0.1:${toString peer.localPort}:127.0.0.1:${toString peer.port}"
                ]
                ++ peer.sshHost
              );
              Restart = "always";
              RestartSec = 60;
            };
            Install.WantedBy = [ "default.target" ];
          }
        ) cfg.linkedEnvironments
        // {
          t3code-link =
            let
              tunnels = map (name: "${tunnelUnit name}.service") (builtins.attrNames cfg.linkedEnvironments);
            in
            {
              Unit = {
                Description = "Link T3 Code to its peer environments";
                Wants = tunnels;
                After = tunnels ++ lib.optional cfg.server.enable "t3code.service";
              };
              Service = {
                Type = "oneshot";
                ExecStart = "${lib.getExe linkEnvironments} ${linkPeers}";
                Environment = [ "T3CODE_HOME=${cfg.baseDir}" ];
                TimeoutStartSec = "5min";
              };
            };
        };

      systemd.user.timers.t3code-link = {
        Unit.Description = "Keep T3 Code's peer environment links fresh";
        Timer = {
          OnStartupSec = "2min";
          OnUnitActiveSec = "6h";
        };
        Install.WantedBy = [ "timers.target" ];
      };
    })
  ]);
}
