#!/usr/bin/env bash
#
# harden.sh - Outil de sécurisation rapide pour Debian/Ubuntu
#
# V1.4 :
#   - Mode simple (automatique) ou mode avancé (tu choisis les valeurs)
#   - Change le mot de passe root (aléatoire ou personnalisé)
#   - Change le port SSH (aléatoire ou personnalisé)
#   - Durcit les paramètres SSH communs (personnalisables en mode avancé)
#   - Propose au choix :
#       [1] Authentification par clé SSH (désactive le mot de passe après test)
#       [2] Conserve l'authentification par mot de passe
#   - Installe et configure fail2ban (paramètres personnalisables en mode avancé)
#   - Sauvegarde l'état d'origine (une seule fois) pour permettre un rollback via unharden.sh
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

# Demande une valeur à l'utilisateur, avec une valeur par défaut si Entrée seule
prompt_with_default() {
    local prompt_text="$1"
    local default_value="$2"
    local input
    read -rp "${prompt_text} [${default_value}] : " input
    echo "${input:-$default_value}"
}

# ----------------------------------------------------------------------------
# Nettoyage garanti même en cas d'interruption (Ctrl+C, erreur, etc.)
# ----------------------------------------------------------------------------
NEW_ROOT_PASSWORD=""
NEW_SSH_PORT=""
SSH_PUBLIC_KEY=""
CUSTOM_PASSWORD=""

cleanup() {
    NEW_ROOT_PASSWORD=""
    NEW_SSH_PORT=""
    SSH_PUBLIC_KEY=""
    CUSTOM_PASSWORD=""
    unset NEW_ROOT_PASSWORD NEW_SSH_PORT SSH_PUBLIC_KEY CUSTOM_PASSWORD
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

# ----------------------------------------------------------------------------
# Sauvegarde de l'état d'ORIGINE (une seule fois, sert à unharden.sh)
# ----------------------------------------------------------------------------
STATE_DIR="/var/lib/harden-sh"

init_pristine_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    if [[ -f "$STATE_DIR/.initialized" ]]; then
        return
    fi

    info "Première exécution détectée : sauvegarde de l'état d'origine (pour unharden.sh)..."

    cp "$SSHD_CONFIG" "$STATE_DIR/sshd_config.orig"

    if [[ -f /root/.ssh/authorized_keys ]]; then
        cp /root/.ssh/authorized_keys "$STATE_DIR/authorized_keys.orig"
    else
        touch "$STATE_DIR/authorized_keys.absent"
    fi

    if command -v fail2ban-client &> /dev/null; then
        touch "$STATE_DIR/fail2ban.preexisting"
        if [[ -f /etc/fail2ban/jail.local ]]; then
            cp /etc/fail2ban/jail.local "$STATE_DIR/jail.local.orig"
        else
            touch "$STATE_DIR/jail.local.absent"
        fi
    else
        touch "$STATE_DIR/fail2ban.installed_by_script"
    fi

    touch "$STATE_DIR/.initialized"
    info "État d'origine sauvegardé dans $STATE_DIR."
}

init_pristine_state

echo -e "${BOLD}=== Outil de sécurisation Linux - V1.4 ===${NC}"
echo "Ce script va :"
echo "  1. Sauvegarder ta configuration SSH actuelle"
echo "  2. Générer/définir un mot de passe root"
echo "  3. Générer/définir un port SSH"
echo "  4. Durcir les paramètres SSH (MaxAuthTries, forwarding, etc.)"
echo "  5. Te proposer un choix : clé SSH OU mot de passe"
echo "  6. Installer et configurer fail2ban"
echo "  7. T'afficher les nouvelles infos UNE SEULE FOIS"
echo ""
read -rp "Continuer ? (o/N) : " CONFIRM
if [[ ! "$CONFIRM" =~ ^[oOyY]$ ]]; then
    warn "Annulé par l'utilisateur."
    exit 0
fi

# ----------------------------------------------------------------------------
# 1.5. Choix du mode : simple (automatique) ou avancé (personnalisé)
# ----------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Quel mode veux-tu utiliser ?${NC}"
echo "  [1] Simple  : tout est généré automatiquement (recommandé si tu débutes)"
echo "  [2] Avancé  : tu choisis toi-même le port, le mot de passe, et les réglages"
echo "               fins (utilisateurs à l'aise avec SSH/Linux)"
echo ""
SCRIPT_MODE=$(prompt_with_default "Ton choix (1/2)" "1")

# Valeurs par défaut (utilisées telles quelles en mode simple, ou comme
# suggestions modifiables en mode avancé)
DEFAULT_MAX_AUTH_TRIES="3"
DEFAULT_CLIENT_ALIVE_COUNT_MAX="2"
DEFAULT_MAX_SESSIONS="2"
DEFAULT_F2B_MAXRETRY="3"
DEFAULT_F2B_FINDTIME="600"
DEFAULT_F2B_BANTIME="3600"

