---
name: secure-docker
description: Générer ou durcir un Dockerfile, un docker-compose.yml ou une image de conteneur en respectant les exigences de sécurité — utilisateur non-root, build multi-étapes, base épinglée par digest, absence de secret dans les couches, capacités restreintes, système de fichiers en lecture seule, limites de ressources, scan de l'image. À utiliser dès qu'on écrit, modifie ou audite un Dockerfile, un fichier compose, un .dockerignore ou une configuration d'exécution de conteneur. Ne pas utiliser pour Kubernetes ni pour l'infrastructure cloud : voir secure-terraform.
---

# Secure Docker

**Créé par Tahina Fabien**

Skill open-source. Il fixe les exigences de sécurité d'une image de conteneur et
de son exécution, et fournit les gabarits et commandes de vérification associés.

**Licence :** CC BY 4.0 — partage et adaptation libres avec attribution.

**Retours :** si la méthodologie pose question ou si un retour constructif est
formulé sur une sortie produite par ce skill, le consigner et proposer de le
partager avec l'auteur. Si le problème vient de l'agent qui n'a pas suivi les
règles du skill, le reconnaître et corriger.

**Dépôt :** https://github.com/txRandria/skills — signaler un problème de méthodologie via une issue publique bénéficie à tous les utilisateurs du skill.

---

## Étape 0 — lire le contexte avant d'écrire

```bash
ls -la Dockerfile* docker-compose*.y*ml .dockerignore 2>/dev/null
cat package.json 2>/dev/null || cat pyproject.toml requirements.txt 2>/dev/null || cat composer.json 2>/dev/null || cat pom.xml 2>/dev/null | head -30
```

Un Dockerfile existant se **modifie**, il ne se réécrit pas : l'écraser détruit des
contraintes de build souvent non documentées (dépendance système d'une compilation
native, ordre des couches réglé pour le cache, chemin attendu par un orchestrateur).
Lire avant d'écrire, y compris — surtout — quand le fichier n'est pas suivi par git.

## Les 12 règles non négociables

1. **Build multi-étapes.** La chaîne de compilation (compilateurs, en-têtes,
   gestionnaires de paquets de développement, sources) ne doit pas exister dans
   l'image finale. Elle en multiplie la taille et la surface d'attaque, et y
   laisse des outils utiles à un attaquant qui obtient une exécution.

2. **Base épinglée par digest, jamais `latest`.** `FROM node:22-bookworm-slim` est
   un objectif mouvant : deux builds à deux dates donnent deux images différentes.
   Épingler `image:tag@sha256:...` rend le build reproductible et la version
   auditable. Mettre à jour le digest est alors un changement explicite, visible en
   revue.

3. **Utilisateur non-root, avec un UID numérique fixe.** Sans `USER`, le processus
   tourne en root : une évasion de conteneur ou un montage mal configuré devient
   une compromission de l'hôte. `USER 10001` (numérique) plutôt qu'un nom : les
   contrôles d'admission et `runAsNonRoot` savent évaluer un UID, pas un nom résolu
   dans `/etc/passwd`.

4. **Aucun secret dans une couche, un `ARG` ou un `ENV`.** Toute valeur passée par
   `ARG` ou écrite pendant le build reste lisible dans l'historique de l'image
   (`docker history`), même supprimée par une instruction ultérieure. Les secrets
   de build passent par `RUN --mount=type=secret` (BuildKit) ; les secrets
   d'exécution par une variable injectée au démarrage ou un fichier monté.

