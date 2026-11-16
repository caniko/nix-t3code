# Link T3 Code environments of one user, as described by the JSON file $1:
# {self: {urls, access}, mesh, peers: [{name, urls, destinations, command, baseDir, access}]}.
# This host's name (uname -n) names this environment to the others.
# This environment ($T3CODE_HOME) links to each peer and saves a desktop
# connection to it; with mesh, each peer does the same towards every other
# environment, so a peer that cannot reach the others still gets them all.
# A link or desktop session is (re)made when missing or within a week of
# expiring. Destinations are SSH routes to a peer, tried in order; a peer that
# none reaches is skipped.
renew_before=$(($(date +%s) + 7 * 86400))
user="$(id -un)"
self="$(uname -n)"
config="$(jq --arg self "$self" --arg home "$T3CODE_HOME" '
  [.self + {name: $self, command: "t3", baseDir: $home, destinations: []}] + .peers
  | map({key: .name, value: .}) | from_entries' "$1")"
mesh="$(jq -r .mesh "$1")"
mapfile -t names < <(jq -r 'keys[]' <<<"$config")
declare -A routes=() down=() described=()
for name in "${names[@]}"; do
  routes[$name]="$(jq -r --arg name "$name" '.[$name].destinations | join(" ")' <<<"$config")"
done
field() { jq -r --arg name "$1" ".[\$name].$2" <<<"$config"; }
# A jq filter: $before is its argument, not a shell variable.
# shellcheck disable=SC2016
fresh='.expiresAt == null or (.expiresAt | sub("\\.[0-9]+"; "") | fromdateiso8601) > $before'

# Runs $2 in the login shell of environment $1 (sh for this one), with $3 as
# its input, leaving its output in $reply. Returns 255 when no route reaches
# it, and from then on at once. The route that answers moves first, so later
# calls skip the dead ones. Not for $(...): its subshell would drop both.
run() {
  reply=""
  if [[ $1 == "$self" ]]; then
    reply="$(sh -c "$2" <<<"$3")"
    return
  fi
  [[ -z ${down[$1]:-} ]] || return 255
  local rc=255 route others=() all
  read -ra all <<<"${routes[$1]}"
  for route in "${all[@]}"; do
    rc=0
    reply="$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$route" "$2" <<<"$3")" || rc=$?
    if ((rc != 255)); then
      for other in "${all[@]}"; do [[ $other == "$route" ]] || others+=("$other"); done
      routes[$1]="$route ${others[*]}"
      break
    fi
  done
  ((rc != 255)) || down[$1]=1
  return "$rc"
}
# A T3 Code CLI command line for environment $1.
cli() { echo "$(field "$1" command) $2 --base-dir '$(field "$1" baseDir)'"; }
# Caches environment $1's {environmentId, label}: its id lets a link fall back
# to later addresses, and it names its desktop connection.
describe() {
  [[ -z ${described[$1]:-} ]] || return 0
  run "$1" "$(cli "$1" "environment describe --json")" "" || return
  described[$1]="$reply"
}

status=0
fail() {
  echo "$1" >&2
  status=1
}
for x in "${names[@]}"; do
  [[ $mesh == true || $x == "$self" ]] || continue
  set +e
  run "$x" "$(cli "$x" "environment list --json")" ""
  rc=$?
  set -e
  links="$reply"
  if ((rc == 255)); then
    echo "skip $x: ${routes[$x]} unreachable" >&2
    continue
  elif ((rc != 0)); then
    fail "failed to list the links of $x"
    continue
  fi
  # The desktop connections saved there, one {name, expiresAt} file per environment.
  if ! run "$x" "sh -c 'cat \"\$0\"/*.json 2>/dev/null; true' '$(field "$x" baseDir)/desktop-connections'" ""; then
    fail "failed to read the desktop connections of $x"
    continue
  fi
  saved="$(jq -s . <<<"$reply")"
  for y in "${names[@]}"; do
    urls="$(jq -c --arg name "$y" '.[$name].urls' <<<"$config")"
    [[ $y != "$x" && $urls != "[]" ]] || continue

    if ! jq -e --argjson urls "$urls" --argjson before "$renew_before" "
        any(.[]; any(.urls[]; IN(\$urls[])) and .status != \"expired\" and ($fresh))" \
      <<<"$links" >/dev/null; then
      # The pairing code only passes through this shell and stdin, never argv or logs.
      set +e
      describe "$y" && run "$y" "$(cli "$y" "auth pairing create --json --ttl 5m --label '$user@$x'")" ""
      rc=$?
      set -e
      pairing="$reply"
      if ((rc == 255)); then
        echo "skip $x -> $y: ${routes[$y]} unreachable" >&2
        continue
      fi
      if ((rc != 0)) || ! code="$(jq -er .credential <<<"$pairing")"; then
        fail "failed to pair $x with $y"
      else
        mapfile -t addresses < <(jq -r '.[]' <<<"$urls")
        link="environment link '${addresses[0]}' --expect-environment-id '$(jq -r .environmentId <<<"${described[$y]}")'"
        for address in "${addresses[@]:1}"; do link+=" --url '$address'"; done
        run "$x" "$(cli "$x" "$link --pairing-code - --access $(field "$y" access)")" "$code" ||
          fail "failed to link $x to $y"
      fi
    fi

    if ! jq -e --arg name "$y" --argjson before "$renew_before" "
        any(.[]; .name == \$name and ($fresh))" <<<"$saved" >/dev/null; then
      # A new session for the desktop app there; the one it replaces lapses on its own.
      set +e
      describe "$y" && run "$y" "$(cli "$y" "auth session issue --json --ttl 30d --label 'T3 Code desktop on $x' --subject 'nix-t3code:desktop:$x'")" ""
      rc=$?
      set -e
      if ((rc == 255)); then
        echo "skip desktop $x -> $y: ${routes[$y]} unreachable" >&2
        continue
      elif ((rc != 0)); then
        fail "failed to issue a desktop session on $y for $x"
        continue
      fi
      # The last route is the most widely reachable one, for a desktop that roams.
      # The token stays on stdin, out of every argv.
      entry="$(jq -c --arg name "$y" --argjson urls "$urls" --argjson described "${described[$y]}" '
        {name: $name, environmentId: $described.environmentId, label: $described.label,
         httpBaseUrl: ($urls | last), token, expiresAt}' <<<"$reply")"
      # Renamed into place, so an import never reads half a file.
      run "$x" "sh -c 'umask 077 && mkdir -p \"\$0\" && cat > \"\$0/.$y.tmp\" && mv \"\$0/.$y.tmp\" \"\$0/$y.json\"' '$(field "$x" baseDir)/desktop-connections'" "$entry" ||
        fail "failed to save the $y desktop connection on $x"
    fi
  done
done
exit "$status"
