# nix-t3code

A Home Manager module for [T3 Code](https://github.com/pingdotgg/t3code) with
finer control than Home Manager's built-in `programs.t3code`, which it replaces
(`disabledModules`). Option names stay compatible with the built-in module.

```nix
{
  inputs.nix-t3code.url = "github:caniko/nix-t3code";

  # in a Home Manager configuration
  imports = [ inputs.nix-t3code.homeManagerModules.default ];

  programs.t3code = {
    enable = true;
    baseDir = "${config.xdg.dataHome}/t3code";
    userSettings.enableProviderUpdateChecks = false;
    userSettingsDefaults.providerInstances.opencode = {
      driver = "opencode";
      enabled = true;
    };
    server = {
      enable = true;
      host = "127.0.0.1";
      port = 3774;
    };
    sourceControl = {
      gitCredentialHelpers = true;
      hosts = {
        "github.com".kind = "github";
        "gitlab.com".kind = "gitlab";
        "codeberg.org".kind = "forgejo";
        "codefloe.com".kind = "forgejo";
      };
    };
  };
}
```

## What it adds

- **Any T3 home.** `baseDir` replaces the hardcoded `~/.t3` and is exported as
  `T3CODE_HOME`, so the desktop app, CLI and service agree.
- **Every settings file.** `settings.json`, `keybindings.json`,
  `client-settings.json` and `desktop-settings.json`, each with enforced keys
  (`userSettings`, ...) and seeded keys (`userSettingsDefaults`, ...) that keep
  later changes made in the app. The files stay regular, writable files: the
  server rewrites `settings.json` and `keybindings.json` itself, so links into
  the store break it. `mutable* = false` resets a file to the declaration on
  every activation instead.
- **Environment themes.** `themes.<id>` publishes theme files to
  `userdata/themes`, which the server hot-reloads and offers to all clients.
  `defaultTheme` makes connected clients adopt one, again whenever it changes.
  [nix-theme-broker](https://github.com/caniko/nix-theme-broker)'s `t3code`
  target fills both from the broker palette.
- **Forges.** `sourceControl.hosts` installs `gh`, `glab` and `fj` for the
  declared hosts and can make Git authenticate HTTPS with their logins. T3 Code
  recognizes hosts it does not know by name, such as `codefloe.com`, only
  through such a CLI login.
- **Service tuning.** `server.{host,port,extraArgs,path,environment,environmentFile,serviceConfig}`.
- **Usage limits.** `usageLimitSources.<id>` configures CLIProxyAPI sources
  for the usage-limit display. Keys can come from a runtime file or a T3 Code
  secret-provider reference.
- **Linked environments.** `linkedEnvironments.<name>` links this environment
  to another machine's T3 Code server, at its https `urls` or else through an
  SSH tunnel to a loopback port. `sshHost` takes one destination or a list of
  routes tried in order (LAN, then VPN). A timer pairs over SSH, renews each
  link before it expires, and leaves a desktop session for each peer. With
  `linkMesh` and this environment's own `urls`, it also links the peers to each
  other and to this one, so one machine with SSH to all joins machines that
  have none.
- **Desktop connection.** `server.desktopProgram` saves the server, and the
  peers the link timer left sessions for, in the desktop app's connections
  (`--import-connections`) and renews its session, for an app that runs with
  `localEnvironmentEnabled = false`.
- **Antigravity from the store.** `antigravityPackage` makes the
  `antigravity` provider run a store copy of the Antigravity CLI, such as
  nixpkgs' `antigravity-cli`, instead of the runtime T3 Code downloads.
  `antigravityHooks` installs a `hooks.json` into the provider's private
  profile, such as harbor-llm's `programs.harborLlm.lsp.antigravityHooks`,
  which reports language-server errors in the files the agent edited. Use
  `"${config.programs.t3code.antigravityConfigDir}/mcp_config.json"` to locate
  that instance's MCP configuration.

The server unit is Linux-only.

## Usage-limit sources

```nix
programs.t3code.usageLimitSources.local-proxy = {
  label = "Local CLIProxyAPI";
  url = "http://127.0.0.1:8317";
  managementKeyFile = "/run/secrets/cliproxy-management-key";
};
```

Use an absolute runtime path string readable by the Home Manager user, not a
Nix path literal or `builtins.readFile`. Activation and `t3code.service`
pre-start read the file, trim trailing newlines, and write `settings.json` with
mode `0600`. The key stays out of the Nix store. If the file has not been
created yet, `optional = true` (the default) leaves that source unchanged;
set `optional = false` to require it.

Alternatively, set `managementKey = { provider = "vault"; reference = "proxy/management"; };`
instead of `managementKeyFile`. `managementKey` itself enters the Nix store:
use it only for a reference or a non-secret literal.

IDs must match `^[A-Za-z0-9][A-Za-z0-9._-]*$`. `kind` defaults to `"cliproxy"`,
`label` is optional, and `enable = false` keeps the source configured without
polling it. Removing a declaration removes the entry this module wrote without
removing sources created in the app, unless `mutableUserSettings = false`
resets the whole settings file. Use `systemd.user.services.t3code.Unit` to add
`Wants` and `After` for a proxy user service if needed.

## Shared server (NixOS)

`nixosModules.t3codeServer` runs one T3 Code server per machine as the system
user `t3code`, with a socket-activated runner per user, so several people share
a server while agents, terminals and Git run as the thread's owner.

```nix
{
  imports = [ inputs.nix-t3code.nixosModules.t3codeServer ];

  services.t3code = {
    enable = true;
    package = t3code;
    host = "0.0.0.0"; # default 127.0.0.1; the firewall stays yours
    oidc = {
      issuer = "https://auth.example.org/oauth2/openid/t3code";
      clientId = "t3code";
      clientSecretFile = config.age.secrets.t3code-oidc.path;
      publicOrigins = [ "https://t3.example.org" ];
      allowedGroup = "t3code_users";
    };
    runners.alice.roots = [ "/home/alice" ];
    operators = [ "alice" ];
  };
}
```

The package must provide `t3 runner`. State is `/var/lib/t3code`; operators
administer it with `sudo -u t3code /etc/t3code/t3 ...`.

- `policyFile`: non-secret policy JSON installed at `/etc/t3code/policy.json`.
  Use a store-backed file (for example, `pkgs.writeText`); changes restart
  the server. The T3 Code package must support the policy format.
- `backupGroup`: optional group with access to `/var/lib/t3code/backup`, not
  to live userdata. Set `users.groups.<group>.members` for readers and have
  the snapshot command write group-readable files.
- `extraGroups`: additional existing groups for the server user.
- `sudoExtraEnv`: non-secret settings for operator commands run as `t3code`,
  in addition to the module's fixed `T3CODE_HOME`. It does not change the
  server or runner environment.

## Scheduled backups (NixOS)

```nix
{
  imports = [ inputs.nix-t3code.nixosModules.t3codeBackup ];

  services.t3codeBackup.jobs.history = {
    onCalendar = "daily";
    user = "backup";
    execStart = "${backupPackage}/bin/backup-t3code";
  };
}
```

The job runs as the existing `backup` user and gets a private
`$STATE_DIRECTORY` (`/var/lib/t3code-backup-history` in this example). The
timer catches missed runs and adds up to 15 minutes of delay by default.
The command handles the backup itself, including what to copy and how long
to keep it. Use `group`, `environment`, `randomizedDelaySec` or
`serviceConfig` to adjust a job.

## Nightly binaries (x86_64 Linux)

```nix
inputs.nix-t3code.lib.mkT3CodeNightly {
  inherit pkgs;
  manifest = builtins.fromJSON (builtins.readFile ./manifest.json);
  runtimePackages = [ pkgs.git ]; # optional
}
```

Supply a manifest with `version` and `assets.cli` / `assets.desktop`, each
with a `url` and either an SRI `hash` or a hex `sha256`. The CLI asset must
be the glibc x64 `.tar.gz` release and the desktop asset the x86_64
AppImage. The package provides `t3` and `t3code-desktop`; `cliUnwrapped` and
`desktopPackage` are also available separately. No providers or state path
overrides are enabled by default.

## Checks

```console
nix flake check
```

The contribution workflow follows Home Manager's
[contributing guide](https://nix-community.github.io/home-manager/#ch-contributing):
the module keeps upstream option names, documents every option, and ships a
test for its behaviour.