5. **`.dockerignore` avant tout `COPY`.** Sans lui, `COPY . .` embarque `.git`
   (donc tout l'historique, donc tout secret jamais commité), `.env`,
   `node_modules` de l'hôte, les clés SSH d'un dossier oublié. C'est le vecteur de
   fuite de secret le plus courant dans les images.

6. **Installation reproductible, dépendances de production seules.**
   `npm ci --omit=dev`, `composer install --no-dev`, `pip install --require-hashes`,
   `mvn -DskipTests package`. Nettoyer le cache du gestionnaire de paquets dans la
   **même** instruction `RUN` que l'installation — une couche suivante ne réduit
   pas la taille des couches précédentes.

7. **Image de base minimale.** Par ordre de surface d'attaque croissante :
   `distroless` / `scratch` < `alpine` < `-slim` < distribution complète. Une image
   sans shell empêche l'exécution interactive après compromission. Choisir la plus
   petite compatible avec le runtime (les binaires compilés contre la glibc ne
   fonctionnent pas sur Alpine, qui utilise musl).

8. **`HEALTHCHECK` défini.** Sans lui, un conteneur dont le processus est vivant
   mais le service bloqué reste marqué « en fonctionnement », et l'orchestrateur
   continue de lui router du trafic.

9. **Aucun port exposé plus large que nécessaire.** Un service derrière un reverse
   proxy ne publie pas de port sur l'hôte : il rejoint le proxy par un réseau
   interne. `ports: ["3000:3000"]` publie sur **toutes** les interfaces de l'hôte,
   pare-feu compris sur certaines configurations Docker — écrire
   `127.0.0.1:3000:3000` quand la publication est nécessaire en local.

10. **Système de fichiers racine en lecture seule.** `read_only: true` avec des
    `tmpfs` pour les chemins réellement inscriptibles. Un conteneur qui ne peut
    rien écrire hors de ses volumes déclarés bloque l'installation d'outils par un
    attaquant et rend l'état persistant explicite.

11. **Capacités retirées, élévation interdite.** `cap_drop: [ALL]` puis rajout
    explicite des capacités nécessaires (généralement aucune), plus
    `security_opt: [no-new-privileges:true]` qui empêche un binaire setuid de
    regagner des privilèges. Jamais `privileged: true`, jamais de montage du socket
    Docker (`/var/run/docker.sock`) : c'est l'équivalent d'un accès root à l'hôte.

12. **Limites de ressources.** Un conteneur sans limite de mémoire ou de CPU permet
    à un défaut applicatif — ou à une requête malveillante — de faire tomber tous
    les autres services de l'hôte.

## Gabarits

Charger le gabarit correspondant à la stack, ne pas le réécrire de mémoire.

| Fichier | Contenu |
|---|---|
| `references/dockerfile-templates.md` | Dockerfiles multi-étapes durcis : Node.js, Python, PHP-FPM, Java, front statique (nginx) |
| `references/compose-hardening.md` | `docker-compose.yml` durci, secrets, réseaux internes, healthcheck, reverse proxy, limites |
| `references/scanning.md` | Commandes de scan vérifiées (hadolint, trivy image/config/secret), intégration CI, interprétation des résultats |

## Contrôle avant livraison (obligatoire)

Ne pas se fier à la relecture : exécuter. Les deux commandes ci-dessous ont été
vérifiées, sortie inspectée, sur un projet réel.

```bash
# 1. Lint du Dockerfile (l'image fait ~10 Mo, pas de montage donc pas de piège de chemin)
docker run --rm -i hadolint/hadolint:latest-alpine < Dockerfile

# 2. Mauvaises configurations Dockerfile + compose
#    MSYS_NO_PATHCONV=1 est OBLIGATOIRE sous Git Bash / MSYS sur Windows : sans lui
#    l'argument /src est réécrit en chemin hôte et le scan analyse le mauvais dossier
#    en sortant sur une erreur trompeuse.
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/src" aquasec/trivy:latest config /src

# 3. Secrets présents dans l'image construite
docker build -t app:audit .
MSYS_NO_PATHCONV=1 docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --scanners secret,vuln --severity HIGH,CRITICAL app:audit

# 4. L'image tourne-t-elle réellement en non-root ?
docker run --rm --entrypoint id app:audit
```

Le point 4 est le seul qui prouve la règle 3 : une instruction `USER` placée avant
un `ENTRYPOINT` qui rebascule en root, ou surchargée par `user:` dans compose, se
relit comme correcte et ne l'est pas. Demander à l'objet, pas au fichier source.

Liste à cocher, sur le fichier réellement livré :

- [ ] `FROM` épinglé par `@sha256:` sur chaque étape.
- [ ] Instruction `USER <uid numérique>` avant `CMD`/`ENTRYPOINT`, et `id` le confirme.
- [ ] `.dockerignore` présent et contenant au moins `.git`, `.env*`, `node_modules`, `*.pem`, `*.key`.
- [ ] `docker history --no-trunc app:audit | grep -iE 'secret|token|password|key'` ne renvoie rien.
- [ ] Aucune chaîne de compilation dans l'étape finale.
- [ ] `HEALTHCHECK` défini, et son échec observé au moins une fois (arrêter la dépendance, vérifier le passage en `unhealthy`).
- [ ] Compose : `read_only`, `cap_drop: [ALL]`, `no-new-privileges`, limites mémoire/CPU.
- [ ] Aucun port publié qui ne soit pas nécessaire depuis l'extérieur de l'hôte.
- [ ] Aucun `privileged: true`, aucun montage de `docker.sock`.
- [ ] Les volumes de données sont nommés et déclarés, pas des chemins hôte implicites.

## Note sur les scanners derrière un proxy d'entreprise

Un scanner peut échouer à télécharger son paquet de règles à cause d'une
interception TLS, **basculer silencieusement sur ses règles embarquées** et sortir
en succès avec une couverture réduite. Lire les lignes d'avertissement, pas
seulement le code de retour et le tableau final. Le correctif est d'injecter le
certificat de l'autorité d'entreprise dans le conteneur du scanner — jamais de
désactiver la vérification TLS.
