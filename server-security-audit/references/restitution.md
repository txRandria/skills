# Phase 5 — restitution

## Deux livrables, jamais fusionnés

| Livrable | Contenu | Ce qu'il n'est pas |
|---|---|---|
| **Constat** | Ce qui a été observé, avec la méthode et l'horodatage | Une liste de tâches |
| **Recommandations** | Ce qui est proposé, priorisé, chiffré | Des actions déjà appliquées |

Fusionner les deux fait perdre au client la possibilité de contester un constat
avant d'en accepter la correction — et rend impossible, plus tard, de savoir ce
qui était vrai au moment de l'audit.

Si une action a malgré tout été appliquée pendant la collecte (urgence, demande
explicite), elle figure **en tête du rapport**, dans un encadré séparé, avec son
horodatage et son motif.

## Format d'un constat

```
[CRITIQUE] C-03 — Base de données PostgreSQL joignable depuis Internet

Observation : le port 5432 répond depuis <ip-externe> (mesuré le 2026-09-09
à 10:42 UTC). Le conteneur publie 0.0.0.0:5432->5432/tcp. La politique UFW
déclare pourtant « deny incoming » hors 22/80/443 : le trafic vers les
conteneurs ne traverse pas la chaîne où cette politique est écrite.

Méthode : ss -tulpn sur l'hôte, docker ps, puis balayage TCP depuis une
machine externe au réseau du serveur.

Impact : le rôle applicatif porte l'attribut superutilisateur (voir C-04),
ce qui transforme une authentification réussie sur ce port en exécution de
commandes sur l'hôte de la base.

Preuve : sortie nmap jointe (annexe A), horodatée.

Proposition : limiter la publication à 127.0.0.1, ou placer la base sur un
réseau interne sans route sortante. Vérification attendue : le port 5432
doit être filtré depuis l'extérieur, l'application doit rester fonctionnelle.
```

Éléments obligatoires : identifiant stable, gravité, **observation**, **méthode**,
**impact concret**, **preuve horodatée**, proposition avec sa vérification
attendue.

Ce qui rend un constat exploitable, c'est l'impact concret. « Configuration
réseau permissive » est une opinion ; « le port répond depuis l'extérieur et le
compte qui s'y authentifie peut exécuter des commandes » est un constat.

## Échelle de gravité

La gravité se déduit de ce que l'accès permet, croisé avec sa facilité
d'obtention — dans cet ordre.

| Niveau | Critère |
|---|---|
| **Critique** | Exécution de code ou accès aux données sans authentification, depuis l'extérieur. Identifiants d'usine valides sur un service exposé. Indicateur de compromission active. |
| **Élevé** | Escalade vers root ou superutilisateur de base depuis un accès applicatif. Service sensible exposé avec authentification faible. Secret exposé et encore valide. |
| **Moyen** | Divulgation d'information (version, trace de pile, endpoint d'administration). Absence de journalisation. Privilège excessif non directement exploitable depuis l'extérieur. |
| **Faible** | Durcissement manquant sans chemin d'exploitation identifié. Correctifs en attente sans exposition. |

Deux règles de comptage, à appliquer avant de publier une synthèse :

- **Un même défaut détecté par deux méthodes ne compte qu'une fois.** Sinon il
  pèse double dans le total et peut décider seul d'un feu vert ou rouge.
- **Un scénario d'attaque n'est pas une vulnérabilité supplémentaire.** Une chaîne
  qui combine trois constats existants se présente comme scénario, avec renvoi aux
  identifiants concernés, et ne se recompte pas.

(Pour la relecture d'un rapport déjà produit, y compris par un outil automatisé,
voir le skill `security-audit-review`.)

## Tableau d'écart politique / réalité

À inclure systématiquement quand l'hôte fait tourner des conteneurs : c'est le
tableau que le client ne peut pas produire lui-même.

| Port | Écoute (hôte) | Politique déclarée | Mesuré depuis l'extérieur | Écart |
|---|---|---|---|---|
| 22 | 0.0.0.0 | autorisé | ouvert | conforme |
| 443 | 0.0.0.0 | autorisé | ouvert | conforme |
| 5432 | 0.0.0.0 (conteneur) | non autorisé | **ouvert** | contournement |
| 6379 | 127.0.0.1 | non autorisé | fermé | conforme |

## Statut des protections

| Protection | Chemin protégé | Contournement possible | Statut |
|---|---|---|---|
| Reverse proxy durci | 443 → application | port 8069 direct exposé | **préparée, inerte** |
| Bannissement automatique | authentification SSH | — | active (compteurs vérifiés) |
| Pare-feu hôte | trafic non conteneurisé | conteneurs hors chaîne | **partielle** |

Une protection inerte ne figure jamais dans la colonne des mesures en place. Le
statut « préparée » n'est pas une nuance de langage : c'est la différence entre un
serveur protégé et un serveur qui semble l'être.

## Section « ce que cet audit ne conclut pas »

Obligatoire. Un rapport qui n'énumère pas ses angles morts affirme davantage qu'il
n'a vérifié.

```
Méthodes employées : inventaire système en lecture seule, configuration
effective des services et conteneurs, privilèges des comptes de base de
données, mesure d'exposition depuis l'extérieur, journaux d'authentification
sur 90 jours, couche inscriptible des conteneurs.

Méthodes NON employées : analyse mémoire, comparaison d'empreintes avec les
paquets d'origine (outil non présent, non installé pour rester en lecture
seule), observation dynamique sur un cycle complet, inspection des
enregistrements applicatifs évalués comme du code, test d'intrusion applicatif.

En conséquence, ce rapport constate l'absence d'indicateurs pour les méthodes
employées. Il ne conclut pas à l'absence de compromission.
```

## Fiche serveur (onboarding dans un parc)

Quand l'audit sert à intégrer un serveur dans un parc documenté, produire en plus
une fiche au format du parc. Champs minimaux :

```
Hôte / adresses (publique, privée)  |  Accès : méthode, comptes, qui détient les clés
OS et version, noyau, redémarrage en attente  |  Horloge (dérive constatée, UTC)
Services exposés (port, processus, publié par)  |  Ports mesurés ouverts depuis l'extérieur
Conteneurs (nom, image + digest, volumes, redémarrage)
Bases de données (moteur, version, comptes, privilèges)
Sauvegardes (emplacement, chiffrement, dernière vérifiée)
Journalisation (quoi, où, rétention)
Date de collecte (UTC), auteur, méthode
```

La date de collecte en UTC n'est pas cosmétique : une fiche sans horodatage
propre n'est pas corrélable avec les journaux d'un incident ultérieur, et devient
progressivement un document dont personne ne sait s'il décrit encore le serveur.

## Livraison

Le rapport en prose passe par un outil d'écriture de fichier, jamais par un
heredoc shell : au-delà de quelques dizaines de lignes contenant apostrophes,
accents, backticks et tableaux, une couche de quoting finit par corrompre le
contenu — et l'échec survient après que tout le travail de composition a été fait,
donc à coût maximal.

Ne pas inclure de valeur secrète dans le rapport, même pour illustrer un constat :
citer l'emplacement et la nature, jamais la valeur. Un rapport d'audit circule
plus largement et plus longtemps que le serveur qu'il décrit.
