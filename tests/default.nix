{
  pkgs,
  home-manager,
  module,
  serverModule,
  agy-acp-server,
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
              sshHost = [
                "tester@lan"
                "tester@peer"
              ];
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

  fakeAgy = pkgs.writeShellScriptBin "agy_acp_server.par" "";
  agyHooks = pkgs.writeText "hooks.json" ''{"lsp":{"PreToolUse":[]}}'';
  first = configuration {
    programs.t3code.antigravityPackage = fakeAgy;
    programs.t3code.antigravityHooks = agyHooks;
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

  # The shared system server: unit names and paths are a contract with the T3
  # CLI and with modules that extend the units by name.
  system =
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = null;
      modules = [
        serverModule
        {
          nixpkgs.pkgs = pkgs;
          users.users.alice = {
            isNormalUser = true;
            home = "/home/alice";
          };
          services.t3code = {
            enable = true;
            package = pkgs.writeShellScriptBin "t3" "";
            host = "0.0.0.0";
            oidc = {
              issuer = "https://auth.example.org/oauth2/openid/t3code";
              clientId = "t3code";
              clientSecretFile = "/run/secrets/t3code";
              publicOrigins = [
                "https://a.example.org"
                "https://b.example.org"
              ];
              allowedGroup = "t3code_users";
            };
            runners.alice = {
              roots = [
                "/home/alice"
                "/data/alice"
              ];
              environment = [ "FOO=bar" ];
            };
            operators = [ "alice" ];
          };
        }
      ];
    }).config;
  systemServer = system.systemd.services.t3code;
  runner = system.systemd.services."t3-runner@alice";

  activation = config: pkgs.writeText "t3code-activation" config.home.activation.t3codeConfig.data;
  service = first.systemd.user.services.t3code.Service;
  tunnel = toString first.systemd.user.services.t3code-tunnel-peer.Service.ExecStart;
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
assert lib.assertMsg
  (lib.hasSuffix "-t3code-tunnel 127.0.0.1:37741:127.0.0.1:3774 tester@lan tester@peer" tunnel)
  "tunnel unit missing";
assert lib.assertMsg (first.systemd.user.timers ? t3code-link) "link timer missing";
assert lib.assertMsg (
  !(configuration { programs.t3code.linkedEnvironments.peer.urls = [ "https://peer" ]; })
  .systemd.user.services
    ? t3code-tunnel-peer
) "a peer with urls needs no tunnel";
assert lib.assertMsg (
  !(first.systemd.user.services ? t3code-desktop-connect)
) "desktop connection must be opt-in";
assert lib.assertMsg (lib.hasSuffix "/bin/desktop http://127.0.0.1:3774" (
  toString
    (configuration { programs.t3code.server.desktopProgram = "desktop"; })
    .systemd.user.services.t3code-desktop-connect.Service.ExecStart
)) "desktop connection unit must target the declared server";
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
assert lib.assertMsg
  (lib.hasSuffix "/bin/t3 serve --host 0.0.0.0 --port 3773" systemServer.serviceConfig.ExecStart)
  "unexpected system ExecStart";
