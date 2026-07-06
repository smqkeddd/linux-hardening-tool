#!/usr/bin/env bash
#
# harden.sh - Outil de sécurisation rapide pour Debian/Ubuntu
#
# V1.5 :
#   - Mode simple (automatique) ou mode avancé (tu choisis les valeurs)
#   - Change le mot de passe root (aléatoire ou personnalisé)
#   - Change le port SSH (aléatoire ou personnalisé)
#   - Durcit les paramètres SSH communs (personnalisables en mode avancé)
#   - Propose au choix :
#       [1] Authentification par clé SSH (désactive le mot de passe après test)
#       [2] Conserve l'authentification par mot de passe
#   - Installe et configure fail2ban (paramètres personnalisables en mode avancé)
#   - Configure la politique d'expiration des mots de passe (login.defs + chage)
#   - Installe le contrôle de complexité des mots de passe (pam_pwquality)
#   - Installe et configure auditd (traçabilité des fichiers/actions sensibles)
#   - Installe AIDE et initialise sa base d'intégrité des fichiers
#   - Sauvegarde l'état d'origine (une seule fois) pour permettre un rollback via unharden.sh
#   - Affiche les nouvelles infos UNE SEULE FOIS à l'écran (jamais stockées sur disque)
#
# Usage : sudo ./harden.sh
#
set -euo pipefail

# Empêche TOUT dialogue interactif d'apt/dpkg/needrestart de bloquer le script
# (sans ça, needrestart ou apt-listbugs peuvent afficher une invite qui
# resterait en attente indéfiniment sur une session non-interactive)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

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

echo -e "${BOLD}=== Outil de sécurisation Linux - V1.5 ===${NC}"
echo "Ce script va :"
echo "  1. Sauvegarder ta configuration SSH actuelle"
echo "  2. Générer/définir un mot de passe root"
echo "  3. Générer/définir un port SSH"
echo "  4. Durcir les paramètres SSH (MaxAuthTries, forwarding, compression, etc.)"
echo "  5. Te proposer un choix : clé SSH OU mot de passe"
echo "  6. Installer et configurer fail2ban (bannissement des IP après échecs)"
echo "  7. Configurer la politique d'expiration des mots de passe"
echo "     (max 90j, min 7j, avertissement 14j avant expiration - appliqué à"
echo "     root et à tous les comptes existants)"
echo "  8. Installer le contrôle de complexité des mots de passe"
echo "     (12 caractères min, majuscule/minuscule/chiffre/symbole requis)"
echo "  9. Installer et configurer auditd (traçabilité des accès sensibles :"
echo "     /etc/passwd, /etc/shadow, sshd_config, sudoers, exécutions sudo)"
echo " 10. Installer AIDE et initialiser sa base d'intégrité des fichiers"
echo "     (peut prendre plusieurs minutes)"
echo " 11. T'afficher les nouvelles infos UNE SEULE FOIS"
echo ""
warn "Les étapes 7 à 10 sont chacune indépendantes : si l'une échoue (ex: pas"
warn "de connexion internet), le script continue sans s'arrêter."
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
# Fonctions : durcissements "priorité élevée" (issus de l'audit Lynis)
# Chacune est appelée dans un SOUS-SHELL isolé : si l'une échoue, le reste du
# script continue normalement (aucune propagation d'erreur en cascade).
# ----------------------------------------------------------------------------

