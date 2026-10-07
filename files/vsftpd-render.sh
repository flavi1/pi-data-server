# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# render_vsftpd TEMPLATE SORTIE
#   Génère vsftpd.conf. Utilisé par install.sh ET par tests/test-ftp.sh (même code).
#   Variables lues : FTP_USER FTP_ROOT INCOMING_DIR FTP_PASV_MIN FTP_PASV_MAX
#                    FTP_PASV_ADDRESS FTP_TLS SSL_CERT SSL_KEY
#   Les certificats doivent exister si FTP_TLS=yes.
render_vsftpd() {
    local tpl="$1" out="$2" pasv tls
    pasv="# pasv_address non défini : l'adresse locale de la Pi est annoncée"
    if [[ -n "${FTP_PASV_ADDRESS:-}" ]]; then
        pasv="pasv_address=$FTP_PASV_ADDRESS"
        [[ "$FTP_PASV_ADDRESS" =~ ^[0-9.]+$ ]] || pasv+=$'\npasv_addr_resolve=YES'
    fi
    if [[ "${FTP_TLS:-yes}" == "yes" ]]; then
        # Options reconnues par vsftpd 3.0.5 de Debian : PAS de ssl_tlsv1_1/_2/_3
        # (refusées : « unrecognised variable »). ssl_tlsv1=YES autorise TLS 1.x ;
        # OpenSSL 3 (Debian) impose de toute façon TLS 1.2 minimum.
        tls="ssl_enable=YES
rsa_cert_file=${SSL_CERT}
rsa_private_key_file=${SSL_KEY}
force_local_logins_ssl=YES
force_local_data_ssl=YES
ssl_sslv2=NO
ssl_sslv3=NO
ssl_tlsv1=YES
require_ssl_reuse=NO
ssl_ciphers=HIGH"
    else
        tls="# ATTENTION : FTP non chiffré, mot de passe en clair sur le réseau
ssl_enable=NO"
    fi
    PASV_LINES="$pasv" TLS_LINES="$tls" FTP_USER="$FTP_USER" FTP_ROOT="$FTP_ROOT" \
    INCOMING_DIR="$INCOMING_DIR" FTP_PASV_MIN="$FTP_PASV_MIN" FTP_PASV_MAX="$FTP_PASV_MAX" \
    python3 - "$tpl" "$out" <<'PY'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
for k in ("FTP_USER", "FTP_ROOT", "INCOMING_DIR", "FTP_PASV_MIN", "FTP_PASV_MAX"):
    t = t.replace("@%s@" % k, os.environ[k])
t = t.replace("@PASV_ADDRESS_LINES@", os.environ["PASV_LINES"])
t = t.replace("@TLS_LINES@", os.environ["TLS_LINES"])
open(sys.argv[2], "w", encoding="utf-8").write(t)
PY
}
