# Changelog

Toutes les modifications notables de ce projet seront documentées dans ce fichier.

Le format suit [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/),
et ce projet respecte le [Semantic Versioning](https://semver.org/lang/fr/).

## [Non publié]

### Ajouté
- **Mode avancé pour `harden.sh`** : au lancement, choix entre mode simple (tout automatique) et mode avancé, qui permet de définir soi-même :
  - Le mot de passe root (généré aléatoirement ou personnalisé, avec confirmation double-saisie et avertissement si trop court)
  - Le port SSH (généré aléatoirement ou personnalisé, avec validation de plage, avertissement sur les ports privilégiés, et vérification qu'il n'est pas déjà utilisé)
  - Les paramètres de durcissement SSH (`MaxAuthTries`, `ClientAliveCountMax`, `MaxSessions`)
  - Les paramètres fail2ban (`maxretry`, `findtime`, `bantime`)
  - En mode simple, toutes ces valeurs restent générées/définies automatiquement comme avant (aucune régression)
- Nouvelle fonction `prompt_with_default()` réutilisable pour les questions avec valeur par défaut
- **Fallback dans `unharden.sh` (mode [2])** : si aucune référence d'origine n'est trouvée dans `/var/lib/harden-sh/` (ex : machine ayant utilisé une version de `harden.sh` antérieure à cette fonctionnalité), le script liste automatiquement les sauvegardes `.bak.*` disponibles avec leur date/heure, et laisse choisir laquelle restaurer
- Nouveau script `unharden.sh` : annule les modifications de `harden.sh`, avec un menu à deux modes :
  - **[1] Reset complet par défaut** : port 22, mot de passe root `root` (faible, usage labo/test uniquement), retire la clé SSH ajoutée, désinstalle fail2ban
  - **[2] Restauration de l'état exact d'avant harden.sh** : redonne à `sshd_config` sa configuration d'origine (ex: si le port était déjà personnalisé avant, ex 222, il le redevient), restaure/supprime `authorized_keys` selon l'état d'origine, gère fail2ban en conséquence
  - Sauvegarde automatique de l'état d'origine (sshd_config, authorized_keys, présence/config fail2ban) lors de la **toute première exécution** de `harden.sh`, stockée dans `/var/lib/harden-sh/` (aucune donnée sensible : pas de mots de passe stockés, uniquement de la config et des clés publiques)
  - **Limite connue** : le mot de passe root d'origine ne peut jamais être restauré dans le mode [2] (jamais stocké nulle part, par design sécurité). Un nouveau mot de passe aléatoire est généré à la place, affiché une seule fois

### À venir
- Option de création d'utilisateur sudo non-root
- Désactivation optionnelle de PermitRootLogin

### Modifié
- fail2ban est désormais installé et configuré **dans les deux modes d'authentification** (clé SSH ou mot de passe), et non plus uniquement en mode mot de passe. Utile même avec des clés pour limiter le bruit des scans/tentatives automatisées.

### Testé puis mis de côté
- Mot de passe GRUB aléatoire : fonctionnel, mais retiré temporairement car le comportement par défaut de GRUB (`superusers` + `password_pbkdf2`) demande le mot de passe à **chaque démarrage**, pas seulement pour l'édition des entrées de boot. Risque de blocage sur un serveur distant sans accès console. À réintroduire une fois l'option `--unrestricted` correctement gérée pour les entrées de boot normales.
- Firewall ufw : testé avec succès (politique par défaut + autorisation du port SSH avant activation), mais mis de côté pour se concentrer sur d'autres priorités. À réintégrer plus tard.

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
