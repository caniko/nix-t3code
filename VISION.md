# nix-t3code vision

A Home Manager module for T3 Code with finer control than Home Manager's
built-in `programs.t3code`, which it replaces through `disabledModules`. Option
names stay compatible with the built-in module, so adoption is a change of
implementation rather than a rename. The server unit it manages is Linux-only.

## Problem

The built-in module assumes `~/.t3`, does not manage every settings file T3 Code
reads, and cannot declare forges, environment themes, or links to other
machines. Users end up patching the store or editing app-owned files by hand,
which the app then overwrites.

## Principles

- **Compatibility first.** Option names stay compatible with the built-in
  module; the module follows Home Manager's contributing guide and ships a
  behaviour test for every option it documents.
- **The app owns its files.** Settings files stay regular, writable files
  because the server rewrites `settings.json` and `keybindings.json` itself, so
  links into the store would break it. `mutable* = false` opts into resetting a
  file to the declaration on every activation.
- **Enforced current state, seeded defaults.** `userSettings` and friends are
  enforced; `userSettingsDefaults` only fills gaps, so later changes made in the
  app survive activation.
- **One home for every component.** `baseDir` replaces the hardcoded `~/.t3`
  and is exported as `T3CODE_HOME`, so the desktop app, CLI, and service agree.
- **Secrets never travel through argv or logs.** The linked-environment script
  passes a pairing code through the shell only.
- **Themes are files.** `themes.<id>` publishes files to `userdata/themes` that
  the server hot-reloads and offers to clients; `defaultTheme` makes connected
  clients adopt one.
- **Forges are declared, not guessed.** `sourceControl.hosts` installs `gh`,
  `glab`, and `fj` for the declared hosts and can make Git authenticate HTTPS
  through their logins, which is how T3 Code recognizes hosts such as
  `codefloe.com`.

## Scope

`programs.t3code` with `baseDir`, all four settings files, `themes` and
`defaultTheme`, `sourceControl`, `server.{host,port,extraArgs,path,environment,
environmentFile,serviceConfig}`, and `linkedEnvironments.<name>`; plus the
module's forge-credential and link-renewal scripts, a Home Manager test suite,
flake checks, and a formatter.

## Non-goals

- The server unit is Linux-only.
- Linked environments need SSH reachability; the module deliberately tunnels to
  a loopback port instead of requiring a public server address.

## Direction

The three commits so far add the module, add environment linking over SSH
tunnels with a renewal timer, and keep those tunnels off SSH control masters.

## Place in the fleet

canix wires it for desktop and service use (`home/modules/desktop/t3code.nix`,
`root/modules/services/t3code.nix`) and documents it in
`docs/src/operations/t3code.md`; `nix-theme-broker`'s `t3code` target fills
`themes` and `defaultTheme` from the broker palette.
