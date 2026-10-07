#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  pi-data-server — serveur de données
#   - automontage udev de tous les disques amovibles, lecture seule absolue
#   - HTTP (lighttpd, instance dédiée) : /media en lecture seule, public
#   - FTP (vsftpd, FTPS) : /incoming en lecture/écriture, /media en lecture seule
#
#  Autonome : fonctionne seul sur Raspberry Pi OS (Debian). Si pi-server est
#  présent, ses règles de pare-feu sont simplement complétées.
#
#     sudo bash install.sh [--non-interactive]
#
#  Idempotent : relancez-le après chaque modification de
#  /etc/pi-data-server/data-server.conf
# =============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "À lancer avec sudo."; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="$HERE/files"
NONINT=0
for a in "$@"; do
    case "$a" in
        --non-interactive) NONINT=1 ;;
        *) echo "option inconnue : $a"; exit 2 ;;
    esac
done
[[ -t 0 ]] || NONINT=1
export DEBIAN_FRONTEND=noninteractive
# --no-install-recommends : seulement les dépendances strictes (carte SD de petite
# taille ; les « recommandés » tirent des centaines de Mo inutiles ici).
APT=(apt-get -o DPkg::Lock::Timeout=900 -o APT::Install-Recommends=false -y)
# apt_run ARGS… : apt-get qui patiente si apt est déjà occupé (mises à jour
# automatiques, autre installation). DPkg::Lock::Timeout ne couvre que le verrou
# de dpkg, pas ceux du cache et des listes : on réessaie tant qu'un autre apt tourne.
# apt_busy : vrai si un autre programme tient un verrou d'apt/dpkg. On teste les
# verrous eux-mêmes (fcntl, comme apt), pas les noms de processus : le démon de
# veille d'unattended-upgrades tourne en permanence et ne doit pas compter.
apt_busy() {
    python3 - <<'PY'
import fcntl, os, sys
for f in ("/var/lib/dpkg/lock-frontend", "/var/lib/dpkg/lock",
          "/var/cache/apt/archives/lock", "/var/lib/apt/lists/lock"):
    try:
        fd = os.open(f, os.O_RDWR)
    except OSError:
        continue
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.lockf(fd, fcntl.LOCK_UN)
    except OSError:
        sys.exit(0)          # verrou tenu par un autre programme
    finally:
        os.close(fd)
sys.exit(1)
PY
}
apt_run() {
    local _ waited=0
    for _ in $(seq 1 120); do
        while apt_busy; do
            if [[ $waited -eq 0 ]]; then
                echo "   apt est occupé par un autre programme : attente (voir : sudo journalctl -fu apt-daily -u apt-daily-upgrade)"
                waited=1
            fi
            sleep 5
        done
        "${APT[@]}" "$@" && return 0
        apt_busy || return 1      # échec réel (paquet introuvable…) : on s'arrête
        sleep 5
    done
    return 1
}
log()  { printf '\n\033[1;32m[pi-data-server]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

CONF_DIR=/etc/pi-data-server
mkdir -p "$CONF_DIR"
[[ -f "$CONF_DIR/data-server.conf" ]] || install -m 644 "$HERE/data-server.conf" "$CONF_DIR/data-server.conf"
# shellcheck source=data-server.conf
. "$CONF_DIR/data-server.conf"

log "Paquets"
apt_run update
apt_run install lighttpd vsftpd ntfs-3g exfatprogs openssl python3 util-linux
if [[ "${FAIL2BAN:-yes}" == "yes" ]]; then apt_run install fail2ban python3-systemd; fi

# ---------------------------------------------------------------------------
log "Automontage lecture seule (/media en tmpfs + udev + systemd)"
install -m 755 "$F/bin/media-automount"        /usr/local/sbin/media-automount
install -m 644 "$F/media.mount"                /etc/systemd/system/media.mount
install -m 644 "$F/media-automount@.service"   /etc/systemd/system/media-automount@.service
install -m 644 "$F/90-media-automount.rules"   /etc/udev/rules.d/90-media-automount.rules
mkdir -p /etc/media-automount/hooks.d
# Pas d'automonteur concurrent
systemctl mask --now udisks2.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now media.mount
udevadm control --reload
udevadm trigger --subsystem-match=block --action=add

# ---------------------------------------------------------------------------
log "Dossier /incoming"
if [[ "${FTP_USER:-auto}" == auto ]]; then
    # Compte administrateur créé par prepare.sh (premier compte « humain »)
    FTP_USER="$(getent passwd 1000 | cut -d: -f1)"
    FTP_USER="${FTP_USER:-ftpuser}"
fi
if ! id -u "$FTP_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/var/lib/$FTP_USER" --shell /usr/sbin/nologin "$FTP_USER"
fi
# /incoming appartient au compte FTP ; groupe commun pour partager avec d'autres comptes
mkdir -p "$INCOMING_DIR"
chown "$FTP_USER:$FTP_USER" "$INCOMING_DIR"
chmod 2775 "$INCOMING_DIR"

# ---------------------------------------------------------------------------
log "Arborescence FTP $FTP_ROOT"
mkdir -p "$FTP_ROOT/incoming" "$FTP_ROOT/media"
chown root:root "$FTP_ROOT"; chmod 755 "$FTP_ROOT"

unit_in="$(systemd-escape -p --suffix=mount "$FTP_ROOT/incoming")"
unit_me="$(systemd-escape -p --suffix=mount "$FTP_ROOT/media")"
cat > "/etc/systemd/system/$unit_in" <<EOF
[Unit]
Description=Vue FTP de $INCOMING_DIR (lecture/écriture)
RequiresMountsFor=$INCOMING_DIR

[Mount]
What=$INCOMING_DIR
Where=$FTP_ROOT/incoming
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF
cat > "/etc/systemd/system/$unit_me" <<EOF
[Unit]
Description=Vue FTP de /media (lecture seule, suit les branchements à chaud)
Requires=media.mount
After=media.mount

[Mount]
What=/media
Where=$FTP_ROOT/media
Type=none
# rbind + propagation partagée : chaque disque monté/démonté dans /media
# apparaît/disparaît aussitôt ici.
Options=rbind,ro

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$unit_in" "$unit_me"

# ---------------------------------------------------------------------------
log "Serveur HTTP lecture seule sur le port $HTTP_PORT (lighttpd)"
# Le service lighttpd par défaut (port 80, /var/www) n'est pas utilisé
systemctl disable --now lighttpd.service 2>/dev/null || true
sed "s/@HTTP_PORT@/$HTTP_PORT/g" "$F/lighttpd-media.conf.in" > "$CONF_DIR/lighttpd-media.conf"
lighttpd -tt -f "$CONF_DIR/lighttpd-media.conf"
cat > /etc/systemd/system/media-http.service <<UNIT
[Unit]
Description=Mini serveur HTTP lecture seule de /media (lighttpd)
After=network-online.target media.mount
Wants=network-online.target
Requires=media.mount

[Service]
ExecStart=/usr/sbin/lighttpd -D -f $CONF_DIR/lighttpd-media.conf
Restart=always
RestartSec=2
# Aucun privilège : utilisateur www-data, port > 1024
User=www-data
Group=www-data
NoNewPrivileges=yes
CapabilityBoundingSet=
# Durcissement : le service ne peut rien écrire nulle part
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=yes
MemoryDenyWriteExecute=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable media-http.service
systemctl restart media-http.service

# ---------------------------------------------------------------------------
log "Serveur FTP (vsftpd)"
echo "$FTP_USER" > /etc/vsftpd.userlist
# PAM : comme Debian, mais sans exiger un shell valide (le compte n'a pas de shell)
[[ -f /etc/pam.d/vsftpd.orig ]] || cp /etc/pam.d/vsftpd /etc/pam.d/vsftpd.orig
cat > /etc/pam.d/vsftpd <<'EOF'
# pi-data-server : identique à Debian sans pam_shells (compte FTP sans shell)
auth    required        pam_listfile.so item=user sense=deny file=/etc/ftpusers onerr=succeed
@include common-auth
@include common-account
@include common-session
EOF

if [[ "${FTP_TLS:-yes}" == "yes" ]]; then
    mkdir -p /etc/ssl/pi-data-server
    if [[ ! -f /etc/ssl/pi-data-server/vsftpd.pem ]]; then
        openssl req -x509 -nodes -newkey rsa:3072 -days 3650 \
            -subj "/CN=$(hostname -f 2>/dev/null || hostname)" \
            -keyout /etc/ssl/pi-data-server/vsftpd.key -out /etc/ssl/pi-data-server/vsftpd.pem
        chmod 600 /etc/ssl/pi-data-server/vsftpd.key
    fi
fi
export SSL_CERT=/etc/ssl/pi-data-server/vsftpd.pem SSL_KEY=/etc/ssl/pi-data-server/vsftpd.key
# shellcheck source=files/vsftpd-render.sh
. "$F/vsftpd-render.sh"
render_vsftpd "$F/vsftpd.conf.in" /etc/vsftpd.conf
# vsftpd ne dit rien dans le journal s'il refuse sa configuration : on vérifie
# qu'il démarre réellement, et on affiche son message sinon.
systemctl enable vsftpd
systemctl restart vsftpd
sleep 1
if ! systemctl is-active --quiet vsftpd; then
    warn "vsftpd refuse de démarrer :"
    timeout 3 /usr/sbin/vsftpd /etc/vsftpd.conf 2>&1 | head -n 3 || true
    exit 1
fi

FTP_PW_SET=yes
if ! passwd -S "$FTP_USER" 2>/dev/null | awk '{exit ($2=="P")?0:1}'; then
    if [[ $NONINT -eq 1 ]]; then
        FTP_PW_SET=no   # le compte reste verrouillé : aucune connexion FTP possible
    else
        echo
        echo ">>> Choisissez le mot de passe FTP du compte « $FTP_USER » :"
        until passwd "$FTP_USER"; do echo "Recommencez."; done
    fi
fi

# ---------------------------------------------------------------------------
if [[ "${FAIL2BAN:-yes}" == "yes" ]]; then
    log "fail2ban (bannit 1 h après 5 échecs FTP en 10 min)"
    cat > /etc/fail2ban/jail.d/pi-data-server.local <<'EOF'
[DEFAULT]
backend   = systemd
banaction = nftables-multiport
banaction_allports = nftables-allports
bantime   = 1h
findtime  = 10m
maxretry  = 5
ignoreip  = 127.0.0.1/8 ::1

[vsftpd]
enabled = true
port    = ftp,ftp-data,ftps,ftps-data
# vsftpd écrit ses échecs (« FAIL LOGIN ») dans son propre fichier
backend = auto
logpath = /var/log/vsftpd.log
EOF
    touch /var/log/vsftpd.log
    systemctl enable fail2ban
    systemctl restart fail2ban
fi

# ---------------------------------------------------------------------------
if [[ -f /etc/nftables.d/00-lan.nft ]] && grep -q 'nftables.d/\[1-9\]' /etc/nftables.conf 2>/dev/null; then
    log "Pare-feu pi-server : HTTP $HTTP_PORT et FTP ouverts (public)"
    cat > /etc/nftables.d/10-pi-data-server.nft <<EOF
# pi-data-server — ouvert à tous (c'est la box qui décide de l'exposition)
add rule inet filter input tcp dport { $HTTP_PORT, 21, $FTP_PASV_MIN-$FTP_PASV_MAX } accept
EOF
    nft -c -f /etc/nftables.conf && systemctl restart nftables
    # fail2ban recrée sa table après un rechargement du pare-feu
    if [[ "${FAIL2BAN:-yes}" == "yes" ]]; then systemctl restart fail2ban; fi
else
    warn "Pas de pare-feu pi-server : aucun filtrage ajouté (ports $HTTP_PORT, 21, $FTP_PASV_MIN-$FTP_PASV_MAX)."
fi

apt-get clean
IP="$(hostname -I | awk '{print $1}')"
log "Serveur de données prêt"
cat <<EOF
  HTTP (lecture seule) : http://$IP:$HTTP_PORT/
  $([[ "${FTP_TLS:-yes}" == yes ]] && echo "FTPS (TLS explicite)" || echo "FTP (non chiffré)  ") : $IP port 21, utilisateur « $FTP_USER »
                         /incoming (rw)   /media (ro)
  Disques amovibles    : journalctl -fu 'media-automount@*'
EOF
if [[ "$FTP_PW_SET" == no ]]; then
    echo
    warn "Mot de passe FTP non défini : le compte « $FTP_USER » est verrouillé."
    warn "Pour l'activer, choisissez-lui un mot de passe :  sudo passwd $FTP_USER"
    warn "(ou utilisez votre propre compte : FTP_USER=auto dans $CONF_DIR/data-server.conf,"
    warn " puis sudo bash $HERE/install.sh)"
fi
