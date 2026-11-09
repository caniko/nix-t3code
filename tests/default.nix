{
  pkgs,
  home-manager,
  module,
}:
let
  inherit (pkgs) lib;
  # Rewritten to a directory inside the build at run time.
  home = "/t3code-test-home";

  configuration =
    extra:
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        module
        {
          home = {
            username = "tester";
            homeDirectory = home;
            stateVersion = "25.11";
          };
          programs.git.enable = true;
          programs.gh = {
            enable = true;
            gitCredentialHelper.enable = true;
          };
          programs.t3code = {
            enable = true;
            package = pkgs.writeShellScriptBin "t3" "";
            userSettings = {
              enableProviderUpdateChecks = false;
              nested.a = 1;
            };
            userSettingsDefaults = {
              providerInstances.opencode = {
                driver = "opencode";
                enabled = true;
              };
              seeded = "nix";
            };
            clientSettings.timestampFormat = "24-hour";
            keybindings = [
              {
                key = "mod+j";
                command = "terminal.toggle";
              }
            ];
            defaultTheme = "broker";
            sourceControl = {
              gitCredentialHelpers = true;
              hosts = {
                "github.com".kind = "github";
                "gitlab.com".kind = "gitlab";
                "codefloe.com".kind = "forgejo";
                "codeberg.org" = {
                  kind = "forgejo";
                  gitCredentialHelper = false;
                };
              };
            };
            server = {
              enable = true;
              host = "127.0.0.1";
              port = 3774;
              environment.T3CODE_LOG_LEVEL = "Debug";
              serviceConfig = {
                Slice = "app.slice";
                Environment = [ "EXTRA=1" ];
              };
            };
            linkedEnvironments.peer = {
              sshHost = "tester@peer";
              port = 3774;
              localPort = 37741;
            };
          };
        }
        extra
      ];
    }).config;

  theme = accent: {
    name = "Broker";
    appearance = "dark";
    canvas = "#101010";
    inherit accent;
  };

  first = configuration {
    programs.t3code.themes = {
      broker = theme "#ff0000";
      old = theme "#00ff00";
    };
  };
  second = configuration {
    programs.t3code = {
      themes.broker = theme "#0000ff";
      mutableUserSettings = false;
    };
  };

  noGh = configuration { programs.gh.enable = lib.mkForce false; };

  activation = config: pkgs.writeText "t3code-activation" config.home.activation.t3codeConfig.data;
  service = first.systemd.user.services.t3code.Service;
  credential = first.programs.git.settings.credential;
  helpers = host: credential."https://${host}".helper;
in
assert lib.assertMsg
  (lib.hasSuffix "/bin/t3 serve --base-dir ${home}/.t3 --no-browser --host 127.0.0.1 --port 3774" (
    toString service.ExecStart
  ))
  "unexpected ExecStart: ${toString service.ExecStart}";
