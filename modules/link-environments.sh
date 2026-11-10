# Link this T3 Code environment ($T3CODE_HOME) to each peer in the JSON file $1:
# [{url, destinations, pairing, access}]. A link is (re)made when it is missing,
# expired, or expires within a week. Destinations are SSH routes to the peer,
# tried in order; a peer that none reaches is skipped.
renew_before=$(($(date +%s) + 7 * 86400))
label="$(id -un)@$(uname -n)"
links="$(t3 environment list --json --base-dir "$T3CODE_HOME")"
mapfile -t peers < <(jq -c '.[]' "$1")
status=0
for peer in "${peers[@]}"; do
  url="$(jq -r .url <<<"$peer")"
  if jq -e --arg url "$url" --argjson before "$renew_before" '
      any(.[]; any(.urls[]; . == $url) and .status != "expired"
        and (.expiresAt == null
          or (.expiresAt | sub("\\.[0-9]+"; "") | fromdateiso8601) > $before))' \
    <<<"$links" >/dev/null; then
    continue
  fi
  mapfile -t destinations < <(jq -r '.destinations[]' <<<"$peer")
  rc=255
  for destination in "${destinations[@]}"; do
    # The pairing code only passes through this shell, never argv or logs.
    set +e
    pairing="$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$destination" \
      "$(jq -r .pairing <<<"$peer") --label '$label'")"
    rc=$?
    set -e
    ((rc == 255)) || break
  done
  if ((rc == 255)); then
    echo "skip $url: ${destinations[*]} unreachable" >&2
    continue
  fi
  if ((rc != 0)) || ! code="$(jq -er .credential <<<"$pairing")" ||
    ! printf '%s\n' "$code" | t3 environment link "$url" --pairing-code - \
      --access "$(jq -r .access <<<"$peer")" --base-dir "$T3CODE_HOME"; then
    echo "failed to link $url through $destination" >&2
    status=1
  fi
done
exit "$status"
