# Scan d'image et de configuration

Toutes les commandes ci-dessous ont été exécutées et leur sortie inspectée. Les
outils sont invoqués par conteneur : aucune installation locale n'est nécessaire,
et la version utilisée est explicite.

## Piège d'environnement à connaître avant tout

Sous Git Bash / MSYS sur Windows, la couche de compatibilité réécrit les arguments
qui ressemblent à un chemin absolu POSIX. `-v "$PWD:/src" ... /src` devient
`C:/Program Files/Git/src` côté conteneur, et le scan analyse un répertoire de
l'hôte qui n'existe pas :

```
FATAL Fatal error run error: fs scan error: ... unknown error with C:/Program Files/Git/src: no such file or directory
```

Deux neutralisations, au choix :

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/src" aquasec/trivy:latest config /src
docker run --rm -v "$PWD://src" aquasec/trivy:latest config //src   # double barre oblique
```

Sous Linux, macOS et PowerShell, la commande sans préfixe fonctionne telle quelle.

## 1. Lint du Dockerfile — hadolint

```bash
docker run --rm -i hadolint/hadolint:latest-alpine < Dockerfile
```

Pas de montage, donc aucun piège de conversion de chemin. Sortie type :

```
-:4 DL3008 warning: Pin versions in apt get install. Instead of `apt-get install <package>` use `apt-get install <package>=<version>`
```

Règles à ne jamais ignorer : `DL3002` (dernier `USER` est root), `DL3004` (`sudo`),
`DL3020` (`ADD` au lieu de `COPY` — `ADD` télécharge une URL et décompresse une
archive, donc exécute une opération sur une donnée distante), `DL3025` (forme shell
de `CMD`, qui empêche la propagation de `SIGTERM`), `DL4006` (absence de
`pipefail`, qui masque l'échec d'une commande dans un tube).

Règles fréquemment neutralisées après décision explicite : `DL3008`/`DL3018`
(épinglage des paquets système). L'ignorer se fait dans le fichier, avec un motif :

```dockerfile
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates
```

## 2. Mauvaises configurations — trivy config

Analyse les Dockerfile, fichiers compose, manifestes Kubernetes, Terraform et
CloudFormation d'un répertoire :

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/src" aquasec/trivy:latest config /src
```

Sortie réelle sur un projet non durci :

```
Dockerfile (dockerfile)
Tests: 27 (SUCCESSES: 25, FAILURES: 2)
Failures: 2 (LOW: 1, HIGH: 1)

DS-0002 (HIGH): Specify at least 1 USER command in Dockerfile with non-root user as argument
DS-0026 (LOW): Add HEALTHCHECK instruction in your Dockerfile
```

`DS-0002` correspond à la règle 3 du skill et se corrige toujours. Bloquer la CI
au-delà d'un seuil :

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/src" aquasec/trivy:latest config \
  --severity HIGH,CRITICAL --exit-code 1 /src
```

### Avertissement à lire, pas seulement le tableau final

Derrière une interception TLS d'entreprise, le téléchargement du paquet de règles
échoue et l'outil bascule sur ses règles embarquées :

```
ERROR [misconfig] Falling back to embedded checks err="failed to download checks bundle: ... x509: certificate signed by unknown authority"
```

Le scan se poursuit, sort en succès, avec une couverture réduite. Le correctif est
d'injecter le certificat de l'autorité interne dans le conteneur :

```bash
docker run --rm \
  -v "$PWD:/src" -v "/chemin/ca-entreprise.crt:/usr/local/share/ca-certificates/ca.crt:ro" \
  --entrypoint sh aquasec/trivy:latest -c "update-ca-certificates && trivy config /src"
```

Jamais désactiver la vérification TLS pour faire passer le scan : un message
d'erreur qui suggère son propre contournement n'est pas une autorisation de le
prendre.

## 3. Vulnérabilités et secrets de l'image construite

```bash
docker build -t app:audit .

