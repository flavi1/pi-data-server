#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Test d'intégration de media-automount sur des périphériques loop (root requis).
# Pour chaque système de fichiers disponible :
#   - montage via « media-automount add », options ro vérifiées, écriture refusée ;
#   - démontage via « media-automount remove » ;
#   - empreinte SHA-256 de l'image IDENTIQUE avant/après => lecture seule absolue.
# Usage : sudo bash tests/test-automount.sh [ext4 vfat exfat ntfs ...]
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "root requis"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AM="$HERE/files/bin/media-automount"
WORK="$(mktemp -d)"
FAILS=0 RUN=0
mkdir -p /media
cleanup() { for l in $(losetup -j "$WORK/img" -O NAME -n 2>/dev/null); do losetup -d "$l"; done; rm -rf "$WORK"; }
trap cleanup EXIT

mkfs_for() {   # mkfs_for TYPE IMAGE LABEL
    case "$1" in
        ext4)  mkfs.ext4 -q -F -L "$3" "$2" ;;
        ext2)  mkfs.ext2 -q -F -L "$3" "$2" ;;
        vfat)  mkfs.vfat -n "$3" "$2" >/dev/null ;;
        exfat) mkfs.exfat -L "$3" "$2" >/dev/null ;;
        ntfs)  mkntfs -q -F -f -L "$3" "$2" >/dev/null ;;
        xfs)   mkfs.xfs -q -f -L "$3" "$2" ;;
        btrfs) mkfs.btrfs -q -f -L "$3" "$2" ;;
        *) return 1 ;;
    esac
}
tool_for() { case "$1" in ext4|ext2) echo mkfs.ext4 ;; vfat) echo mkfs.vfat ;; exfat) echo mkfs.exfat ;;
             ntfs) echo mkntfs ;; xfs) echo mkfs.xfs ;; btrfs) echo mkfs.btrfs ;; esac; }

ok()   { echo "  ok   : $*"; }
fail() {
    echo "  FAIL : $*"; FAILS=$((FAILS+1))
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=test-automount ($CUR)::$*"
    return 0
}
skip() {
    echo "  ignoré : $*"
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::warning title=test-automount ($CUR)::ignoré : $*"
    return 0
}
CUR=""

TYPES=("$@"); [[ ${#TYPES[@]} -gt 0 ]] || TYPES=(ext4 ext2 vfat exfat ntfs xfs btrfs)
for t in "${TYPES[@]}"; do
    CUR="$t"
    command -v "$(tool_for "$t")" >/dev/null 2>&1 || { skip "$t : outil de formatage absent"; continue; }
    echo "== $t"
    img="$WORK/img"; rm -f "$img"; truncate -s 300M "$img"
    label="TEST$t"; [[ "$t" == ext4 ]] && label="Ma Clé"
    mkfs_for "$t" "$img" "$label" || { skip "$t : formatage impossible"; continue; }
    # quelques fichiers (montage en écriture, hors media-automount)
    L="$(losetup -f --show "$img")"
    mkdir -p "$WORK/m"
    if ! mount "$L" "$WORK/m" 2>"$WORK/err"; then
        skip "$t : non montable sur cette machine ($(tr '\n' ' ' < "$WORK/err"))"
        losetup -d "$L"; continue
    fi
    echo bonjour > "$WORK/m/fichier.txt"; mkdir -p "$WORK/m/Album"; umount "$WORK/m"
    losetup -d "$L"
    RUN=$((RUN+1))
    before="$(sha256sum "$img" | cut -d' ' -f1)"

    L="$(losetup -f --show "$img")"; k="$(basename "$L")"
    bash "$AM" add "$k" 2>&1 | tee "$WORK/am.log"
    dir="$(cat "/run/media-automount/$k" 2>/dev/null || true)"
    if [[ -z "$dir" ]] || ! mountpoint -q "$dir"; then
        fail "$t non monté par media-automount : $(tr '\n' ' ' < "$WORK/am.log")"; losetup -d "$L"; continue
    fi
    ok "monté sur $dir"
    [[ "$t" == ext4 && "$dir" != "/media/Ma Clé" ]] && fail "nom de dossier inattendu : $dir"
    opts="$(findmnt -rn -o OPTIONS --target "$dir")"
    grep -qE '(^|,)ro(,|$)' <<<"$opts" && ok "options : $opts" || fail "pas en ro : $opts"
    [[ "$(blockdev --getro "$L")" == 1 ]] && ok "verrou noyau (blockdev ro)" || fail "blockdev pas en ro"
    [[ "$(cat "$dir/fichier.txt")" == bonjour ]] && ok "lecture" || fail "lecture"
    if touch "$dir/ecriture" 2>/dev/null; then fail "écriture ACCEPTÉE"; else ok "écriture refusée"; fi
    bash "$AM" add "$k" | grep -q "déjà géré" && ok "second « add » ignoré" || fail "second add"
    bash "$AM" remove "$k"
    mountpoint -q "$dir" 2>/dev/null && fail "toujours monté" || ok "démonté"
    [[ -e "$dir" ]] && fail "dossier $dir non supprimé" || ok "dossier supprimé"
    blockdev --setrw "$L"; losetup -d "$L"
    after="$(sha256sum "$img" | cut -d' ' -f1)"
    [[ "$before" == "$after" ]] && ok "image intacte (SHA-256 identique)" || fail "IMAGE MODIFIÉE"
done

echo
echo "$RUN système(s) testé(s), $FAILS échec(s)"
[[ $RUN -gt 0 && $FAILS -eq 0 ]]
