# Save the T3 Code server of $T3CODE_HOME (HTTP origin $2) in the connections of
# the desktop app ($1), under a 30-day session that is renewed in its last week,
# along with the peer connections t3code-link left in desktop-connections/.
# The import fails while the app is running, which keeps its connections in memory.
subject="nix-t3code:desktop"
renew_before=$(($(date +%s) + 7 * 86400))
saved="$T3CODE_HOME/desktop-connections"
mapfile -t pending < <(grep -l '"token"' "$saved"/*.json 2>/dev/null || true)
sessions="$(t3 auth session list --json --base-dir "$T3CODE_HOME")"
own=true
entries=("${pending[@]}")
if [[ -e $T3CODE_HOME/userdata/connection-catalog.json ]] &&
  jq -e --arg subject "$subject" --argjson before "$renew_before" '
    any(.[]; .subject == $subject
      and (.expiresAt | sub("\\.[0-9]+"; "") | fromdateiso8601) > $before)' \
    <<<"$sessions" >/dev/null; then
  ((${#pending[@]} > 0)) || exit 0
  own=false
fi
umask 077
dir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/t3code-connect.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
revoke() { t3 auth session revoke "$1" --base-dir "$T3CODE_HOME" >/dev/null; }
# Tokens only pass through stdin and private files, never argv or logs.
if [[ $own == true ]]; then
  issued="$(t3 auth session issue --json --ttl 30d --label "$subject" --subject "$subject" \
    --base-dir "$T3CODE_HOME")"
  described="$(t3 environment describe --json --base-dir "$T3CODE_HOME")"
  jq -c --arg http "$2" --argjson described "$described" \
    '{environmentId: $described.environmentId, label: $described.label, httpBaseUrl: $http, token}' \
    <<<"$issued" >"$dir/own.json"
  entries+=("$dir/own.json")
fi
jq -s '
  map(("bearer:" + .environmentId) as $id
    | {peer: {environmentId, label, connectionId: $id}, http: (.httpBaseUrl | rtrimstr("/")), token, id: $id})
  | {
      schemaVersion: 1,
      targets: map(.peer + {_tag: "BearerConnectionTarget"}),
      profiles: map(.peer + {
        _tag: "BearerConnectionProfile",
        httpBaseUrl: (.http + "/"),
        wsBaseUrl: (.http | sub("^http"; "ws") + "/")
      }),
      credentials: map({
        connectionId: .id,
        credential: {_tag: "BearerConnectionCredential", token}
      }),
      remoteDpopTokens: [],
      disabledEnvironmentIds: []
    }' "${entries[@]}" >"$dir/connections.json"
if ! "$1" --import-connections "$dir/connections.json"; then
  [[ $own == false ]] || revoke "$(jq -r .sessionId <<<"$issued")"
  exit 1
fi
# Imported: keep only the expiry, which t3code-link reads to renew in time.
for file in "${pending[@]}"; do
  jq 'del(.token)' "$file" >"$file.new" && mv "$file.new" "$file"
done
[[ $own == true ]] || exit 0
# The sessions this one replaces.
jq -r --arg subject "$subject" '.[] | select(.subject == $subject) | .sessionId' <<<"$sessions" |
  while read -r id; do revoke "$id"; done