# AUTH-9282 / AUTH-9286 : politique d'expiration des mots de passe
harden_password_policy() {
    info "Configuration de la politique d'expiration des mots de passe..."

    local login_defs="/etc/login.defs"
    if [[ ! -f "$login_defs" ]]; then
        warn "$login_defs introuvable, étape ignorée."
        return 1
    fi

    cp "$login_defs" "${login_defs}.bak.$(date +%Y%m%d%H%M%S)"

    set_login_defs_directive() {
        local key="$1"
        local value="$2"
        if grep -qE "^#?${key}[[:space:]]" "$login_defs"; then
            sed -i -E "s/^#?${key}[[:space:]]+.*/${key} ${value}/" "$login_defs"
        else
            printf '%s\t%s\n' "$key" "$value" >> "$login_defs"
        fi
    }

    set_login_defs_directive "PASS_MAX_DAYS" "90"
    set_login_defs_directive "PASS_MIN_DAYS" "7"
    set_login_defs_directive "PASS_WARN_AGE" "14"
    info "login.defs mis à jour (max 90j, min 7j, avertissement 14j avant expiration)."

    # AUTH-9328 : umask plus strict
    set_login_defs_directive "UMASK" "027"
    info "Umask par défaut renforcé (027)."

    # AUTH-9230 : rounds de hashage des mots de passe explicitement définis
    # Remarque : s'applique aux PROCHAINS changements de mot de passe, pas
    # rétroactivement au mot de passe root déjà défini plus tôt dans ce run.
    set_login_defs_directive "ENCRYPT_METHOD" "SHA512"
    set_login_defs_directive "SHA_CRYPT_MIN_ROUNDS" "5000"
    set_login_defs_directive "SHA_CRYPT_MAX_ROUNDS" "100000"
    info "Rounds de hashage des mots de passe configurés (SHA512, 5000-100000 rounds)."

    # Application rétroactive sur les comptes existants (root + comptes humains UID >= 1000)
    local username uid
    while IFS=: read -r username _ uid _; do
        if [[ "$username" == "root" || "$uid" -ge 1000 ]]; then
            if chage --maxdays 90 --mindays 7 --warndays 14 "$username" &> /dev/null; then
                info "Politique appliquée au compte : $username"
            else
                warn "Impossible d'appliquer la politique au compte : $username"
            fi
        fi
    done < /etc/passwd
}

# AUTH-9262 : test de robustesse des mots de passe (pam_pwquality)
harden_password_strength() {
    info "Installation du contrôle de complexité des mots de passe (pam_pwquality)..."

    if ! dpkg -s libpam-pwquality &> /dev/null; then
        if ! (apt-get update -qq && apt-get install -y libpam-pwquality); then
            error "Échec de l'installation de libpam-pwquality."
            return 1
        fi
    else
        info "libpam-pwquality déjà installé."
    fi

    local pam_file="/etc/pam.d/common-password"
    if [[ ! -f "$pam_file" ]]; then
        warn "$pam_file introuvable, étape ignorée."
        return 1
    fi

    cp "$pam_file" "${pam_file}.bak.$(date +%Y%m%d%H%M%S)"

    local rule="password requisite pam_pwquality.so retry=3 minlen=12 difok=3 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1"

    if grep -qE '^password\s+requisite\s+pam_pwquality\.so' "$pam_file"; then
        sed -i -E "s|^password\s+requisite\s+pam_pwquality\.so.*|${rule}|" "$pam_file"
    else
        sed -i "/^password.*pam_unix\.so/i ${rule}" "$pam_file"
    fi

    info "Complexité exigée : 12 caractères min, majuscule/minuscule/chiffre/symbole requis."
}

# ACCT-9628 : auditd
harden_auditd() {
    info "Installation et configuration d'auditd..."

    if ! command -v auditctl &> /dev/null; then
        if ! (apt-get update -qq && apt-get install -y auditd audispd-plugins); then
            error "Échec de l'installation d'auditd."
            return 1
        fi
    else
        info "auditd déjà installé."
    fi

    local rules_file="/etc/audit/rules.d/harden-sh.rules"
    cat > "$rules_file" << EOF
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd_config_changes
-w /etc/sudoers -p wa -k sudoers_changes
-w /usr/bin/passwd -p x -k passwd_exec
-w /usr/bin/sudo -p x -k sudo_exec
EOF

    if command -v augenrules &> /dev/null && augenrules --load &> /dev/null; then
        info "Règles auditd chargées avec augenrules."
    else
        warn "augenrules a échoué ou est indisponible, un redémarrage du service appliquera quand même les règles."
    fi

    systemctl enable auditd &> /dev/null || true
    if systemctl restart auditd; then
        info "auditd actif. Consultation possible avec : ausearch -k sshd_config_changes"
    else
        error "Échec du redémarrage d'auditd."
        return 1
    fi
}

