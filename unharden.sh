#!/usr/bin/env bash
#
# unharden.sh - Annule les modifications appliquées par harden.sh
#
# Propose deux modes :
#   [1] Reset complet aux valeurs par défaut (port 22, mdp root = "root",
#       retire la clé SSH ajoutée, désinstalle fail2ban)
#       -> Usage labo/test uniquement, JAMAIS sur une machine exposée.
#   [2] Restaure l'état exact d'AVANT la première exécution de harden.sh
#       (ex : si le port SSH était déjà à 222 avant, il redevient 222)
#
# NE PEUT PAS restaurer dans le mode [2] :
#   - Le mot de passe root d'origine (jamais stocké, par sécurité). Un nouveau
#     mot de passe aléatoire est généré à la place.
#
# Usage : sudo ./unharden.sh
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }

# ----------------------------------------------------------------------------
# Nettoyage garanti même en cas d'interruption
# ----------------------------------------------------------------------------
NEW_ROOT_PASSWORD=""

cleanup() {
    NEW_ROOT_PASSWORD=""
    unset NEW_ROOT_PASSWORD
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# Vérifications préalables
# ----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en root (utilise : sudo ./unharden.sh)"
    exit 1
fi

STATE_DIR="/var/lib/harden-sh"
SSHD_CONFIG="/etc/ssh/sshd_config"

if [[ ! -f "$SSHD_CONFIG" ]]; then
    error "Fichier $SSHD_CONFIG introuvable. OpenSSH est-il installé ?"
    exit 1
fi

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
# Fonction utilitaire : commente une directive (retour au défaut OpenSSH)
# ----------------------------------------------------------------------------
comment_out_directive() {
    local key="$1"
    sed -i -E "s/^(${key}[[:space:]].*)/#\1/" "$SSHD_CONFIG"
}

echo -e "${BOLD}=== unharden.sh - Annulation du durcissement ===${NC}"
echo ""
echo "  [1] Reset complet par défaut (port 22, mdp root = 'root', retire la clé SSH,"
echo "      désinstalle fail2ban) — usage labo/test UNIQUEMENT"
echo "  [2] Restaurer l'état exact d'avant la première exécution de harden.sh"
echo ""
read -rp "Ton choix (1/2) : " RESET_MODE

case "$RESET_MODE" in

    1)
        # ------------------------------------------------------------------
        # OPTION 1 : Reset complet par défaut
        # ------------------------------------------------------------------
        echo ""
        warn "Ce mode remet un mot de passe root FAIBLE ('root') et désactive tout"
        warn "le durcissement SSH. À réserver STRICTEMENT à une VM de test/labo,"
        warn "jamais à une machine exposée sur internet."
        echo ""
        read -rp "Confirmer le reset complet par défaut ? (o/N) : " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[oOyY]$ ]]; then
            warn "Annulé par l'utilisateur."
            exit 0
        fi

        BACKUP_FILE="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$SSHD_CONFIG" "$BACKUP_FILE"
        info "Sauvegarde de sécurité créée : $BACKUP_FILE"

        info "Remise à zéro des directives SSH durcies..."
        for directive in MaxAuthTries ClientAliveCountMax X11Forwarding AllowTcpForwarding \
                         AllowAgentForwarding Compression TCPKeepAlive LogLevel MaxSessions \
                         PubkeyAuthentication; do
            comment_out_directive "$directive"
        done
        set_ssh_directive "Port" "22"
        set_ssh_directive "PasswordAuthentication" "yes"

        if ! sshd -t; then
            error "Configuration invalide après reset. Restauration de la sauvegarde de sécurité..."
            cp "$BACKUP_FILE" "$SSHD_CONFIG"
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
            exit 1
        fi

        if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
            info "SSH remis sur le port 22 avec la configuration par défaut."
        else
            error "Échec du redémarrage SSH. Vérifie manuellement."
            exit 1
        fi

        if [[ -f /root/.ssh/authorized_keys ]]; then
            rm -f /root/.ssh/authorized_keys
            info "Clé(s) SSH retirée(s) de authorized_keys."
        fi

        if command -v fail2ban-client &> /dev/null; then
            info "Désinstallation de fail2ban..."
            systemctl stop fail2ban 2>/dev/null || true
            systemctl disable fail2ban 2>/dev/null || true
            if apt-get remove -y fail2ban &> /dev/null; then
                info "fail2ban désinstallé."
            else
                warn "Échec de la désinstallation de fail2ban. Vérifie manuellement : apt remove fail2ban"
            fi
        fi

        info "Remise à zéro du mot de passe root (mdp faible : 'root')..."
        echo "root:root" | chpasswd

        FINAL_PORT="22"
        FINAL_PASSWORD="root"
        ;;

    2)
        # ------------------------------------------------------------------
        # OPTION 2 : Restauration de l'état exact d'avant harden.sh
        # ------------------------------------------------------------------
        SSHD_SOURCE=""
        USING_FALLBACK=0

        if [[ -f "$STATE_DIR/.initialized" ]]; then
            SSHD_SOURCE="$STATE_DIR/sshd_config.orig"
        else
            # ---------------------------------------------------------------
            # Fallback : pas de référence "pristine", on cherche les .bak.*
            # classiques créés à chaque exécution de harden.sh
            # ---------------------------------------------------------------
            warn "Aucune référence d'origine trouvée dans $STATE_DIR."
            warn "(Cette machine a probablement utilisé une version de harden.sh"
            warn "antérieure à l'ajout de cette fonctionnalité.)"
            echo ""

            shopt -s nullglob
            BACKUPS=( "${SSHD_CONFIG}".bak.* )
            shopt -u nullglob

            if [[ ${#BACKUPS[@]} -eq 0 ]]; then
                error "Aucune sauvegarde .bak.* trouvée non plus. Impossible de restaurer."
                error "Utilise l'option [1] (reset par défaut) à la place."
                exit 1
            fi

            info "Sauvegardes disponibles (de la plus ancienne à la plus récente) :"
            echo ""
            for i in "${!BACKUPS[@]}"; do
                ts=$(basename "${BACKUPS[$i]}" | sed -E 's/.*\.bak\.//')
                formatted=$(date -d "${ts:0:8} ${ts:8:2}:${ts:10:2}:${ts:12:2}" '+%d/%m/%Y à %H:%M:%S' 2>/dev/null || echo "$ts")
                if [[ "$i" -eq 0 ]]; then
                    echo "  [$i] ${BACKUPS[$i]}  (${formatted}) ${GREEN}<- la plus ancienne, recommandée${NC}"
                else
                    echo "  [$i] ${BACKUPS[$i]}  (${formatted})"
                fi
            done
            echo ""
            read -rp "Numéro de la sauvegarde à restaurer (Entrée = 0, la plus ancienne) : " BACKUP_CHOICE
            BACKUP_CHOICE="${BACKUP_CHOICE:-0}"

            if ! [[ "$BACKUP_CHOICE" =~ ^[0-9]+$ ]] || [[ -z "${BACKUPS[$BACKUP_CHOICE]:-}" ]]; then
                error "Choix invalide."
                exit 1
            fi

            SSHD_SOURCE="${BACKUPS[$BACKUP_CHOICE]}"
            USING_FALLBACK=1
            info "Sauvegarde sélectionnée : $SSHD_SOURCE"
        fi

        echo ""
        echo "Ce mode va restaurer :"
        echo "  - La configuration SSH choisie (port inclus, ex: 222 si c'était le cas)"
        if [[ "$USING_FALLBACK" -eq 0 ]]; then
            echo "  - authorized_keys (restauré ou supprimé selon l'état d'origine)"
            echo "  - fail2ban (désinstallé si ajouté par harden.sh, ou restauré à sa config d'origine)"
        else
            warn "Mode fallback : authorized_keys et fail2ban ne peuvent pas être gérés"
            warn "automatiquement (pas de référence d'origine pour ces éléments)."
        fi
        echo ""
        warn "Le mot de passe root d'origine ne peut PAS être restauré (jamais stocké, par sécurité)."
        echo ""
        read -rp "Continuer ? (o/N) : " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[oOyY]$ ]]; then
            warn "Annulé par l'utilisateur."
            exit 0
        fi

        info "Restauration de la configuration SSH sélectionnée..."
        cp "$SSHD_SOURCE" "$SSHD_CONFIG"

        if ! sshd -t; then
            error "La configuration restaurée est invalide. Abandon sans redémarrer SSH."
            error "Vérifie manuellement : $SSHD_SOURCE"
            exit 1
        fi

        if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
            info "SSH restauré à la configuration sélectionnée."
        else
            error "Échec du redémarrage de SSH après restauration. Vérifie manuellement."
            exit 1
        fi

        ORIGINAL_PORT=$(grep -E '^Port[[:space:]]' "$SSHD_CONFIG" | awk '{print $2}' | head -1)
        ORIGINAL_PORT="${ORIGINAL_PORT:-22}"

        if [[ "$USING_FALLBACK" -eq 0 ]]; then
        info "Restauration de l'état d'origine de authorized_keys..."
        if [[ -f "$STATE_DIR/authorized_keys.orig" ]]; then
            cp "$STATE_DIR/authorized_keys.orig" /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
            info "authorized_keys restauré à son contenu d'origine."
        elif [[ -f "$STATE_DIR/authorized_keys.absent" ]]; then
            rm -f /root/.ssh/authorized_keys
            info "authorized_keys supprimé (il n'existait pas avant le durcissement)."
        fi

        if [[ -f "$STATE_DIR/fail2ban.installed_by_script" ]]; then
            info "fail2ban avait été installé par harden.sh : désinstallation..."
            systemctl stop fail2ban 2>/dev/null || true
            systemctl disable fail2ban 2>/dev/null || true
            if apt-get remove -y fail2ban &> /dev/null; then
                info "fail2ban désinstallé."
            else
                warn "Échec de la désinstallation de fail2ban. Vérifie manuellement : apt remove fail2ban"
            fi
        elif [[ -f "$STATE_DIR/fail2ban.preexisting" ]]; then
            info "fail2ban était déjà présent avant harden.sh : conservation de l'installation."
            if [[ -f "$STATE_DIR/jail.local.orig" ]]; then
                cp "$STATE_DIR/jail.local.orig" /etc/fail2ban/jail.local
                info "jail.local restauré à son contenu d'origine."
            elif [[ -f "$STATE_DIR/jail.local.absent" ]]; then
                rm -f /etc/fail2ban/jail.local
                info "jail.local supprimé (il n'existait pas avant le durcissement)."
            fi
            systemctl restart fail2ban 2>/dev/null || true
        fi
        fi

        info "Génération d'un nouveau mot de passe root (l'original ne peut pas être restauré)..."
        NEW_ROOT_PASSWORD=$(openssl rand -base64 24)
        echo "root:${NEW_ROOT_PASSWORD}" | chpasswd

        FINAL_PORT="$ORIGINAL_PORT"
        FINAL_PASSWORD="$NEW_ROOT_PASSWORD"

        if [[ "$USING_FALLBACK" -eq 0 ]]; then
            read -rp "Supprimer l'état sauvegardé ($STATE_DIR) ? Un futur harden.sh recréera une référence d'origine. (o/N) : " CLEAN_STATE
            if [[ "$CLEAN_STATE" =~ ^[oOyY]$ ]]; then
                rm -rf "$STATE_DIR"
                info "État sauvegardé supprimé."
            fi
        fi
        ;;

    *)
        error "Choix invalide. Aucune action effectuée."
        exit 1
        ;;
esac

# ----------------------------------------------------------------------------
# Affichage UNIQUE des informations sensibles
# ----------------------------------------------------------------------------
clear
echo -e "${BOLD}${RED}=== INFORMATIONS SENSIBLES - À NOTER MAINTENANT ===${NC}"
echo ""
echo -e "  ${BOLD}Port SSH      :${NC} ${FINAL_PORT}"
echo -e "  ${BOLD}Mdp root      :${NC} ${FINAL_PASSWORD}"
echo ""
echo -e "${YELLOW}Ces informations ne seront affichées qu'une seule fois et ne sont"
echo -e "stockées nulle part sur le disque.${NC}"
echo ""
echo -e "Pour te reconnecter : ${BOLD}ssh -p ${FINAL_PORT} root@<ip_de_la_machine>${NC}"
echo ""
warn "IMPORTANT : teste la connexion SSH sur le port ${FINAL_PORT} AVANT de fermer"
warn "cette session, pour être sûr de ne pas te retrouver bloqué dehors."
echo ""
read -rp "Appuie sur [Entrée] une fois les informations notées pour les effacer de l'écran..."

clear
info "Opération terminée."

exit 0
