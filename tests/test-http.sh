#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Test du serveur HTTP lecture seule : la configuration lighttpd générée est
# validée (lighttpd -tt), puis l'instance est lancée sur un dossier de test :
# listing, téléchargement, plage d'octets, fichiers cachés, HTML servi en texte,
# écriture (PUT / DELETE / POST) refusée. Requiert lighttpd et curl.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d)"
PID=""
cleanup() { [[ -n "$PID" ]] && kill "$PID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
FAILS=0
ok()   { echo "  ok   : $*"; }
fail() {
    echo "  FAIL : $*"; FAILS=$((FAILS+1))
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=test-http::$*"
    return 0
}
PORT=18080
mkdir -p "$W/media/Ma Clé/Album" "$W/media/.cache"
echo "bonjour" > "$W/media/Ma Clé/Album/piste.txt"
head -c 100000 /dev/urandom > "$W/media/Ma Clé/Album/son.flac"
echo "<script>alert(1)</script>" > "$W/media/Ma Clé/page.html"
echo secret > "$W/media/.cache/x"

sed "s/@HTTP_PORT@/$PORT/g; s#^server.document-root .*#server.document-root = \"$W/media\"#" \
    "$HERE/files/lighttpd-media.conf.in" > "$W/lighttpd.conf"
if lighttpd -tt -f "$W/lighttpd.conf" >"$W/tt.log" 2>&1; then ok "lighttpd -tt"; else fail "lighttpd -tt : $(tr '\n' ' ' < "$W/tt.log")"; fi

lighttpd -D -f "$W/lighttpd.conf" >"$W/run.log" 2>&1 &
PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

code() { curl -s -o "$W/body" -w '%{http_code}' "$@"; }
U="http://127.0.0.1:$PORT"
[[ "$(code "$U/")" == 200 ]] && grep -q 'Ma Cl' "$W/body" && ok "listing de la racine" || fail "listing racine"
[[ "$(code "$U/Ma%20Cl%C3%A9/Album/")" == 200 ]] && grep -q 'piste.txt' "$W/body" && ok "listing d'un dossier accentué" || fail "listing dossier"
[[ "$(code "$U/Ma%20Cl%C3%A9/Album/piste.txt")" == 200 ]] && [[ "$(cat "$W/body")" == bonjour ]] && ok "téléchargement" || fail "téléchargement"
ct="$(curl -s -o /dev/null -w '%{content_type}' "$U/Ma%20Cl%C3%A9/Album/son.flac")"
[[ "$ct" == audio/flac* ]] && ok "type MIME flac" || fail "type MIME flac : $ct"
[[ "$(code -r 0-99 "$U/Ma%20Cl%C3%A9/Album/son.flac")" == 206 ]] && [[ "$(stat -c %s "$W/body")" == 100 ]] && ok "requête partielle (Range)" || fail "Range"
ct="$(curl -s -o /dev/null -w '%{content_type}' "$U/Ma%20Cl%C3%A9/page.html")"
[[ "$ct" == text/plain* ]] && ok "HTML servi en texte brut" || fail "HTML : $ct"
code "$U/" >/dev/null; grep -q '\.cache' "$W/body" && fail "dossier caché listé" || ok "dossiers cachés masqués"
for m in PUT DELETE POST; do
    c="$(code -X "$m" --data x "$U/Ma%20Cl%C3%A9/Album/piste.txt")"
    [[ "$c" =~ ^(403|405|501)$ ]] && ok "$m refusé ($c)" || fail "$m : code $c"
done
[[ "$(cat "$W/media/Ma Clé/Album/piste.txt")" == bonjour ]] && ok "fichier intact" || fail "fichier modifié"
[[ "$(code "$U/../../etc/passwd" --path-as-is)" =~ ^(400|403|404)$ ]] && ok "traversée de répertoire refusée" || fail "traversée"

echo
echo "$FAILS échec(s)"
[[ $FAILS -eq 0 ]]
