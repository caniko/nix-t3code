# Save the T3 Code server of $T3CODE_HOME (HTTP origin $2) in the connections of
# the desktop app ($1), under a 30-day session that is renewed in its last week.
# The import fails while the app is running, which keeps its connections in memory.
subject="nix-t3code:desktop"
renew_before=$(($(date +%s) + 7 * 86400))
sessions="$(t3 auth session list --json --base-dir "$T3CODE_HOME")"
if [[ -e $T3CODE_HOME/userdata/connection-catalog.json ]] &&
  jq -e --arg subject "$subject" --argjson before "$renew_before" '
    any(.[]; .subject == $subject
      and (.expiresAt | sub("\\.[0-9]+"; "") | fromdateiso8601) > $before)' \
    <<<"$sessions" >/dev/null; then
  exit 0
fi
environment="$(t3 environment describe --json --base-dir "$T3CODE_HOME")"
umask 077
dir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/t3code-connect.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
revoke() { t3 auth session revoke "$1" --base-dir "$T3CODE_HOME" >/dev/null; }
# The token only passes through stdin and a private file, never argv or logs.
issued="$(t3 auth session issue --json --ttl 30d --label "$subject" --subject "$subject" \
  --base-dir "$T3CODE_HOME")"
jq --argjson environment "$environment" --arg http "$2" '
  ("bearer:" + $environment.environmentId) as $id
  | ($environment | {environmentId, label, connectionId: $id}) as $peer
  | {
      schemaVersion: 1,
      targets: [$peer + {_tag: "BearerConnectionTarget"}],
      profiles: [$peer + {
        _tag: "BearerConnectionProfile",
        httpBaseUrl: ($http + "/"),
        wsBaseUrl: ($http | sub("^http"; "ws") + "/")
      }],
      credentials: [{
        connectionId: $id,
        credential: {_tag: "BearerConnectionCredential", token}
      }],
      remoteDpopTokens: [],
      disabledEnvironmentIds: []
    }' <<<"$issued" >"$dir/connections.json"
if ! "$1" --import-connections "$dir/connections.json"; then
  revoke "$(jq -r .sessionId <<<"$issued")"
  exit 1
fi
# The sessions this one replaces.
jq -r --arg subject "$subject" '.[] | select(.subject == $subject) | .sessionId' <<<"$sessions" |
  while read -r id; do revoke "$id"; done
