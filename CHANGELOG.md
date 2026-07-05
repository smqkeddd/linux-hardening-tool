# Changelog

Toutes les modifications notables de ce projet seront documentées dans ce fichier.

Le format suit [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/),
et ce projet respecte le [Semantic Versioning](https://semver.org/lang/fr/).

## [Non publié]

### À venir
- Option de création d'utilisateur sudo non-root
- Désactivation optionnelle de PermitRootLogin
- Intégration ufw

## [0.2.0] - 2026-07-05

### Ajouté
- Génération et application d'un mot de passe GRUB aléatoire (`password_pbkdf2`)
- Sauvegarde automatique de `/etc/grub.d/40_custom` avant modification
- Restauration automatique de la config GRUB en cas d'échec de `update-grub`
- Le mot de passe GRUB est désormais affiché avec les autres identifiants (une seule fois)

### Modifié
- Le script passe en V1.1, gère désormais un échec silencieux si GRUB n'est pas installé (ex : environnements cloud sans GRUB classique)

## [0.1.0] - 2026-07-05

### Ajouté
- Script `harden.sh` initial
- Sauvegarde automatique de `sshd_config`
- Génération d'un mot de passe root aléatoire sécurisé
- Génération d'un port SSH aléatoire
- Test de validité de la configuration avant redémarrage du service SSH
- Restauration automatique en cas d'erreur
- Affichage unique des informations sensibles à l'écran
