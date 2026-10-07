#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Test d'intégration FTP : la configuration vsftpd générée (même code que
# install.sh) est lancée avec un VRAI vsftpd sur le port 2121, puis :
#   connexion FTPS, listing (incoming + media), dépôt dans incoming,
#   dépôt / suppression refusés dans media, login en clair refusé.
# Root requis (chroot, utilisateur de test). Outils : vsftpd, curl, openssl.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "root requis"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d)"; chmod 755 "$W"
PORT=2121 PID="" USER_T=ftptest PASS_T='Test-ftp-1234'
cleanup() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null
    umount "$W/srv/media" 2>/dev/null || true
    userdel -r "$USER_T" 2>/dev/null || true
    rm -rf "$W"
}
trap cleanup EXIT
FAILS=0
ok()   { echo "  ok   : $*"; }
fail() {
    echo "  FAIL : $*"; FAILS=$((FAILS+1))
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=test-ftp::$*"
    return 0
}

# --- Mise en place (comme install.sh) -------------------------------------------
id -u "$USER_T" >/dev/null 2>&1 || useradd -m -s /bin/bash "$USER_T"
echo "$USER_T:$PASS_T" | chpasswd
mkdir -p "$W/srv/incoming" "$W/srv/media" "$W/media-src/Clé"
chown root:root "$W/srv"; chmod 755 "$W/srv"
chown "$USER_T:" "$W/srv/incoming"; chmod 2775 "$W/srv/incoming"
echo "bonjour" > "$W/media-src/Clé/piste.txt"
mount --bind "$W/media-src" "$W/srv/media"
mount -o remount,bind,ro "$W/srv/media"
mkdir -p /var/run/vsftpd/empty
echo "$USER_T" > /etc/vsftpd.userlist
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj "/CN=test" \
    -keyout "$W/key.pem" -out "$W/cert.pem" 2>/dev/null

# --- Configuration générée par le code de l'installeur ---------------------------
# shellcheck source=../files/vsftpd-render.sh
. "$HERE/files/vsftpd-render.sh"
FTP_USER="$USER_T" FTP_ROOT="$W/srv" INCOMING_DIR="$W/srv/incoming" \
FTP_PASV_MIN=40000 FTP_PASV_MAX=40100 FTP_PASV_ADDRESS="" FTP_TLS=yes \
SSL_CERT="$W/cert.pem" SSL_KEY="$W/key.pem" \
    render_vsftpd "$HERE/files/vsftpd.conf.in" "$W/vsftpd.conf"
chown root:root "$W/vsftpd.conf"; chmod 600 "$W/vsftpd.conf"

# --- Démarrage ------------------------------------------------------------------------
/usr/sbin/vsftpd "$W/vsftpd.conf" -olisten_port=$PORT >"$W/vsftpd.out" 2>&1 &
PID=$!
for _ in $(seq 1 30); do
    (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.2
done
if ! kill -0 "$PID" 2>/dev/null; then
    fail "vsftpd refuse de démarrer : $(tr '\n' ' ' < "$W/vsftpd.out")"
    echo "$FAILS échec(s)"; exit 1
fi
ok "vsftpd démarre avec la configuration générée"

U="ftp://127.0.0.1:$PORT"
C=(curl -sS --max-time 20 --ssl-reqd -k -u "$USER_T:$PASS_T")

if out="$("${C[@]}" "$U/" 2>&1)" && grep -q incoming <<<"$out" && grep -q media <<<"$out"; then
    ok "connexion FTPS + listing (incoming, media)"
else
    fail "listing FTPS : $out"
fi
echo "contenu" > "$W/depot.txt"
if out="$("${C[@]}" -T "$W/depot.txt" "$U/incoming/" 2>&1)" && [[ -f "$W/srv/incoming/depot.txt" ]]; then
    ok "dépôt dans incoming"
else
    fail "dépôt dans incoming : $out"
fi
if out="$("${C[@]}" "$U/media/Cl%C3%A9/piste.txt" 2>&1)" && [[ "$out" == bonjour ]]; then
    ok "lecture dans media"
else
    fail "lecture dans media : $out"
fi
if "${C[@]}" -T "$W/depot.txt" "$U/media/Cl%C3%A9/" >/dev/null 2>&1; then
    fail "dépôt dans media ACCEPTÉ"
else
    ok "dépôt dans media refusé"
fi
if "${C[@]}" -Q "DELE /media/Clé/piste.txt" "$U/" >/dev/null 2>&1 || [[ ! -f "$W/media-src/Clé/piste.txt" ]]; then
    fail "suppression dans media ACCEPTÉE"
else
    ok "suppression dans media refusée"
fi
if curl -sS --max-time 10 -u "$USER_T:$PASS_T" "$U/" >/dev/null 2>&1; then
    fail "connexion SANS chiffrement acceptée"
else
    ok "connexion sans chiffrement refusée"
fi
if curl -sS --max-time 10 --ssl-reqd -k -u "root:x" "$U/" >/dev/null 2>&1; then
    fail "compte hors liste accepté"
else
    ok "compte hors liste refusé"
fi

echo
echo "$FAILS échec(s)"
[[ $FAILS -eq 0 ]]
