#!/usr/bin/env bash
#
# harden.sh - Outil de sécurisation rapide pour Debian/Ubuntu
#
# V1.2 :
#   - Change le mot de passe root pour un mot de passe aléatoire sécurisé
#   - Change le port SSH pour un port aléatoire
#   - Durcit les paramètres SSH communs (MaxAuthTries, forwarding, etc.)
#   - Propose au choix :
#       [1] Authentification par clé SSH (désactive le mot de passe après test)
#       [2] Conserve l'authentification par mot de passe + fail2ban
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
SSH_PUBLIC_KEY=""

cleanup() {
    NEW_ROOT_PASSWORD=""
    NEW_SSH_PORT=""
    SSH_PUBLIC_KEY=""
    unset NEW_ROOT_PASSWORD NEW_SSH_PORT SSH_PUBLIC_KEY
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# Fonction utilitaire : applique ou remplace une directive dans sshd_config
# ----------------------------------------------------------------------------
set_ssh_directive() {
    local key="$1"
    local value="$2"
    if grep -qE "^#?${key}[[:space:]]" "$SSHD_CONFIG"; then
        sed -i -E "s/^#?${key}[[:space:]].*/${key} ${value}/" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

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

echo -e "${BOLD}=== Outil de sécurisation Linux - V1.2 ===${NC}"
echo "Ce script va :"
echo "  1. Sauvegarder ta configuration SSH actuelle"
echo "  2. Générer un nouveau mot de passe root aléatoire"
echo "  3. Générer un nouveau port SSH aléatoire"
echo "  4. Durcir les paramètres SSH (MaxAuthTries, forwarding, etc.)"
echo "  5. Te proposer un choix : clé SSH OU mot de passe + fail2ban"
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

restore_backup_and_exit() {
    error "Restauration de la sauvegarde SSH..."
    cp "$BACKUP_FILE" "$SSHD_CONFIG"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    exit 1
}

# ----------------------------------------------------------------------------
# 3. Génération du nouveau mot de passe root (aléatoire et sécurisé)
# ----------------------------------------------------------------------------
info "Génération du nouveau mot de passe root..."
NEW_ROOT_PASSWORD=$(openssl rand -base64 24)
echo "root:${NEW_ROOT_PASSWORD}" | chpasswd
info "Mot de passe root changé avec succès."

# ----------------------------------------------------------------------------
# 4. Génération du nouveau port SSH (aléatoire, hors ports réservés)
# ----------------------------------------------------------------------------
info "Génération du nouveau port SSH..."

generate_random_port() {
    local port
    local raw
    while true; do
        raw=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
        port=$(( (raw % 64510) + 1025 ))
        if ! ss -tuln | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}

NEW_SSH_PORT=$(generate_random_port)
info "Nouveau port SSH sélectionné : $NEW_SSH_PORT"

# ----------------------------------------------------------------------------
# 5. Application du port + durcissement SSH commun (indépendant du choix)
# ----------------------------------------------------------------------------
info "Application du nouveau port et du durcissement SSH commun..."

set_ssh_directive "Port" "$NEW_SSH_PORT"
set_ssh_directive "MaxAuthTries" "3"
set_ssh_directive "ClientAliveCountMax" "2"
set_ssh_directive "X11Forwarding" "no"
set_ssh_directive "AllowTcpForwarding" "no"
set_ssh_directive "AllowAgentForwarding" "no"
set_ssh_directive "Compression" "no"
set_ssh_directive "TCPKeepAlive" "no"
set_ssh_directive "LogLevel" "VERBOSE"
set_ssh_directive "MaxSessions" "2"

info "Test de la configuration après durcissement commun..."
if ! sshd -t; then
    restore_backup_and_exit
fi
info "Configuration valide."

# ----------------------------------------------------------------------------
# 6. Choix du mode d'authentification
# ----------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Comment veux-tu gérer l'authentification SSH ?${NC}"
echo "  [1] Authentification par clé SSH (désactive le mot de passe après test)"
echo "  [2] Garder le mot de passe, mais ajouter fail2ban"
echo ""
read -rp "Ton choix (1/2) : " AUTH_MODE

case "$AUTH_MODE" in
    1)
        # ------------------------------------------------------------------
        # OPTION 1 : Authentification par clé SSH
        # ------------------------------------------------------------------
        echo ""
        echo "Colle ta clé publique SSH (contenu de ton fichier .pub, ex: ~/.ssh/id_ed25519.pub) :"
        read -r SSH_PUBLIC_KEY

        if [[ ! "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\ AAAA ]]; then
            error "Cette clé ne ressemble pas à une clé publique SSH valide. Abandon."
            restore_backup_and_exit
        fi

        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        touch /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys

        if grep -qF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
            info "Cette clé est déjà présente dans authorized_keys."
        else
            echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
            info "Clé publique ajoutée à /root/.ssh/authorized_keys."
        fi

        # On garde le mot de passe actif pour l'instant (fallback de sécurité)
        set_ssh_directive "PubkeyAuthentication" "yes"
        set_ssh_directive "PasswordAuthentication" "yes"

        if ! sshd -t; then
            restore_backup_and_exit
        fi

        if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
            info "SSH redémarré avec la clé activée (mot de passe encore actif en fallback)."
        else
            restore_backup_and_exit
        fi

        echo ""
        warn "=== TEST OBLIGATOIRE AVANT DE CONTINUER ==="
        warn "Ouvre un NOUVEAU terminal et teste la connexion par clé :"
        echo -e "  ${BOLD}ssh -p ${NEW_SSH_PORT} -i <chemin_vers_ta_cle_privee> root@<ip_de_la_machine>${NC}"
        echo ""
        read -rp "La connexion par clé a-t-elle fonctionné ? (o/N) : " KEY_TEST_OK

        if [[ "$KEY_TEST_OK" =~ ^[oOyY]$ ]]; then
            set_ssh_directive "PasswordAuthentication" "no"
            if ! sshd -t; then
                restore_backup_and_exit
            fi
            if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
                info "Authentification par mot de passe désactivée. Seule la clé SSH fonctionne désormais."
            else
                restore_backup_and_exit
            fi
        else
            warn "Authentification par mot de passe LAISSÉE ACTIVE par sécurité."
            warn "Relance le script une fois ta clé fonctionnelle pour désactiver le mot de passe."
        fi
        ;;

    2)
        # ------------------------------------------------------------------
        # OPTION 2 : Mot de passe conservé + fail2ban
        # ------------------------------------------------------------------
        set_ssh_directive "PasswordAuthentication" "yes"

        if ! sshd -t; then
            restore_backup_and_exit
        fi

        if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
            info "SSH redémarré avec le durcissement commun (mot de passe conservé)."
        else
            restore_backup_and_exit
        fi

        info "Installation de fail2ban..."
        if ! command -v fail2ban-client &> /dev/null; then
            apt-get update -qq && apt-get install -y fail2ban
        else
            info "fail2ban déjà installé."
        fi

        JAIL_FILE="/etc/fail2ban/jail.local"
        if [[ -f "$JAIL_FILE" ]]; then
            cp "$JAIL_FILE" "${JAIL_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        fi

        cat > "$JAIL_FILE" << EOF
[sshd]
enabled = true
port = ${NEW_SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600
EOF

        systemctl enable fail2ban &> /dev/null || true
        if systemctl restart fail2ban; then
            info "fail2ban configuré et actif sur le port ${NEW_SSH_PORT} (3 tentatives max, ban 1h)."
        else
            warn "fail2ban installé mais le redémarrage du service a échoué. Vérifie manuellement : systemctl status fail2ban"
        fi
        ;;

    *)
        error "Choix invalide. Abandon sans appliquer le mode d'authentification."
        restore_backup_and_exit
        ;;
esac

# ----------------------------------------------------------------------------
# 7. Affichage UNIQUE des informations sensibles
# ----------------------------------------------------------------------------
clear
echo -e "${BOLD}${RED}=== INFORMATIONS SENSIBLES - À NOTER MAINTENANT ===${NC}"
echo ""
echo -e "  ${BOLD}Nouveau port SSH      :${NC} ${NEW_SSH_PORT}"
echo -e "  ${BOLD}Nouveau mdp root      :${NC} ${NEW_ROOT_PASSWORD}"
echo ""
echo -e "${YELLOW}Ces informations ne seront affichées qu'une seule fois et ne sont"
echo -e "stockées nulle part sur le disque.${NC}"
echo ""
if [[ "$AUTH_MODE" == "1" ]]; then
    echo -e "Reconnexion par clé : ${BOLD}ssh -p ${NEW_SSH_PORT} -i <ta_cle_privee> root@<ip_de_la_machine>${NC}"
    echo -e "${YELLOW}Le mot de passe root reste utile comme accès de secours via la console.${NC}"
else
    echo -e "Reconnexion : ${BOLD}ssh -p ${NEW_SSH_PORT} root@<ip_de_la_machine>${NC}"
    echo -e "${YELLOW}fail2ban est actif : 3 tentatives échouées = ban d'1h sur l'IP.${NC}"
fi
echo ""
warn "IMPORTANT : teste la connexion SSH sur le nouveau port AVANT de fermer"
warn "cette session, pour être sûr de ne pas te retrouver bloqué dehors."
echo ""
read -rp "Appuie sur [Entrée] une fois les informations notées pour les effacer de l'écran..."

clear
info "Informations effacées. Sécurisation terminée."
info "Sauvegarde de l'ancienne config conservée dans : $BACKUP_FILE"

exit 0
