# Skills de sécurité pour Claude Code

Six skills qui font écrire du code, des conteneurs, de l'infrastructure et des
pipelines **sécurisés par défaut** — et qui vérifient l'effet obtenu, pas
l'intention déclarée.

Écrits par **Tahina Fabien**. Licence [CC BY 4.0](LICENSE).

---

## Pourquoi

La plupart des guides de sécurité listent des règles. Le problème n'est presque
jamais l'ignorance de la règle : c'est **l'écart entre une protection déclarée et
une protection effective**.

Ces skills sont construits autour de cet écart. Chaque règle y est accompagnée du
contrôle qui prouve qu'elle s'applique réellement. Quelques exemples tirés
d'incidents réels qui ont servi de matière première :

| Ce qui était déclaré | Ce qui était vrai |
|---|---|
| Pare-feu en `deny incoming`, seuls 22/80/443 ouverts | Six services conteneurisés joignables depuis Internet — le trafic ne traversait pas la chaîne où la politique était écrite |
| Instruction `USER` présente dans le Dockerfile | Conteneur en root : `ENTRYPOINT` qui rebascule, ou `user:` dans le fichier compose |
| Rotation du mot de passe administrateur faite | Les variables d'environnement ne sont lues qu'à la première initialisation — l'identifiant d'usine restait valide |
| Bannissement automatique actif, IP bloquées | Règles écrites dans une chaîne que le trafic ne traverse pas ; compteurs de paquets à zéro |
| Rapport d'audit : 2 vulnérabilités « ÉLEVÉ » | Le même faux positif compté deux fois — et c'est ce doublon qui décidait du feu vert de mise en production |
| Limitation de débit configurée sur la route de connexion | Toutes les requêtes portaient l'IP du proxy : la limitation existait et ne protégeait rien |

D'où le principe commun aux six skills :

> **Interroger l'objet, pas le fichier source.** Un contrôle se vérifie par son
> effet observable, jamais par la présence du mot-clé attendu dans une
> configuration.

## Pour qui

- **Développeurs** qui utilisent Claude Code et veulent que le code produit soit
  correct côté sécurité *dès la première écriture*, sans repasser derrière.
- **Équipes DevOps / SRE** qui écrivent des Dockerfile, du Terraform et des
  pipelines, et veulent des gabarits durcis plutôt que des exemples de
  documentation.
- **Auditeurs et prestataires** qui interviennent sur des serveurs tiers et ont
  besoin d'une frontière nette entre constat et intervention.
- **Tech leads** qui reçoivent des rapports d'audit automatisés et doivent
  décider quoi corriger — et quoi écarter, avec justification.

Aucun prérequis d'expertise sécurité. Les skills contiennent le raisonnement, pas
seulement la conclusion.

## Les six skills

| Skill | Se déclenche quand | Contient |
|---|---|---|
| **[secure-coding](secure-coding/)** | On écrit du code touchant une entrée utilisateur, une authentification, une base, un upload, un secret, un log | 14 règles + références Node.js/Express, React/Next.js, Python, PHP, Java, et une grille de revue |
| **[secure-docker](secure-docker/)** | On écrit ou modifie un Dockerfile, un `docker-compose.yml`, un `.dockerignore` | 12 règles + gabarits multi-étapes durcis (5 stacks), durcissement compose, commandes de scan vérifiées |
| **[secure-terraform](secure-terraform/)** | On crée ou modifie un `.tf`, un backend, une config de provider, ou on prépare un `apply` | 12 règles + état/secrets, contrôles AWS, GCP, Azure, scan et pipeline |
| **[secure-cicd](secure-cicd/)** | On écrit un pipeline, une variable de CI, une étape de déploiement | 12 règles + GitLab CI, GitHub Actions, chaîne d'approvisionnement (SBOM, signature, épinglage) |
| **[server-security-audit](server-security-audit/)** | On audite un serveur en fonctionnement, on répond à un incident, on intègre un serveur dans un parc | 8 principes de vérification + 7 phases : reconnaissance, exposition, config effective, privilèges, compromission, remédiation, restitution |
| **[security-audit-review](security-audit-review/)** | Un rapport d'audit (SAST, SCA, scan, pentest) arrive et doit être traité | Workflow 7 phases : instruire, dédupliquer, valider la remédiation, recalculer le score + 10 motifs de faux positifs |

Ils se chargent seuls, à la demande, selon la tâche en cours. Rien à invoquer
manuellement.

---

## Installation

Un skill Claude Code est un répertoire contenant un `SKILL.md`. L'installation
consiste à placer ce répertoire au bon endroit.

### Portée globale — disponible dans tous vos projets

```bash
git clone https://github.com/txRandria/skills.git
cd skills

# Linux / macOS
./install.sh

# Windows (PowerShell)
.\install.ps1
```