# FINT-4350 : AIDE (intégrité des fichiers) + FINT-4402 : checksums SHA256
harden_aide() {
    info "Installation d'AIDE (surveillance d'intégrité des fichiers)..."

    if ! command -v aide &> /dev/null; then
        if ! (apt-get update -qq && apt-get install -y aide aide-common); then
            error "Échec de l'installation d'AIDE."
            return 1
        fi
    else
        info "AIDE déjà installé."
    fi

    # FINT-4402 : renforcement de l'algorithme de checksum (SHA256), AVANT
    # l'initialisation de la base pour éviter un double travail. On valide la
    # syntaxe avant de garder le changement, et on restaure sinon (aucun
    # risque de casser AIDE si la modification s'avère invalide).
    local aide_conf="/etc/aide/aide.conf"
    if [[ -f "$aide_conf" ]] && ! grep -q 'sha256' "$aide_conf"; then
        info "Renforcement de l'algorithme de checksum AIDE (ajout de sha256)..."
        local aide_conf_backup
        aide_conf_backup="${aide_conf}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$aide_conf" "$aide_conf_backup"

        # N'ajoute +sha256 qu'aux lignes de définition de règles (contenant
        # déjà md5 ou sha1) qui n'ont pas déjà sha256 : idempotent et ciblé,
        # ne touche à rien d'autre dans le fichier.
        sed -i -E '/^[A-Za-z_]+[[:space:]]*=.*(md5|sha1)/{ /sha256/! s/$/+sha256/ }' "$aide_conf"

        if command -v aide &> /dev/null && aide --config-check &> /dev/null; then
            info "Configuration AIDE validée avec sha256 ajouté."
        else
            warn "La modification du checksum AIDE semble invalide, restauration de la configuration d'origine."
            cp "$aide_conf_backup" "$aide_conf"
        fi
    elif [[ -f "$aide_conf" ]]; then
        info "AIDE utilise déjà sha256, aucune modification nécessaire."
    fi

    info "Initialisation de la base de référence AIDE (peut prendre plusieurs minutes)..."

    if command -v aideinit &> /dev/null && aideinit -y -f &> /dev/null; then
        info "Base AIDE initialisée via aideinit."
    elif aide --init &> /dev/null && [[ -f /var/lib/aide/aide.db.new ]]; then
        mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
        info "Base AIDE initialisée (méthode alternative)."
    else
        error "Échec de l'initialisation d'AIDE."
        return 1
    fi

    info "Vérification manuelle possible ensuite avec : aide --check"
}

# HRDN-7230 : scanner de malware (rkhunter)
harden_malware_scanner() {
    info "Installation du scanner de malware (rkhunter)..."

    if ! command -v rkhunter &> /dev/null; then
        if ! (apt-get update -qq && apt-get install -y rkhunter); then
            error "Échec de l'installation de rkhunter."
            return 1
        fi
    else
        info "rkhunter déjà installé."
    fi

    # Met à jour les définitions, puis construit une base de référence propre
    rkhunter --update &> /dev/null || warn "Échec de la mise à jour des définitions rkhunter (pas bloquant)."
    if rkhunter --propupd &> /dev/null; then
        info "rkhunter configuré (base de référence des propriétés créée)."
    else
        warn "Échec de la création de la base de référence rkhunter."
    fi

    info "Scan manuel possible ensuite avec : rkhunter --check"
}

# KRNL-5820 : désactivation des core dumps
harden_disable_coredumps() {
    info "Désactivation des core dumps..."

    local limits_file="/etc/security/limits.conf"
    if [[ ! -f "$limits_file" ]]; then
        warn "$limits_file introuvable, étape ignorée."
        return 1
    fi
    cp "$limits_file" "${limits_file}.bak.$(date +%Y%m%d%H%M%S)"

    if ! grep -qE '^\*[[:space:]]+hard[[:space:]]+core[[:space:]]+0' "$limits_file"; then
        echo "* hard core 0" >> "$limits_file"
    fi
    if ! grep -qE '^\*[[:space:]]+soft[[:space:]]+core[[:space:]]+0' "$limits_file"; then
        echo "* soft core 0" >> "$limits_file"
    fi

    local sysctl_file="/etc/sysctl.d/60-harden-sh-coredump.conf"
    echo "fs.suid_dumpable = 0" > "$sysctl_file"
    sysctl -p "$sysctl_file" &> /dev/null || warn "Échec de l'application immédiate du sysctl (sera actif au prochain boot)."

    info "Core dumps désactivés (limits.conf + sysctl)."
}