assert lib.assertMsg (toString service.Slice == "app.slice") "serviceConfig not merged";
assert lib.assertMsg (lib.all (entry: builtins.elem entry service.Environment) [
  "T3CODE_HOME=${home}/.t3"
  "T3CODE_LOG_LEVEL=Debug"
  "EXTRA=1"
]) "server.environment and raw serviceConfig.Environment must both reach the unit";
assert lib.assertMsg (lib.hasInfix "-L 127.0.0.1:37741:127.0.0.1:3774 tester@peer" (
  toString first.systemd.user.services.t3code-tunnel-peer.Service.ExecStart
)) "tunnel unit missing";
assert lib.assertMsg (lib.hasInfix "ControlPath=none" (
  toString first.systemd.user.services.t3code-tunnel-peer.Service.ExecStart
)) "tunnel must not reuse an SSH control master";
assert lib.assertMsg (first.systemd.user.timers ? t3code-link) "link timer missing";
assert lib.assertMsg (lib.hasInfix "glab auth git-credential" (
  lib.last (helpers "gitlab.com")
)) "glab helper missing";
assert lib.assertMsg (lib.hasSuffix "t3code-forgejo-credential" (
  lib.last (helpers "codefloe.com")
)) "fj helper missing";
assert lib.assertMsg (!(credential ? "https://codeberg.org")) "opted-out host got a helper";
# programs.gh owns github.com's helper; the module must not add a second one.
assert lib.assertMsg (
  builtins.length (builtins.filter (lib.hasInfix "gh auth git-credential") (helpers "github.com"))
  == 1
) "duplicate gh helper";
# Without programs.gh, the module installs the github.com helper itself.
assert lib.assertMsg (lib.hasInfix "gh auth git-credential" (
  lib.last noGh.programs.git.settings.credential."https://github.com".helper
)) "gh helper missing when programs.gh is off";
{
  activation =
    pkgs.runCommand "t3code-activation-test"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        set -euo pipefail
        root="$PWD/home"
        state="$root/.t3/userdata"
        errorEcho() { echo "error: $*" >&2; }
        verboseEcho() { :; }
        activate() { source <(sed "s|${home}|$root|g" "$1"); }

        mkdir -p "$state/themes"
        cat > "$state/settings.json" <<'EOF'
        {
          // written by the app
          "enableProviderUpdateChecks": true,
          "nested": { "b": 2 },
          "seeded": "app",
          "keep": 1,
        }
        EOF
        echo '{"settings": {"fontSizeCode": 15}}' > "$state/client-settings.json"
        echo '[{"key": "mod+k", "command": "y"}, {"key": "mod+j", "command": "x"}]' > "$state/keybindings.json"
        echo '{"name": "Mine", "appearance": "light", "canvas": "#ffffff", "accent": "#000000"}' > "$state/themes/manual.json"

        activate ${activation first}
        s="$state/settings.json"
        jq -e '.enableProviderUpdateChecks == false and .nested == {"a": 1, "b": 2} and .seeded == "app" and .keep == 1' "$s"
        jq -e '.providerInstances.opencode.enabled and .defaultTheme == "broker" and (.defaultThemeSetAt | startswith("nix-"))' "$s"
        jq -e '.linkedEnvironmentsEnabled' "$s"
        [[ $(stat -c %a "$s") == 600 ]]
        jq -e '. == {"fontSizeCode": 15, "timestampFormat": "24-hour"}' "$state/client-settings.json"
        jq -e 'map([.key, .command]) == [["mod+k", "y"], ["mod+j", "terminal.toggle"]]' "$state/keybindings.json"
        for id in broker old manual; do [[ -f $state/themes/$id.json && ! -L $state/themes/$id.json ]]; done
        jq -e '.accent == "#ff0000"' "$state/themes/broker.json"
        setAt="$(jq -r .defaultThemeSetAt "$s")"

        before="$(cat "$state"/*.json | sha256sum)"
        activate ${activation first}
        [[ $(cat "$state"/*.json | sha256sum) == "$before" ]]

        activate ${activation second}
        [[ ! -e $state/themes/old.json && -f $state/themes/manual.json ]]
        jq -e '.accent == "#0000ff"' "$state/themes/broker.json"
        [[ $(jq -r .defaultThemeSetAt "$s") != "$setAt" ]]
        # Immutable: exactly the declaration, app keys and defaults' app values gone.
        jq -e '(has("keep") | not) and .enableProviderUpdateChecks == false and .seeded == "nix"' "$s"

        # A link to a file outside the store is followed, not replaced.
        mv "$s" "$root/linked.json"
        ln -s "$root/linked.json" "$s"
        activate ${activation first}
        [[ -L $s ]]
        jq -e ".enableProviderUpdateChecks == false" "$root/linked.json"

        # Unreadable app state fails activation and stays untouched.
        for broken in "{ not json" ""; do
          printf "%s" "$broken" > "$root/linked.json"
          # errexit is ignored inside conditions, so run it as a plain command.
          set +e
          (set -e; activate ${activation first}) 2> errors
          status=$?
          set -e
          [[ $status != 0 ]]
          grep -q "not valid JSON" errors
          [[ $(cat "$root/linked.json") == "$broken" ]]
        done

        touch "$out"
      '';

  link-environments =
    pkgs.runCommand "t3code-link-environments-test"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        set -euo pipefail
        mkdir bin
        export PATH="$PWD/bin:$PATH" LOG="$PWD/log" LINKS="$PWD/links.json" T3CODE_HOME="$PWD/base"
        cat > bin/t3 <<'EOF'
        #!/bin/sh
        case "$1 $2" in
          "environment list") cat "$LINKS" ;;
          "environment link") echo "link $3 $(cat)" >> "$LOG" ;;
        esac
        EOF
        # Exit 255 (unreachable) for "down", a failed pairing for "bad".
        cat > bin/ssh <<'EOF'
        #!/bin/sh
        destination="$5"
        echo "ssh $destination $6" >> "$LOG"
        case "$destination" in
          down) exit 255 ;;
          bad) exit 1 ;;
        esac
        echo "{\"credential\": \"code-$destination\"}"
        EOF
        chmod +x bin/*
        expires() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
        cat > links.json <<EOF
        [
          {"urls": ["http://127.0.0.1:1"], "status": "reachable", "expiresAt": "$(expires '+30 days')"},
          {"urls": ["http://127.0.0.1:2"], "status": "reachable", "expiresAt": "$(expires '+2 days')"}
        ]
        EOF
        peer() { echo "{\"url\": \"http://127.0.0.1:$1\", \"destination\": \"$2\", \"pairing\": \"t3 auth pairing create --base-dir '/b'\", \"access\": \"read-only\"}"; }
        echo "[$(peer 1 fresh), $(peer 2 soon), $(peer 3 down), $(peer 4 ok), $(peer 5 bad)]" > peers.json

        set +e
        bash -euo pipefail ${../modules/link-environments.sh} peers.json
        status=$?
        set -e
        # A failed pairing fails the run; an unreachable peer does not.
        [[ $status == 1 ]]
        grep -qx "link http://127.0.0.1:2 code-soon" log
        grep -qx "link http://127.0.0.1:4 code-ok" log
        [[ $(grep -c '^link ' log) == 2 ]]
        if grep -q ' fresh ' log; then exit 1; fi
        grep -qx "ssh ok t3 auth pairing create --base-dir '/b' --label '$(id -un)@$(uname -n)'" log
        touch "$out"
      '';
}
