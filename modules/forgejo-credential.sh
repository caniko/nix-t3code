# Git credential helper answering with the token fj holds for the host.
# Forgejo accepts an access token as the password of any user name.
[[ ${1-} == get ]] || exit 0

host=""
while IFS='=' read -r key value; do
  [[ -z $key ]] && break
  [[ $key == host ]] && host="$value"
done
[[ -n $host ]] || exit 0

keys="${XDG_DATA_HOME:-$HOME/.local/share}/forgejo-cli/keys.json"
[[ -r $keys ]] || exit 0
# OAuth logins expire; whoami makes fj renew the token first.
if [[ $(jq -r --arg host "$host" '.hosts[$host].type // empty' "$keys") == OAuth ]]; then
  (cd "$HOME" && fj --host "https://$host" whoami >/dev/null 2>&1) || true
fi
token="$(jq -r --arg host "$host" '.hosts[$host].token // empty' "$keys")"
[[ -n $token ]] || exit 0

printf 'username=%s\npassword=%s\n' "t3code" "$token"