# USB-1000 / STRG-1846 : désactivation du stockage amovible (USB/Firewire)
harden_disable_removable_storage() {
    info "Désactivation des pilotes de stockage amovible (USB/Firewire)..."

    local blacklist_file="/etc/modprobe.d/harden-sh-blacklist-storage.conf"
    cat > "$blacklist_file" << 'EOF'
# Ajouté par harden.sh - désactive le stockage amovible
blacklist usb-storage
blacklist firewire-core
blacklist firewire-ohci
blacklist firewire-sbp2
EOF

    # Tentative de déchargement immédiat : échec sans gravité si le module
    # est déjà en cours d'utilisation ou absent (effectif au prochain boot).
    modprobe -r usb-storage &> /dev/null || true
    modprobe -r firewire-ohci &> /dev/null || true

    info "Stockage amovible désactivé pour les prochains démarrages : $blacklist_file"
}

# NETW-3200 : désactivation des protocoles réseau rarement utilisés
harden_disable_rare_protocols() {
    info "Désactivation des protocoles réseau rares (dccp, sctp, rds, tipc)..."

    local blacklist_file="/etc/modprobe.d/harden-sh-blacklist-netproto.conf"
    cat > "$blacklist_file" << 'EOF'
# Ajouté par harden.sh - empêche le chargement de ces protocoles rares
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
EOF

    info "Protocoles réseau rares bloqués : $blacklist_file"
}

# PKGS-7420 : mises à jour de sécurité automatiques
harden_auto_updates() {
    info "Installation des mises à jour de sécurité automatiques (unattended-upgrades)..."

    if ! dpkg -s unattended-upgrades &> /dev/null; then
        if ! (apt-get update -qq && apt-get install -y unattended-upgrades); then
            error "Échec de l'installation d'unattended-upgrades."
            return 1
        fi
    else
        info "unattended-upgrades déjà installé."
    fi

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    systemctl enable --now unattended-upgrades &> /dev/null || true
    info "Mises à jour de sécurité automatiques activées."
}

# ACCT-9622 / ACCT-9626 : process accounting + sysstat
harden_process_accounting() {
    info "Activation du process accounting (acct) et de sysstat..."

    if ! dpkg -s acct &> /dev/null; then
        if ! (apt-get update -qq && apt-get install -y acct); then
            error "Échec de l'installation d'acct."
            return 1
        fi
    fi
    systemctl enable --now acct &> /dev/null || true

    if ! dpkg -s sysstat &> /dev/null; then
        if ! (apt-get update -qq && apt-get install -y sysstat); then
            error "Échec de l'installation de sysstat."
            return 1
        fi
    fi

    if [[ -f /etc/default/sysstat ]]; then
        sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
    fi
    systemctl enable --now sysstat &> /dev/null || true

    info "Process accounting et sysstat actifs."
}

# PKGS-7370 / PKGS-7394 / DEB-0280 / DEB-0810 / DEB-0831 : utilitaires complémentaires
harden_misc_packages() {
    info "Installation des utilitaires complémentaires (debsums, apt-show-versions,"
    info "libpam-tmpdir, apt-listbugs, needrestart)..."

    local packages=(debsums apt-show-versions libpam-tmpdir apt-listbugs needrestart)

    if apt-get update -qq && apt-get install -y "${packages[@]}"; then
        info "Utilitaires installés : ${packages[*]}"
    else
        error "Échec de l'installation d'un ou plusieurs utilitaires complémentaires."
        return 1
    fi
}

