#!/usr/bin/env bash
#
# harden.sh - Outil de sécurisation rapide pour Debian/Ubuntu
#
# V1.1 :
#   - Change le mot de passe root pour un mot de passe aléatoire sécurisé
#   - Change le port SSH pour un port aléatoire
#   - Ajoute un mot de passe GRUB (protège l'édition du boot loader)
#   - Affiche les nouvelles infos UNE SEULE FOIS à l'écran (jamais stockées sur disque)
#
# Usage : sudo ./harden.sh
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Couleurs pour la lisibilité du terminal
# ----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }

# ----------------------------------------------------------------------------
# Nettoyage garanti même en cas d'interruption (Ctrl+C, erreur, etc.)
# ----------------------------------------------------------------------------
NEW_ROOT_PASSWORD=""
NEW_SSH_PORT=""
NEW_GRUB_PASSWORD=""

cleanup() {
    # On efface les variables sensibles de la mémoire du shell
    NEW_ROOT_PASSWORD=""
    NEW_SSH_PORT=""
    NEW_GRUB_PASSWORD=""
    unset NEW_ROOT_PASSWORD NEW_SSH_PORT NEW_GRUB_PASSWORD
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# 1. Vérifications préalables
# ----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en root (utilise : sudo ./harden.sh)"
    exit 1
fi

SSHD_CONFIG="/etc/ssh/sshd_config"

if [[ ! -f "$SSHD_CONFIG" ]]; then
    error "Fichier $SSHD_CONFIG introuvable. OpenSSH est-il installé ?"
    exit 1
fi

echo -e "${BOLD}=== Outil de sécurisation Linux - V1.1 ===${NC}"
echo "Ce script va :"
echo "  1. Sauvegarder ta configuration SSH et GRUB actuelles"
echo "  2. Générer un nouveau mot de passe root aléatoire"
echo "  3. Générer un nouveau port SSH aléatoire"
echo "  4. Générer un mot de passe GRUB aléatoire"
echo "  5. Appliquer les changements et redémarrer SSH"
echo "  6. T'afficher les nouvelles infos UNE SEULE FOIS"
echo ""
read -rp "Continuer ? (o/N) : " CONFIRM
if [[ ! "$CONFIRM" =~ ^[oOyY]$ ]]; then
    warn "Annulé par l'utilisateur."
    exit 0
fi

# ----------------------------------------------------------------------------
# 2. Sauvegarde de la configuration SSH
# ----------------------------------------------------------------------------
BACKUP_FILE="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SSHD_CONFIG" "$BACKUP_FILE"
info "Sauvegarde créée : $BACKUP_FILE"

# ----------------------------------------------------------------------------
# 3. Génération du nouveau mot de passe root (aléatoire et sécurisé)
# ----------------------------------------------------------------------------
info "Génération du nouveau mot de passe root..."
# 24 octets aléatoires encodés en base64 -> mot de passe fort et lisible
NEW_ROOT_PASSWORD=$(openssl rand -base64 24)

echo "root:${NEW_ROOT_PASSWORD}" | chpasswd
info "Mot de passe root changé avec succès."

# ----------------------------------------------------------------------------
# 4. Génération du nouveau port SSH (aléatoire, hors ports réservés)
# ----------------------------------------------------------------------------
info "Génération du nouveau port SSH..."

generate_random_port() {
    # Ports entre 1025 et 65535, on évite les ports "bien connus" < 1024
    local port
    local raw
    while true; do
        raw=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
        port=$(( (raw % 64510) + 1025 ))
        # Vérifie que le port n'est pas déjà utilisé
        if ! ss -tuln | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}

NEW_SSH_PORT=$(generate_random_port)
info "Nouveau port SSH sélectionné : $NEW_SSH_PORT"

# ----------------------------------------------------------------------------
# 5. Génération et application du mot de passe GRUB
# ----------------------------------------------------------------------------
GRUB_CUSTOM_FILE="/etc/grub.d/40_custom"
GRUB_SKIPPED=0

if ! command -v grub-mkpasswd-pbkdf2 &> /dev/null; then
    warn "grub-mkpasswd-pbkdf2 introuvable (paquet grub-common/grub-pc manquant)."
    warn "Le mot de passe GRUB sera ignoré pour cette exécution."
    GRUB_SKIPPED=1
elif [[ ! -f "$GRUB_CUSTOM_FILE" ]]; then
    warn "Fichier $GRUB_CUSTOM_FILE introuvable. Le mot de passe GRUB sera ignoré."
    GRUB_SKIPPED=1
else
    info "Génération du mot de passe GRUB..."
    NEW_GRUB_PASSWORD=$(openssl rand -base64 18)

    # Sauvegarde du fichier grub avant modification
    GRUB_BACKUP_FILE="${GRUB_CUSTOM_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$GRUB_CUSTOM_FILE" "$GRUB_BACKUP_FILE"
    info "Sauvegarde GRUB créée : $GRUB_BACKUP_FILE"

    # Hashage du mot de passe (jamais stocké en clair)
    GRUB_HASH=$(printf '%s\n%s\n' "$NEW_GRUB_PASSWORD" "$NEW_GRUB_PASSWORD" \
        | grub-mkpasswd-pbkdf2 \
        | grep -oE 'grub\.pbkdf2\.sha512\.[0-9]+\.[A-F0-9]+\.[A-F0-9]+')

    if [[ -z "$GRUB_HASH" ]]; then
        error "Échec de la génération du hash GRUB. Le mot de passe GRUB est ignoré."
        GRUB_SKIPPED=1
        NEW_GRUB_PASSWORD=""
    else
        # On retire un éventuel ancien bloc ajouté par ce script, puis on ajoute le nouveau
        sed -i '/# --- harden.sh GRUB password START ---/,/# --- harden.sh GRUB password END ---/d' "$GRUB_CUSTOM_FILE"
        {
            echo ""
            echo "# --- harden.sh GRUB password START ---"
            echo "set superusers=\"root\""
            echo "password_pbkdf2 root ${GRUB_HASH}"
            echo "# --- harden.sh GRUB password END ---"
        } >> "$GRUB_CUSTOM_FILE"
        info "Mot de passe GRUB configuré dans $GRUB_CUSTOM_FILE."
    fi
fi

# ----------------------------------------------------------------------------
# 6. Application des changements dans sshd_config
# ----------------------------------------------------------------------------
info "Application des changements dans la configuration SSH..."

if grep -qE '^#?Port ' "$SSHD_CONFIG"; then
    sed -i -E "s/^#?Port .*/Port ${NEW_SSH_PORT}/" "$SSHD_CONFIG"
else
    echo "Port ${NEW_SSH_PORT}" >> "$SSHD_CONFIG"
fi

# ----------------------------------------------------------------------------
# 7. Test de la configuration AVANT de redémarrer le service
# ----------------------------------------------------------------------------
info "Vérification de la validité de la configuration SSH..."
if ! sshd -t; then
    error "La configuration SSH générée est invalide ! Restauration de la sauvegarde..."
    cp "$BACKUP_FILE" "$SSHD_CONFIG"
    error "Configuration restaurée. Le mot de passe root a bien été changé, mais le port SSH n'a PAS été modifié."
    exit 1
fi
info "Configuration valide."

# ----------------------------------------------------------------------------
# 8. Redémarrage du service SSH
# ----------------------------------------------------------------------------
info "Redémarrage du service SSH..."
if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
    info "Service SSH redémarré avec succès."
else
    error "Échec du redémarrage du service SSH. Restauration de la sauvegarde..."
    cp "$BACKUP_FILE" "$SSHD_CONFIG"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    exit 1
fi

# ----------------------------------------------------------------------------
# 9. Mise à jour de la configuration GRUB (si applicable)
# ----------------------------------------------------------------------------
if [[ "$GRUB_SKIPPED" -eq 0 ]]; then
    info "Mise à jour de la configuration GRUB (update-grub)..."
    if command -v update-grub &> /dev/null; then
        if ! update-grub; then
            error "Échec de update-grub. Restauration de la sauvegarde GRUB..."
            cp "$GRUB_BACKUP_FILE" "$GRUB_CUSTOM_FILE"
            update-grub || true
            warn "Configuration GRUB restaurée. Le mot de passe GRUB n'a PAS été appliqué."
            GRUB_SKIPPED=1
            NEW_GRUB_PASSWORD=""
        else
            info "Configuration GRUB mise à jour avec succès."
        fi
    else
        warn "Commande update-grub introuvable, mise à jour manuelle nécessaire :"
        warn "  update-grub  (Debian/Ubuntu)  ou  grub2-mkconfig -o /boot/grub2/grub.cfg"
    fi
fi

# ----------------------------------------------------------------------------
# 10. Affichage UNIQUE des informations sensibles
# ----------------------------------------------------------------------------
clear
echo -e "${BOLD}${RED}=== INFORMATIONS SENSIBLES - À NOTER MAINTENANT ===${NC}"
echo ""
echo -e "  ${BOLD}Nouveau port SSH      :${NC} ${NEW_SSH_PORT}"
echo -e "  ${BOLD}Nouveau mdp root      :${NC} ${NEW_ROOT_PASSWORD}"
if [[ "$GRUB_SKIPPED" -eq 0 && -n "$NEW_GRUB_PASSWORD" ]]; then
    echo -e "  ${BOLD}Nouveau mdp GRUB      :${NC} ${NEW_GRUB_PASSWORD} ${YELLOW}(user: root)${NC}"
fi
echo ""
echo -e "${YELLOW}Ces informations ne seront affichées qu'une seule fois et ne sont"
echo -e "stockées nulle part sur le disque.${NC}"
echo ""
echo -e "Pour te reconnecter : ${BOLD}ssh -p ${NEW_SSH_PORT} root@<ip_de_la_machine>${NC}"
if [[ "$GRUB_SKIPPED" -eq 1 ]]; then
    echo ""
    warn "Le mot de passe GRUB n'a pas pu être configuré sur cette machine (voir logs ci-dessus)."
fi
echo ""
warn "IMPORTANT : teste la connexion SSH sur le nouveau port AVANT de fermer"
warn "cette session, pour être sûr de ne pas te retrouver bloqué dehors."
echo ""
read -rp "Appuie sur [Entrée] une fois les informations notées pour les effacer de l'écran..."

# On efface l'écran pour ne pas laisser les secrets affichés
clear
info "Informations effacées. Sécurisation terminée."
info "Sauvegarde de l'ancienne config conservée dans : $BACKUP_FILE"

exit 0