MAX_AUTH_TRIES="$DEFAULT_MAX_AUTH_TRIES"
CLIENT_ALIVE_COUNT_MAX="$DEFAULT_CLIENT_ALIVE_COUNT_MAX"
MAX_SESSIONS="$DEFAULT_MAX_SESSIONS"
F2B_MAXRETRY="$DEFAULT_F2B_MAXRETRY"
F2B_FINDTIME="$DEFAULT_F2B_FINDTIME"
F2B_BANTIME="$DEFAULT_F2B_BANTIME"

if [[ "$SCRIPT_MODE" == "2" ]]; then
    echo ""
    info "Mode avancé activé. Appuie sur Entrée à chaque question pour garder la valeur par défaut."
fi

# ----------------------------------------------------------------------------
# 2. Sauvegarde de la configuration SSH (backup de cette exécution)
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
# 3. Mot de passe root (aléatoire, ou personnalisé en mode avancé)
# ----------------------------------------------------------------------------
if [[ "$SCRIPT_MODE" == "2" ]]; then
    echo ""
    echo "Mot de passe root :"
    echo "  [1] Générer un mot de passe aléatoire sécurisé (recommandé)"
    echo "  [2] Définir mon propre mot de passe"
    PW_CHOICE=$(prompt_with_default "Ton choix (1/2)" "1")

    if [[ "$PW_CHOICE" == "2" ]]; then
        while true; do
            read -rsp "Nouveau mot de passe root : " CUSTOM_PASSWORD
            echo ""
            read -rsp "Confirme le mot de passe : " CUSTOM_PASSWORD_CONFIRM
            echo ""

            if [[ "$CUSTOM_PASSWORD" != "$CUSTOM_PASSWORD_CONFIRM" ]]; then
                error "Les deux mots de passe ne correspondent pas. Réessaie."
                continue
            fi

            if [[ ${#CUSTOM_PASSWORD} -lt 8 ]]; then
                warn "Ce mot de passe fait moins de 8 caractères, c'est risqué."
                read -rp "Continuer quand même avec ce mot de passe ? (o/N) : " WEAK_CONFIRM
                if [[ ! "$WEAK_CONFIRM" =~ ^[oOyY]$ ]]; then
                    continue
                fi
            fi

            NEW_ROOT_PASSWORD="$CUSTOM_PASSWORD"
            break
        done
    else
        NEW_ROOT_PASSWORD=$(openssl rand -base64 24)
    fi
else
    info "Génération du nouveau mot de passe root..."
    NEW_ROOT_PASSWORD=$(openssl rand -base64 24)
fi

echo "root:${NEW_ROOT_PASSWORD}" | chpasswd
info "Mot de passe root changé avec succès."

# ----------------------------------------------------------------------------
# 4. Port SSH (aléatoire, ou personnalisé en mode avancé)
# ----------------------------------------------------------------------------
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

if [[ "$SCRIPT_MODE" == "2" ]]; then
    echo ""
    echo "Port SSH :"
    echo "  [1] Générer un port aléatoire (recommandé)"
    echo "  [2] Choisir mon propre port"
    PORT_CHOICE=$(prompt_with_default "Ton choix (1/2)" "1")

    if [[ "$PORT_CHOICE" == "2" ]]; then
        while true; do
            read -rp "Port SSH souhaité (1-65535) : " CUSTOM_PORT

            if ! [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] || (( CUSTOM_PORT < 1 || CUSTOM_PORT > 65535 )); then
                error "Port invalide. Choisis un nombre entre 1 et 65535."
                continue
            fi

            if (( CUSTOM_PORT < 1024 )); then
                warn "Ce port est un port privilégié (<1024), généralement déconseillé pour SSH."
                read -rp "Continuer quand même avec ce port ? (o/N) : " PRIV_CONFIRM
                if [[ ! "$PRIV_CONFIRM" =~ ^[oOyY]$ ]]; then
                    continue
                fi
            fi

            if ss -tuln | grep -q ":${CUSTOM_PORT} "; then
                error "Ce port semble déjà utilisé par un autre service. Choisis-en un autre."
                continue
            fi

            NEW_SSH_PORT="$CUSTOM_PORT"
            break
        done
    else
        NEW_SSH_PORT=$(generate_random_port)
    fi
else
    info "Génération du nouveau port SSH..."
    NEW_SSH_PORT=$(generate_random_port)
fi

info "Port SSH sélectionné : $NEW_SSH_PORT"

# ----------------------------------------------------------------------------
# 5. Paramètres de durcissement SSH (valeurs par défaut, ajustables en avancé)
# ----------------------------------------------------------------------------
if [[ "$SCRIPT_MODE" == "2" ]]; then
    echo ""
    echo "Paramètres de durcissement SSH (Entrée = valeur par défaut) :"
    MAX_AUTH_TRIES=$(prompt_with_default "  Nombre max de tentatives de connexion (MaxAuthTries)" "$DEFAULT_MAX_AUTH_TRIES")
    CLIENT_ALIVE_COUNT_MAX=$(prompt_with_default "  ClientAliveCountMax" "$DEFAULT_CLIENT_ALIVE_COUNT_MAX")
    MAX_SESSIONS=$(prompt_with_default "  Sessions SSH simultanées max (MaxSessions)" "$DEFAULT_MAX_SESSIONS")
fi

# ----------------------------------------------------------------------------
# 6. Application du port + durcissement SSH commun
# ----------------------------------------------------------------------------
info "Application du port et du durcissement SSH..."

set_ssh_directive "Port" "$NEW_SSH_PORT"
set_ssh_directive "MaxAuthTries" "$MAX_AUTH_TRIES"
set_ssh_directive "ClientAliveCountMax" "$CLIENT_ALIVE_COUNT_MAX"
set_ssh_directive "X11Forwarding" "no"
set_ssh_directive "AllowTcpForwarding" "no"
set_ssh_directive "AllowAgentForwarding" "no"
set_ssh_directive "Compression" "no"
set_ssh_directive "TCPKeepAlive" "no"
set_ssh_directive "LogLevel" "VERBOSE"
set_ssh_directive "MaxSessions" "$MAX_SESSIONS"

info "Test de la configuration après durcissement commun..."
if ! sshd -t; then
    restore_backup_and_exit
fi
info "Configuration valide."

# ----------------------------------------------------------------------------
# Fonction : installation et configuration de fail2ban (dans tous les cas)
# ----------------------------------------------------------------------------
install_fail2ban() {
    if [[ "$SCRIPT_MODE" == "2" ]]; then
        echo ""
        echo "Paramètres fail2ban (Entrée = valeur par défaut) :"
        F2B_MAXRETRY=$(prompt_with_default "  Tentatives max avant bannissement (maxretry)" "$DEFAULT_F2B_MAXRETRY")
        F2B_FINDTIME=$(prompt_with_default "  Fenêtre de détection en secondes (findtime)" "$DEFAULT_F2B_FINDTIME")
        F2B_BANTIME=$(prompt_with_default "  Durée du bannissement en secondes (bantime)" "$DEFAULT_F2B_BANTIME")
    fi

    info "Installation de fail2ban..."
    if ! command -v fail2ban-client &> /dev/null; then
        apt-get update -qq && apt-get install -y fail2ban
    else
        info "fail2ban déjà installé."
    fi

    local jail_file="/etc/fail2ban/jail.local"
    if [[ -f "$jail_file" ]]; then
        cp "$jail_file" "${jail_file}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    cat > "$jail_file" << EOF
[sshd]
enabled = true
port = ${NEW_SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = ${F2B_MAXRETRY}
findtime = ${F2B_FINDTIME}
bantime = ${F2B_BANTIME}
EOF

    systemctl enable fail2ban &> /dev/null || true
    if systemctl restart fail2ban; then
        info "fail2ban configuré et actif sur le port ${NEW_SSH_PORT} (${F2B_MAXRETRY} tentatives max, ban ${F2B_BANTIME}s)."
    else
        warn "fail2ban installé mais le redémarrage du service a échoué. Vérifie manuellement : systemctl status fail2ban"
    fi
}

# ----------------------------------------------------------------------------
# 7. Choix du mode d'authentification
# ----------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Comment veux-tu gérer l'authentification SSH ?${NC}"
echo "  [1] Authentification par clé SSH (désactive le mot de passe après test)"
echo "  [2] Garder le mot de passe"
echo ""
echo -e "${YELLOW}Dans les deux cas, fail2ban sera installé et configuré.${NC}"
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
        # OPTION 2 : Mot de passe conservé
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
        ;;

    *)
        error "Choix invalide. Abandon sans appliquer le mode d'authentification."
        restore_backup_and_exit
        ;;
esac

# ----------------------------------------------------------------------------
# 8. fail2ban (dans tous les cas, indépendamment du mode d'authentification)
# ----------------------------------------------------------------------------
install_fail2ban

# ----------------------------------------------------------------------------
# 9. Affichage UNIQUE des informations sensibles
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
fi
echo -e "${YELLOW}fail2ban est actif : ${F2B_MAXRETRY} tentatives échouées = ban de ${F2B_BANTIME}s sur l'IP.${NC}"
echo ""
warn "IMPORTANT : teste la connexion SSH sur le nouveau port AVANT de fermer"
warn "cette session, pour être sûr de ne pas te retrouver bloqué dehors."
echo ""
read -rp "Appuie sur [Entrée] une fois les informations notées pour les effacer de l'écran..."

clear
info "Informations effacées. Sécurisation terminée."
info "Sauvegarde de l'ancienne config conservée dans : $BACKUP_FILE"

exit 0