# BANN-7126 / BANN-7130 : bannière légale SSH
harden_legal_banner() {
    info "Ajout d'une bannière légale (/etc/issue et /etc/issue.net)..."

    local banner_text="Accès réservé aux utilisateurs autorisés. Toute tentative d'accès non autorisé est interdite et peut faire l'objet de poursuites."
    local sshd_snapshot
    sshd_snapshot="${SSHD_CONFIG}.bak.banner.$(date +%Y%m%d%H%M%S)"

    cp "$SSHD_CONFIG" "$sshd_snapshot"
    echo "$banner_text" > /etc/issue
    echo "$banner_text" > /etc/issue.net
    set_ssh_directive "Banner" "/etc/issue.net"

    if ! sshd -t; then
        error "Configuration SSH invalide après ajout de la bannière, restauration..."
        cp "$sshd_snapshot" "$SSHD_CONFIG"
        return 1
    fi

    if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
        info "Bannière légale configurée et SSH redémarré."
    else
        error "Échec du redémarrage SSH après ajout de la bannière, restauration..."
        cp "$sshd_snapshot" "$SSHD_CONFIG"
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        return 1
    fi
}

# TIME-3185 : synchronisation NTP (systemd-timesyncd)
harden_time_sync() {
    info "Vérification/activation de la synchronisation NTP (systemd-timesyncd)..."

    if ! command -v timedatectl &> /dev/null; then
        warn "timedatectl indisponible, étape ignorée."
        return 1
    fi

    timedatectl set-ntp true 2>/dev/null || true
    systemctl enable --now systemd-timesyncd &> /dev/null || true

    if systemctl restart systemd-timesyncd; then
        info "systemd-timesyncd actif (la synchronisation effective dépend de l'accès réseau aux serveurs NTP)."
    else
        error "Échec du redémarrage de systemd-timesyncd."
        return 1
    fi
}

# ----------------------------------------------------------------------------
# 8. fail2ban (dans tous les cas, indépendamment du mode d'authentification)
# ----------------------------------------------------------------------------
install_fail2ban

# ----------------------------------------------------------------------------
# 8.5. Durcissements priorité élevée, moyenne et faible (chacun isolé, une
# erreur n'arrête jamais le reste du script)
# ----------------------------------------------------------------------------
echo ""
info "Application des durcissements complémentaires (audit Lynis)..."

( harden_password_policy )            || warn "Échec de la politique d'expiration des mots de passe, on continue."
( harden_password_strength )          || warn "Échec du contrôle de complexité des mots de passe, on continue."
( harden_auditd )                     || warn "Échec de la configuration d'auditd, on continue."
( harden_aide )                       || warn "Échec de l'initialisation d'AIDE, on continue."
( harden_malware_scanner )            || warn "Échec de l'installation du scanner de malware, on continue."
( harden_disable_coredumps )          || warn "Échec de la désactivation des core dumps, on continue."
( harden_disable_removable_storage )  || warn "Échec de la désactivation du stockage amovible, on continue."
( harden_disable_rare_protocols )     || warn "Échec de la désactivation des protocoles réseau rares, on continue."
( harden_auto_updates )               || warn "Échec de l'installation des mises à jour automatiques, on continue."
( harden_process_accounting )         || warn "Échec de l'activation du process accounting, on continue."
( harden_misc_packages )              || warn "Échec de l'installation des utilitaires complémentaires, on continue."
( harden_legal_banner )               || warn "Échec de l'ajout de la bannière légale, on continue."
( harden_time_sync )                  || warn "Échec de la synchronisation NTP, on continue."

info "Durcissements complémentaires terminés."

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
echo -e "${YELLOW}Politique mdp (expiration 90j), complexité (12 car. min), auditd et AIDE"
echo -e "ont été configurés (voir les [!] ci-dessus si l'une des étapes a échoué).${NC}"
echo ""
warn "IMPORTANT : teste la connexion SSH sur le nouveau port AVANT de fermer"
warn "cette session, pour être sûr de ne pas te retrouver bloqué dehors."
echo ""
read -rp "Appuie sur [Entrée] une fois les informations notées pour les effacer de l'écran..."

clear
info "Informations effacées. Sécurisation terminée."
info "Sauvegarde de l'ancienne config conservée dans : $BACKUP_FILE"

exit 0
