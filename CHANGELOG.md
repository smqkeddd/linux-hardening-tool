# Changelog

Toutes les modifications notables de ce projet seront documentées dans ce fichier.

Le format suit [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/),
et ce projet respecte le [Semantic Versioning](https://semver.org/lang/fr/).

## [Non publié]

### Ajouté
- **GRUB** : mot de passe (aléatoire, ou personnalisé en mode avancé) protégeant l'édition des entrées de boot et la console GRUB, sans bloquer le démarrage normal (patch `--unrestricted` sur `10_linux`)
- **PermitRootLogin=prohibit-password** : appliqué uniquement si l'authentification par clé a été confirmée fonctionnelle dans la même exécution, pour éviter tout risque de blocage
- **rkhunter** : installation, mise à jour des définitions, création de la base de référence
- **Core dumps désactivés** (`limits.conf` + `sysctl`)
- **Stockage amovible désactivé** (USB, Firewire) via blacklist modprobe
- **Protocoles réseau rares bloqués** (dccp, sctp, rds, tipc)
- **Mises à jour de sécurité automatiques** (`unattended-upgrades`)
- **Process accounting** (`acct`) et `sysstat`
- **Bannière légale SSH** bilingue (contient les mots-clés requis par les audits type Lynis)
- **Synchronisation NTP** (`systemd-timesyncd`)
- **Politique de mots de passe étendue** : umask 027, rounds de hashage SHA512 explicites, en plus de l'expiration déjà en place
- **Complexité des mots de passe** (`pam_pwquality`), **auditd**, **AIDE** (durcissements "priorité élevée" de l'audit Lynis)
- **Mode avancé pour `harden.sh`** : choix du port SSH, du mot de passe root, du mot de passe GRUB, et des réglages fins (SSH, fail2ban) — Entrée garde la valeur par défaut
- **`unharden.sh`** : annule les modifications de `harden.sh`, menu à deux modes (reset par défaut, ou retour à l'état exact d'avant `harden.sh`), avec repli automatique sur les sauvegardes `.bak.*` si la référence d'origine est absente
- Sauvegarde de l'état d'origine de la machine au tout premier lancement de `harden.sh` (`/var/lib/harden-sh/`)

### Corrigé
- Bug de délimiteur `sed` dans la fonction d'application des directives (`/` en conflit avec des valeurs contenant elles-mêmes des `/`, comme `Banner /etc/issue.net`)
- Détection du checksum AIDE trop restrictive (ne fonctionnait pas avec la config par défaut Debian `Checksums = H`)
- Validation `aide --config-check` incomplète (paramètre `--config` manquant, faisait échouer la validation à tort)
- Bannière légale entièrement en français : ne matchait aucun des mots-clés attendus par le test Lynis (liste en anglais) — texte rendu bilingue

### Optimisé
- Fusion de `set_ssh_directive()` et `set_login_defs_directive()` en une seule fonction générique `set_directive()`
- Extraction du pattern de redémarrage SSH (`restart_ssh()`) et du pattern sauvegarde/test/rollback (`safe_apply_ssh_directive()`), tous deux dupliqués une dizaine de fois auparavant
- Réorganisation du script dans un ordre plus logique (helpers → vérifications → cœur SSH → durcissements complémentaires → affichage)
- Commentaires raccourcis, suppression des séparateurs `# ----------`
- Script réduit de ~1150 à ~790 lignes sans perte de fonctionnalité

### À venir
- Option de création d'utilisateur sudo non-root
- Durcissement de l'accès aux compilateurs (HRDN-7222)

### Testé puis mis de côté
- Firewall ufw : fonctionnel, mis de côté pour se concentrer sur d'autres priorités

## [0.3.0] - 2026-07-05

### Ajouté
- Durcissement SSH commun : `MaxAuthTries`, `ClientAliveCountMax`, `MaxSessions`, désactivation de `X11Forwarding`, `AllowTcpForwarding`, `AllowAgentForwarding`, `Compression`, `TCPKeepAlive`, `LogLevel VERBOSE`
- Menu interactif de choix d'authentification :
  - Option clé SSH : ajout de clé publique dans `authorized_keys`, test obligatoire avant désactivation du mot de passe
  - Option mot de passe + fail2ban : installation et configuration automatique de fail2ban (jail sshd, 3 tentatives, ban 1h)
- Fonction `set_ssh_directive()` réutilisable pour appliquer proprement les directives sshd_config
- Restauration automatique de la sauvegarde en cas d'échec à n'importe quelle étape du durcissement SSH

## [0.1.0] - 2026-07-05

### Ajouté
- Script `harden.sh` initial
- Sauvegarde automatique de `sshd_config`
- Génération d'un mot de passe root aléatoire sécurisé
- Génération d'un port SSH aléatoire
- Test de validité de la configuration avant redémarrage du service SSH
- Restauration automatique en cas d'erreur
- Affichage unique des informations sensibles à l'écran
⠀⠀⢀⠤⣂⣤⣬⣭⣭⣭⣔⡠⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠔⣵⣾⣿⣿⣿⢿⣿⣿⣿⣿⣎⢂⠀⢲⣤⣤⣤⣤⣀⣒⣒⣒⣒⣂⡠⠤⠤⣄
⠐⣾⣿⣿⣿⡏⣾⡿⢎⣛⣫⣭⣴⣾⠆⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⢼
⡇⣿⣿⣿⣿⣟⡿⢀⣐⣻⣛⡩⢁⠀⠀⣘⣛⣛⡛⠿⠿⠿⢿⣿⣿⣿⣿⣿⢟⣾
⡇⣿⣿⣿⣿⣷⣾⣿⣿⣿⣿⣿⣶⡕⠄⠉⠛⠛⠛⠛⡻⣣⣾⣿⣿⣿⢟⣵⣿⠛
⠃⣿⣿⣿⣿⣿⢋⣥⠭⡻⣿⣿⣿⣿⡌⡄⠀⠀⠀⡐⣼⣿⣿⣿⡿⣣⣾⠏⠀⠀
⠨⢻⣿⣿⣿⣧⢻⠁⠀⠘⢸⣿⣿⣿⡇⣿⠀⠀⠌⣼⣿⣿⣿⡿⢱⣿⠃⠀⠀⠀
⠀⢦⢻⣿⣿⣿⣦⣐⣀⣊⣼⣿⣿⡿⢱⡿⠀⠰⣸⣿⣿⣿⣿⢣⣿⠃⠀⠀⠀⠀
⠀⠀⠣⣙⠿⣿⣿⣿⣿⣿⣿⠿⢛⣵⡿⠃⢀⢃⣿⣿⣿⣿⡟⣾⡇⠀⠀⠀⠀⠀
⠀⠀⠀⠈⠛⠶⣮⣭⣭⣴⣶⡿⠿⠋⠀⠀⢨⣘⣿⡻⠿⠿⢇⣿⠀⠀⠀⠀⠀⠀
⠀⠀⢀⠔⠒⠂⠠⠤⠭⡀⠀⠀⠀⠀⠀⠀⠀⠙⠛⠛⠛⠛⠻⠃⠀⠀⠀⠀⠀⠀
⢀⠆⠁⠀⡄⠀⠀⠀⠀⠈⢂⠀⠀⠀⠀⠀⠀⠀⠀⢀⡤⠒⠁⠀⠀⠒⢤⡀⠀⠀
⠣⠤⢤⠞⠂⠀⣀⠰⠃⠀⠘⣆⢀⣀⠀⠀⠀⠀⢀⠎⠀⢠⡀⠀⠀⠀⢀⠀⠙⡀
⠀⠀⢸⠀⠈⠭⡀⢈⣡⠔⢶⠁⣹⢩⠃⠀⢀⠀⢸⠀⠀⠀⣑⣠⣤⠀⠙⡦⣀⠜
⠀⠀⠀⠣⠀⢂⠞⠱⠴⣈⡸⠰⢇⠘⠀⠰⡭⠷⢝⡤⣂⣄⠒⢤⡐⠀⠀⡇⠀⠀
⠀⠀⠀⠀⠱⠄⣀⢜⢁⡠⠥⠊⠀⠀⠀⠀⠡⡘⡄⠐⡂⠘⢌⡀⠉⠂⡸⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠙⠄⠹⢅⣀⠹⠒⠊⠀⠀⠀⠠
