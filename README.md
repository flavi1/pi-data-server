# pi-data-server

[![CI](https://github.com/flavi1/pi-data-server/actions/workflows/ci.yml/badge.svg)](https://github.com/flavi1/pi-data-server/actions/workflows/ci.yml)

Serveur de données pour Raspberry Pi 4 / 5 sans bureau graphique.

Module autonome : il s'installe seul sur Raspberry Pi OS Lite, ou via
[pi-server](https://github.com/flavi1/pi-server) qui ajoute le socle (mises à jour
automatiques, pare-feu, SSH) et la mise à jour par `sudo pi-server update`.

Public : HTTP lecture seule de `/media`, FTP privé (mot de passe + TLS) avec `/incoming`
en lecture/écriture et `/media` en lecture seule. Tous les disques amovibles sont montés
automatiquement dans `/media`, en **lecture seule absolue**, et peuvent être arrachés à
tout moment.

```
 clé / SSD USB ──udev──► media-automount@sdX1.service ──► /media/<ÉTIQUETTE>  (ro)
                                                            │
                     ┌──────────────────────────────────────┼─────────────────────┐
                     ▼                                      ▼                     ▼
            lighttpd  :8080 (public, ro)      vsftpd (FTPS, chroot /srv/ftp)   tout autre lecteur
                                              /incoming  -> /incoming (rw)
                                              /media     -> /media    (ro)
```

## 1. Installation

Avec pi-server : choisir le module `data` dans `prepare.sh`, ou plus tard
`sudo pi-server add data`.

Seul :

```bash
sudo apt install -y git
sudo git clone https://github.com/flavi1/pi-data-server /opt/pi-data-server
sudo bash /opt/pi-data-server/install.sh
```

### Compte FTP

Par défaut (`FTP_USER=auto`), le FTP utilise **votre compte administrateur**, celui
créé par `prepare.sh` : même identifiant, même mot de passe qu'en SSH. Rien à faire.

Pour un compte FTP séparé, sans accès SSH ni shell, avec son propre mot de passe :

```bash
sudo nano /etc/pi-data-server/data-server.conf     # FTP_USER=ftpuser
sudo bash /opt/pi-data-server/install.sh           # crée le compte et demande son mot de passe
```

Si le compte est créé pendant l'installation automatique, il reste **verrouillé**
(aucune connexion possible) tant qu'il n'a pas de mot de passe. Pour l'activer :

```bash
sudo passwd ftpuser
```

> Exposer votre compte administrateur sur un FTP ouvert à Internet signifie que son
> mot de passe circule (chiffré, en FTPS) et peut être attaqué par force brute
> (fail2ban limite à 5 essais / 10 min). SSH reste fermé depuis l'extérieur par le
> pare-feu. Avec un mot de passe solide c'est raisonnable ; sinon préférez un compte
> dédié.

Le script est relançable après toute modification de
`/etc/pi-data-server/data-server.conf` (ports, utilisateur, adresse passive, TLS…),
qui n'est jamais écrasé.

Mise à jour manuelle : `sudo pi-server update pi-data-server`, ou sans pi-server :
`sudo git -C /opt/pi-data-server pull && sudo bash /opt/pi-data-server/install.sh`.

Pare-feu : si le pare-feu pi-server est présent, le module y ajoute ses ports
(`/etc/nftables.d/10-pi-data-server.nft`). Sinon il n'ajoute aucun filtrage et le
signale.

## 2. Automontage lecture seule

### Ce qui se passe au branchement

1. udev voit un nouveau système de fichiers (`ID_FS_USAGE=filesystem`) et demande à
   systemd `media-automount@sdX1.service` (`/etc/udev/rules.d/90-media-automount.rules`).
2. Le service lance `/usr/local/sbin/media-automount add sdX1`, qui :
   - ignore la carte SD système, les disques déclarés dans `/etc/fstab`, les volumes
     LUKS/RAID/LVM/swap ;
   - passe le **périphérique bloc en lecture seule** (`blockdev --setro`) : le noyau
     refuse alors tout montage en écriture ;
   - monte avec des options qui **interdisent le rejeu du journal** :

     | Système | Options |
     |---|---|
     | ext4 / ext3 | `ro,noload` |
     | xfs | `ro,norecovery` |
     | btrfs | `ro,rescue=nologreplay` |
     | f2fs | `ro,norecovery` |
     | NTFS | pilote noyau `ntfs3`, sinon `ntfs-3g`, `ro` |
     | exFAT, FAT, HFS+, ISO, UDF | `ro` |

     plus `noatime,nodev,nosuid,noexec` partout (aucune date d'accès écrite) ;
   - vérifie que le montage obtenu est bien `ro`, sinon il démonte aussitôt.
3. Point de montage : `/media/<étiquette du volume>`, sinon `/media/<type>-<uuid>`.
   `/media` est un **tmpfs** : les dossiers ne sont jamais écrits sur la carte SD.

### Au débranchement

`BindsTo=dev-sdX1.device` : systemd arrête le service dès que le périphérique disparaît,
ce qui exécute `umount -l` (démontage paresseux) et supprime le dossier. Comme rien n'a
jamais été écrit, **il n'y a rien à vider ni à corrompre** : on peut débrancher à tout
moment, même pendant une lecture (le client en cours reçoit simplement une erreur
d'entrée/sortie).

> Un disque « sale » (débranché d'un PC sans éjection, Windows en veille prolongée)
> est monté dans l'état de sa dernière écriture validée : les dernières modifications
> non journalisées peuvent ne pas apparaître, mais le disque n'est **pas** modifié.

### Vérifier

```bash
journalctl -fu 'media-automount@*'          # suivre les branchements
findmnt -R /media                           # disques montés (colonne OPTIONS : ro)
cat /sys/block/sda/sda1/ro                  # 1 = verrou noyau actif
```

### Hooks

Les exécutables de `/etc/media-automount/hooks.d/` sont appelés après chaque montage
/ démontage (`add|remove <dossier> <périphérique>`). Point d'extension facultatif :
aucun autre module n'en dépend (pi-sound-server surveille `/media` lui-même).

## 3. HTTP lecture seule (lighttpd)

- Service `media-http.service`, port `HTTP_PORT` (8080 par défaut) : `http://hifi.local:8080/`.
- Instance **dédiée** de lighttpd (`/etc/pi-data-server/lighttpd-media.conf`, générée) :
  uniquement les modules de fichiers statiques et de listing des dossiers, aucun module
  d'écriture (ni WebDAV, ni CGI, ni upload). Les `.html` des disques sont servis en
  texte brut : rien d'actif ne s'exécute depuis une clé branchée.
- Tourne sous `www-data`, **sans aucun privilège** (port > 1024), enfermé par systemd
  (`ProtectSystem=strict`, `NoNewPrivileges`, aucune capacité…). Le service lighttpd
  par défaut de Debian (port 80) est désactivé.
- Les disques branchés après son démarrage apparaissent immédiatement.

Pour le publier sur Internet : redirigez un port de la box vers `8080` de la Pi. Pas de
HTTPS intégré : si besoin, mettez un reverse-proxy (Caddy) devant.

## 4. FTP (vsftpd)

| Chemin vu par le client | Réel | Droits |
|---|---|---|
| `/incoming` | `/incoming` | lecture/écriture |
| `/media` | `/media` (bind récursif) | lecture seule |

- Un seul compte autorisé (`FTP_USER`, voir « Compte FTP » plus haut) ; tous les
  autres comptes, root compris, sont refusés.
- Enfermé (chroot) dans `/srv/ftp` ; anonyme interdit.
- **FTPS explicite obligatoire** (certificat auto-signé généré dans `/etc/ssl/pi-data-server/`).
  Dans FileZilla : *Chiffrement : « Connexion FTP explicite sur TLS »*, accepter le
  certificat au premier contact.
- fail2ban bannit une IP pendant 1 h après 5 échecs en 10 min (`sudo fail2ban-client status vsftpd`).

### Accès depuis l'extérieur

Sur la box, rediriger vers l'IP de la Pi :

- TCP **21** ;
- TCP **40000 à 40100** (plage passive, `FTP_PASV_MIN/MAX`).

Puis dans `/etc/pi-data-server/data-server.conf`, renseigner `FTP_PASV_ADDRESS` avec votre IP
publique ou votre nom DNS dynamique, et relancer l'installeur. (Limite connue de FTP :
avec cette option, les clients du réseau local doivent aussi passer par l'adresse
publique, ce que la plupart des box gèrent.)

## 5. `/incoming` sur une clé dédiée (plus tard)

Aujourd'hui `/incoming` est un dossier de la carte SD. Pour le déplacer sur une clé :

```bash
sudo blkid                                      # repérer l'UUID de la clé (ext4 conseillé)
sudo nano /etc/fstab
# UUID=xxxx-xxxx  /incoming  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2
sudo systemctl daemon-reload
sudo mount /incoming
sudo chown <compte FTP>: /incoming && sudo chmod 2775 /incoming
sudo systemctl restart srv-ftp-incoming.mount vsftpd
```

Le disque déclaré dans `fstab` est automatiquement **exclu** de l'automontage lecture
seule. Attention : celui-ci est monté en écriture, il ne doit **pas** être arraché à chaud
(`sudo umount /incoming` avant de le retirer).

## 6. Dépannage

| Symptôme | Piste |
|---|---|
| Disque non monté | `journalctl -u 'media-automount@*' -b` ; type non géré ? `sudo blkid -p /dev/sdX1` |
| Nouveaux disques absents du FTP | `findmnt -o TARGET,PROPAGATION /media /srv/ftp/media` doit indiquer `shared` |
| FTP : « 530 Login incorrect » | mot de passe, `sudo fail2ban-client status vsftpd`, `/var/log/vsftpd.log` |
| FTP : liste qui ne s'affiche pas | ports passifs non redirigés, ou `FTP_PASV_ADDRESS` manquant de l'extérieur |
| HTTP ne répond pas | `systemctl status media-http`, `sudo nft list ruleset` |
