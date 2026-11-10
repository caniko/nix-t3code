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
- **Linked environments.** `linkedEnvironments.<name>` links this environment
  to another machine's T3 Code server through an SSH tunnel to a loopback
  port, so no server needs a public address. `sshHost` takes one destination
  or a list of routes tried in order (LAN, then VPN). A timer pairs over SSH
  and renews each link before it expires.

The server unit is Linux-only.

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

## Checks

```console
nix flake check
```

The contribution workflow follows Home Manager's
[contributing guide](https://nix-community.github.io/home-manager/#ch-contributing):
the module keeps upstream option names, documents every option, and ships a
test for its behaviour.
