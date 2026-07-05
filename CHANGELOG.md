# Changelog

Toutes les modifications notables de ce projet seront documentées dans ce fichier.

Le format suit [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/),
et ce projet respecte le [Semantic Versioning](https://semver.org/lang/fr/).

## [Non publié]

### À venir
- Option de création d'utilisateur sudo non-root
- Désactivation optionnelle de PermitRootLogin
- Intégration ufw

### Modifié
- fail2ban est désormais installé et configuré **dans les deux modes d'authentification** (clé SSH ou mot de passe), et non plus uniquement en mode mot de passe. Utile même avec des clés pour limiter le bruit des scans/tentatives automatisées.

### Testé puis mis de côté
- Mot de passe GRUB aléatoire : fonctionnel, mais retiré temporairement car le comportement par défaut de GRUB (`superusers` + `password_pbkdf2`) demande le mot de passe à **chaque démarrage**, pas seulement pour l'édition des entrées de boot. Risque de blocage sur un serveur distant sans accès console. À réintroduire une fois l'option `--unrestricted` correctement gérée pour les entrées de boot normales.

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