Le script copie les six répertoires dans `~/.claude/skills/`
(`%USERPROFILE%\.claude\skills\` sous Windows).

### Portée projet — partagée avec l'équipe par git

Plus utile en équipe : les skills suivent le dépôt, chaque personne qui clone les
obtient.

```bash
mkdir -p .claude/skills
cp -r /chemin/vers/skills/secure-* .claude/skills/
git add .claude/skills && git commit -m "chore: skills de sécurité"
```

Ou en sous-module, pour recevoir les mises à jour :

```bash
git submodule add https://github.com/txRandria/skills.git .claude/skills
```

### Installation manuelle

```bash
cp -r secure-coding secure-docker secure-terraform secure-cicd \
      server-security-audit security-audit-review ~/.claude/skills/
```

### Vérifier l'installation

Dans Claude Code :

```
/skills
```

Les six doivent apparaître avec leur description complète. Si un skill s'affiche
avec un nom court au lieu de sa description, son en-tête YAML est cassé — voir
« Fins de ligne » plus bas.

---

## Utilisation

### Le cas normal : ne rien faire

Les skills se déclenchent sur le contexte de la tâche. Écrivez votre demande
habituelle :

```
Ajoute un endpoint de téléchargement de document
   -> secure-coding se charge : autorisation sur l'objet, path traversal, en-têtes

Écris-moi un Dockerfile pour cette app Node
   -> secure-docker se charge : multi-étapes, non-root, digest, .dockerignore

Prépare le module Terraform pour la base de données
   -> secure-terraform se charge : chiffrement, réseau fermé, secrets hors état

Audite ce serveur, j'ai un accès SSH
   -> server-security-audit se charge : phases lecture seule, exposition mesurée
```

### Invocation explicite

Quand vous voulez forcer un skill précis :

```
/secure-docker durcis le Dockerfile existant
/security-audit-review traite le rapport rapport-audit.md
```

### Ce qu'un skill fait concrètement

Chaque `SKILL.md` est court : les règles non négociables, une table de routage
vers les références, et une **liste de contrôle avant livraison**. Les références
(gabarits, batteries de commandes, contrôles par langage ou par cloud) ne sont
chargées qu'au moment où elles servent — le coût en contexte reste faible.

La liste de contrôle est la partie qui compte. Une règle écrite dans un document
n'est pas une règle appliquée : chaque skill se termine par une vérification
exécutable, à faire passer sur le code réellement produit.

### Exemple de sortie — `secure-docker`

```bash
# Commandes vérifiées, sortie inspectée sur un projet réel
docker run --rm -i hadolint/hadolint:latest-alpine < Dockerfile
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/src" aquasec/trivy:latest config /src
docker run --rm --entrypoint id app:audit        # prouve le non-root
docker history --no-trunc app:audit | grep -i secret   # prouve l'absence de fuite
```

Le troisième contrôle est le seul qui prouve réellement la règle « non-root » :
une instruction `USER` peut être annulée en aval. C'est la logique de tout le
dépôt.

---

## Choix de conception

**Toute commande embarquée a été exécutée avant d'être écrite.** Un extrait de
code dans un skill s'exécute verbatim, indéfiniment, sans relecture. Les
commandes de ce dépôt ont été lancées contre des cibles réelles et leurs sorties
inspectées — pas seulement leur code de retour, qui peut valoir zéro après qu'un
scanner a silencieusement dégradé sa couverture.

**Aucun identifiant, aucun digest, aucun SHA inventé.** Là où un digest d'image ou
un SHA de commit est nécessaire, le skill donne la commande qui le résout, avec le
piège associé (un tag annoté ne pointe pas sur un commit).

**Versions ancrées.** Chaque skill commence par lire le manifeste du projet avant
de produire un extrait : Express 4 ≠ Express 5, Spring Boot 2 ≠ 3, Pages Router ≠
App Router. Un extrait non ancré à une version est un motif, pas une
implémentation.

**Constat et intervention séparés.** Pour les skills d'audit, la collecte est
strictement en lecture seule et la remédiation est une phase distincte, validée.
Une correction appliquée pendant la collecte rend impossible de distinguer ce qui
a été observé de ce qui a été changé — et, sur un serveur compromis, détruit les
traces.

---

## Fins de ligne (important)

Les `SKILL.md` doivent être en **LF**. Un `\r` en fin de ligne casse l'analyse de
l'en-tête YAML : le skill se charge mais perd sa description, donc son
déclenchement automatique.

Le dépôt contient un `.gitattributes` qui force LF sur les fichiers Markdown. Si
vous éditez sous Windows, vérifiez :

```bash
grep -c $'\r' */SKILL.md      # doit renvoyer 0 partout
```

---

## Contribuer

Les retours sur la **méthodologie** sont les plus utiles : un cas où une règle ne
s'applique pas, un contrôle qui produit un faux négatif, un mécanisme non couvert.
Ouvrir une issue avec le contexte concret plutôt qu'une suggestion générale.

Si un skill produit une mauvaise sortie parce que l'agent n'a pas suivi ses
propres règles, ce n'est pas un défaut du skill — c'est un défaut d'application,
à corriger dans la session.

## Licence

[CC BY 4.0](LICENSE) — partage et adaptation libres, y compris commerciaux, avec
attribution.