assert lib.assertMsg (
  systemServer.environment.T3CODE_OIDC_PUBLIC_ORIGINS == "https://a.example.org,https://b.example.org"
  && systemServer.environment.T3CODE_RUNNER_SOCKET_TEMPLATE == "/run/t3code/runner-%u.sock"
  && systemServer.environment.T3CODE_HOME == system.services.t3code.stateDir
) "system server environment";
assert lib.assertMsg (
  system.systemd.sockets."t3-runner@".listenStreams == [ "/run/t3code/runner-%i.sock" ]
  && system.systemd.sockets."t3-runner@alice".wantedBy == [ "sockets.target" ]
  && system.systemd.sockets."t3-runner@alice".overrideStrategy == "asDropin"
) "runner socket";
assert lib.assertMsg (
  builtins.head runner.serviceConfig.ExecStart == ""
  && lib.hasSuffix "/bin/t3 runner --allow-root /home/alice --allow-root /data/alice" (
    lib.last runner.serviceConfig.ExecStart
  )
  && runner.serviceConfig.Environment == [ "FOO=bar" ]
  && runner.serviceConfig.WorkingDirectory == "/home/alice"
) "runner drop-in";
assert lib.assertMsg (
  builtins.elem "a+ /data/alice - - - - u:t3code:--x" system.systemd.tmpfiles.rules
  && !(lib.any (lib.hasPrefix "C ") system.systemd.tmpfiles.rules)
) "traverse ACLs, and no settings seed without initialSettings";
assert lib.assertMsg (lib.any (
  rule: rule.runAs == "t3code" && rule.users == [ "alice" ]
) system.security.sudo.extraRules) "operator sudo rule";
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
        jq -e '.providerInstances.antigravity == {"driver": "antigravity", "config": {"binaryPath": "${lib.getExe fakeAgy}"}}' "$s"
        [[ $(stat -c %a "$s") == 600 ]]
        hooks="$state/providers/antigravity/${builtins.hashString "sha256" "antigravity"}/config/hooks.json"
        cmp "$hooks" ${agyHooks}
        [[ ! -L $hooks && $(stat -c %a "$hooks" "''${hooks%/config/hooks.json}") == $'600\n700' ]]
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
        [[ ! -e $hooks ]]
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

  connect-desktop =
    pkgs.runCommand "t3code-connect-desktop-test"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        mkdir -p bin base/userdata
        export PATH="$PWD/bin:$PATH" LOG="$PWD/log" SESSIONS="$PWD/sessions.json" T3CODE_HOME="$PWD/base"
        export XDG_RUNTIME_DIR="$PWD"
        cat > bin/t3 <<'EOF'
        #!${pkgs.runtimeShell}
        case "$1 $2 $3" in
          "auth session list") cat "$SESSIONS" ;;
          "auth session issue") echo '{"sessionId": "new", "token": "secret"}' ;;
          "auth session revoke") echo "revoke $4" >> "$LOG" ;;
          "environment describe --json") echo '{"environmentId": "env", "label": "host"}' ;;
          *) exit 2 ;;
        esac
        EOF
        cat > bin/desktop <<'EOF'
        #!${pkgs.runtimeShell}
        [[ $1 == --import-connections && $(stat -c %a "$2") == 600 && ! -e $PWD/running ]] || exit 1
        cp "$2" "$PWD/imported.json"
        touch "$T3CODE_HOME/userdata/connection-catalog.json"
        EOF
        chmod +x bin/*
        connect() { bash -euo pipefail ${../modules/connect-desktop.sh} desktop http://127.0.0.1:3774; }
        session() { echo "[{\"sessionId\": \"$1\", \"subject\": \"$2\", \"expiresAt\": \"$(date -u -d "$3" +%Y-%m-%dT%H:%M:%S.000Z)\"}]"; }

        # A running app refuses the import: the new session is revoked, the old one kept.
        session old nix-t3code:desktop "+2 days" > sessions.json
        touch running
        ! connect
        [[ $(cat log) == "revoke new" ]]

        rm running log
        connect
        [[ $(cat log) == "revoke old" ]]
        jq -e '
          .schemaVersion == 1
          and .targets == [{_tag: "BearerConnectionTarget", environmentId: "env", label: "host", connectionId: "bearer:env"}]
          and (.profiles[0] | .httpBaseUrl == "http://127.0.0.1:3774/" and .wsBaseUrl == "ws://127.0.0.1:3774/")
          and .credentials == [{connectionId: "bearer:env", credential: {_tag: "BearerConnectionCredential", token: "secret"}}]
        ' imported.json
        [[ -z $(find . -name "t3code-connect.*") ]]

        # A fresh session with a saved catalog is left alone; another subject's is not ours.
        rm log imported.json
        session fresh nix-t3code:desktop "+20 days" > sessions.json
        connect
        [[ ! -e log && ! -e imported.json ]]
        session other mcp-client "+20 days" > sessions.json
        connect
        [[ -e imported.json && ! -e log ]]

        # A peer connection left by t3code-link is imported alone; only its expiry stays.
        rm imported.json
        session fresh nix-t3code:desktop "+20 days" > sessions.json
        mkdir base/desktop-connections
        echo '{"name": "peer", "environmentId": "p", "label": "peer", "httpBaseUrl": "https://peer.vpn", "token": "t", "expiresAt": "x"}' > base/desktop-connections/peer.json
        connect
        [[ ! -e log ]]
        jq -e '
          .targets == [{_tag: "BearerConnectionTarget", environmentId: "p", label: "peer", connectionId: "bearer:p"}]
          and (.profiles[0] | .httpBaseUrl == "https://peer.vpn/" and .wsBaseUrl == "wss://peer.vpn/")
          and .credentials[0].credential.token == "t"
        ' imported.json
        jq -e '. == {name: "peer", environmentId: "p", label: "peer", httpBaseUrl: "https://peer.vpn", expiresAt: "x"}' base/desktop-connections/peer.json
        rm imported.json
        connect
        [[ ! -e imported.json ]]

        touch "$out"
      '';

  link-environments =
    pkgs.runCommand "t3code-link-environments-test"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.shellcheck
        ];
      }
      ''
        set -euo pipefail
        # writeShellApplication fails the packaged scripts on any shellcheck finding.
        shellcheck -s bash ${../modules/link-environments.sh} ${../modules/connect-desktop.sh}
        # The tunnel must not reuse an SSH control master.
        grep -q ControlPath=none ${lib.head (lib.splitString " " tunnel)}
        mkdir bin
        export PATH="$PWD/bin:$PATH" LOG="$PWD/log" LINKS="$PWD/links.json" T3CODE_HOME="$PWD/base"
        expires() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
        export LATER="$(expires '+30 days')"
        # Answers for environment $T3 (this one, or the SSH destination).
        cat > bin/t3 <<'EOF'
        #!/bin/sh
        at="''${T3:-self}"
        case "$1 $2 $3" in
          "environment list --json") if [ "$at" = self ]; then cat "$LINKS"; else echo '[]'; fi ;;
          "environment link "*) echo "link@$at $* $(cat)" >> "$LOG" ;;
          "auth pairing create") echo "{\"credential\": \"code-$at\"}" ;;
          "environment describe --json") echo "{\"environmentId\": \"id-$at\", \"label\": \"$at\"}" ;;
          "auth session issue") echo "{\"token\": \"tok-$at\", \"expiresAt\": \"$LATER\"}" ;;
          *) exit 2 ;;
        esac
        EOF
        # Exit 255 (unreachable) for "down"; every command fails for "bad".
        cat > bin/ssh <<'EOF'
        #!/bin/sh
        destination="$5"
        echo "ssh $destination $6" >> "$LOG"
        case "$destination" in
          down) exit 255 ;;
          bad) exit 1 ;;
        esac
        T3="$destination" exec sh -c "$6"
        EOF
        chmod +x bin/*
        mkdir -p base/desktop-connections
        echo "{\"name\": \"fresh\", \"expiresAt\": \"$(expires '+20 days')\"}" > base/desktop-connections/fresh.json
        cat > links.json <<EOF
        [
          {"urls": ["http://127.0.0.1:1"], "status": "reachable", "expiresAt": "$(expires '+30 days')"},
          {"urls": ["http://127.0.0.1:2"], "status": "reachable", "expiresAt": "$(expires '+2 days')"}
        ]
        EOF
        peer() { echo "{\"name\": \"$2\", \"urls\": [\"http://127.0.0.1:$1\"], \"destinations\": [\"down\", \"$3\"], \"command\": \"t3\", \"baseDir\": \"/b\", \"access\": \"read-only\"}"; }
        echo "{\"self\": {\"urls\": [], \"access\": \"approval-required\"}, \"mesh\": false, \"peers\": [$(peer 1 fresh fresh), $(peer 2 soon soon), $(peer 3 off down), $(peer 4 ok ok), $(peer 5 bad bad)]}" > peers.json

        set +e
        bash -euo pipefail ${../modules/link-environments.sh} peers.json
        status=$?
        set -e
        # A failed pairing fails the run; an unreachable peer does not.
        [[ $status == 1 ]]
        grep -qx "link@self environment link http://127.0.0.1:2 --expect-environment-id id-soon --pairing-code - --access read-only --base-dir $T3CODE_HOME code-soon" log
        grep -qx "link@self environment link http://127.0.0.1:4 --expect-environment-id id-ok --pairing-code - --access read-only --base-dir $T3CODE_HOME code-ok" log
        [[ $(grep -c '^link' log) == 2 ]]
        if grep -q '^ssh fresh ' log; then exit 1; fi
        # The dead route is tried once per peer; the one that answered goes first after.
        [[ $(grep -c '^ssh down ' log) == 5 ]]
        grep -qx "ssh ok t3 auth pairing create --json --ttl 5m --label '$(id -un)@$(uname -n)' --base-dir '/b'" log
        # Desktop sessions for the peers that answered, saved privately; a fresh one is kept.
        jq -e --arg later "$LATER" '. == {name: "ok", environmentId: "id-ok", label: "ok", httpBaseUrl: "http://127.0.0.1:4", token: "tok-ok", expiresAt: $later}' base/desktop-connections/ok.json
        [[ $(stat -c %a base/desktop-connections/ok.json) == 600 ]]
        [[ -f base/desktop-connections/soon.json && ! -e base/desktop-connections/bad.json && ! -e base/desktop-connections/off.json ]]
        jq -e 'has("token") | not' base/desktop-connections/fresh.json

        # Mesh: each peer links to the others and to this environment, and gets their desktop sessions.
        rm log
        mesh() { echo "{\"name\": \"$1\", \"urls\": [\"https://$1.lan\", \"https://$1.vpn\"], \"destinations\": [\"$1\"], \"command\": \"t3\", \"baseDir\": \"$PWD/mesh-$1\", \"access\": \"auto\"}"; }
        echo "{\"self\": {\"urls\": [\"https://self.vpn\"], \"access\": \"approval-required\"}, \"mesh\": true, \"peers\": [$(mesh a), $(mesh b)]}" > mesh.json
        echo '[]' > links.json
        bash -euo pipefail ${../modules/link-environments.sh} mesh.json
        grep -qx "link@a environment link https://self.vpn --expect-environment-id id-self --pairing-code - --access approval-required --base-dir $PWD/mesh-a code-self" log
        grep -qx "link@a environment link https://b.lan --expect-environment-id id-b --url https://b.vpn --pairing-code - --access auto --base-dir $PWD/mesh-a code-b" log
        grep -qx "link@b environment link https://a.lan --expect-environment-id id-a --url https://a.vpn --pairing-code - --access auto --base-dir $PWD/mesh-b code-a" log
        grep -qx "link@self environment link https://a.lan --expect-environment-id id-a --url https://a.vpn --pairing-code - --access auto --base-dir $T3CODE_HOME code-a" log
        [[ $(grep -c '^link' log) == 6 ]]
        jq -e '.httpBaseUrl == "https://self.vpn" and .token == "tok-self"' mesh-a/desktop-connections/$(uname -n).json
        jq -e '.httpBaseUrl == "https://b.vpn" and .token == "tok-b"' mesh-a/desktop-connections/b.json
        jq -e '.httpBaseUrl == "https://a.vpn"' base/desktop-connections/a.json
        touch "$out"
      '';

  # Patching the launcher appends a segment after the Python app zipped onto
  # its end; the app's archive must survive intact. The ACP handshake itself
  # cannot run here: the launcher's tcmalloc aborts without /sys, which the
  # build sandbox lacks.
  agy-acp-server =
    pkgs.runCommand "agy-acp-server-test"
      {
        nativeBuildInputs = [
          pkgs.patchelf
          pkgs.python3
        ];
      }
      ''
        set -euo pipefail
        par=${lib.getExe agy-acp-server}
        [[ -x ${agy-acp-server}/bin/localharness_external ]]
        [[ $(patchelf --print-interpreter "$par") == /nix/store/* ]]
        end=$(python3 -c 'import mmap, sys; f = open(sys.argv[1], "rb"); print(mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ).rfind(b"PK\x05\x06") + 22)' "$par")
        head -c "$end" "$par" > app.zip
        python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); z.getinfo(sys.argv[2]); assert z.testzip() is None' \
          app.zip google3/cloud/developer_experience/antigravity_extensions/acp_server/main.py
        touch "$out"
      '';
}