MSYS_NO_PATHCONV=1 docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --scanners vuln,secret --severity HIGH,CRITICAL app:audit
```

Le montage du socket Docker est nécessaire pour que le scanner lise l'image du
démon local. Le faire uniquement en local ou dans un exécuteur de CI dédié —
jamais dans un service exposé.

Variante sans socket (via une archive) :

```bash
docker save app:audit -o /tmp/app.tar
MSYS_NO_PATHCONV=1 docker run --rm -v /tmp:/tmp aquasec/trivy:latest image --input /tmp/app.tar
```

Interprétation : distinguer les vulnérabilités **corrigeables** (`--ignore-unfixed`
les masque) des autres. Une image dont les paquets système traînent des CVE non
corrigées signale surtout une image de base périmée : la solution est de mettre à
jour la base, pas de filtrer le rapport.

## 4. Secrets dans l'historique des couches

```bash
docker history --no-trunc app:audit | grep -iE 'secret|token|password|api[_-]?key|BEGIN .*PRIVATE'
```

Aucune sortie = aucune valeur secrète dans les métadonnées de construction. Ce
contrôle attrape le motif `ARG TOKEN` / `ENV TOKEN=$TOKEN`, que le lint ne voit pas.

Contrôle complémentaire sur le contenu du système de fichiers :

```bash
docker run --rm --entrypoint sh app:audit -c 'ls -la /app; test -d /app/.git && echo "FUITE .git"'
```

## 5. Vérifier l'utilisateur d'exécution réel

```bash
docker run --rm --entrypoint id app:audit
# attendu : uid=10001 gid=10001
```

C'est le seul contrôle qui prouve la règle « non-root ». Une instruction `USER`
peut être annulée par un `ENTRYPOINT` qui rebascule, par `user: root` dans compose,
ou par un orchestrateur. Interroger l'objet, pas le fichier source.

Vérifier aussi sur le conteneur en fonctionnement, qui est ce qui compte :

```bash
docker compose exec app id
docker inspect --format '{{.Config.User}} | ro={{.HostConfig.ReadonlyRootfs}} | priv={{.HostConfig.Privileged}} | capdrop={{.HostConfig.CapDrop}}' <conteneur>
```

## 6. SBOM et signature (chaîne d'approvisionnement)

```bash
# Nomenclature logicielle au format CycloneDX
MSYS_NO_PATHCONV=1 docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --format cyclonedx --output /tmp/sbom.json app:audit

# Signature sans clé (identité OIDC de la CI)
COSIGN_EXPERIMENTAL=1 cosign sign registry.exemple.tld/app@sha256:<digest>
cosign verify registry.exemple.tld/app@sha256:<digest>
```

La SBOM sert à répondre « suis-je exposé ? » lors de la publication d'une CVE, sans
reconstruire l'image. La signature sert à garantir que ce qui est déployé vient
bien de la CI. Signer par digest, jamais par tag : un tag est réattribuable.

## 7. Intégration en CI

Le détail des pipelines est dans le skill `secure-cicd`. Le principe minimal :

- Le lint et le scan de configuration bloquent au niveau `HIGH` dès la merge request.
- Le scan de vulnérabilités de l'image tourne sur l'image effectivement construite,
  avant publication au registre, et bloque sur `CRITICAL`.
- Les résultats sont publiés comme artefact, pas seulement affichés dans les logs :
  un journal expire, un artefact se compare d'une exécution à l'autre.
- Un scan planifié hebdomadaire sur les images déjà publiées détecte les CVE
  découvertes après la construction — c'est le seul moyen de les voir.

## Ordre de traitement d'un rapport

1. Secret trouvé dans une couche ou dans l'historique — traiter comme une fuite :
   rotationner la valeur, puis corriger le build.
2. Exécution en root, `privileged`, socket Docker monté.
3. Vulnérabilités `CRITICAL` corrigeables sur un composant atteignable depuis le
   réseau.
4. Base de l'image périmée (souvent la cause commune de tout le bloc précédent).
5. Absence de `HEALTHCHECK`, épinglage des paquets, taille de l'image.
