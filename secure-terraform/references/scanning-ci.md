# Validation, scan et pipeline Terraform

## Chaîne locale minimale

```bash
terraform fmt -recursive -check -diff
terraform init -backend=false        # valide sans toucher au backend distant
terraform validate
```

`-backend=false` permet de valider la syntaxe et les références sans identifiants
cloud ni accès à l'état — c'est ce qui rend l'étape utilisable sur toute merge
request, y compris depuis un fork.

## Scan de configuration

```bash
# trivy — couvre Terraform, Dockerfile, compose, Kubernetes dans le même passage.
# MSYS_NO_PATHCONV=1 est requis sous Git Bash/MSYS, sinon /src est réécrit en
# chemin hôte et le scan analyse le mauvais dossier (voir secure-docker).
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/src" aquasec/trivy:latest config \
  --severity HIGH,CRITICAL --exit-code 1 /src

# checkov — règles plus nombreuses, sortie plus verbeuse
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/src" bridgecrew/checkov:latest \
  -d /src --compact --quiet --framework terraform

# tflint — erreurs de configuration et attributs invalides du provider
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/data" -t ghcr.io/terraform-linters/tflint
```

Les trois ne se recouvrent pas : `tflint` attrape les valeurs invalides et les
attributs dépréciés, `trivy config` et `checkov` attrapent les configurations
dangereuses. Deux suffisent en pratique ; en choisir deux et les rendre bloquants
vaut mieux qu'en lancer quatre en mode informatif.

### Scanner le plan plutôt que le code

Le code seul ne voit pas ce que produisent les valeurs de variables et les modules
distants. Scanner le plan rendu couvre l'infrastructure réellement demandée :

```bash
terraform plan -out=tfplan
terraform show -json tfplan > tfplan.json
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/src" aquasec/trivy:latest config /src/tfplan.json
```

`tfplan` et `tfplan.json` contiennent des valeurs sensibles : les traiter comme
l'état — artefact à accès restreint, jamais commité, expiration courte.

## Neutraliser une règle : avec un motif, jamais en masse

```hcl
#trivy:ignore:AVD-AWS-0089 Journalisation d'accès assurée par CloudTrail data events
resource "aws_s3_bucket" "documents" { ... }
```

```hcl
#checkov:skip=CKV_AWS_18:Journalisation centralisée au niveau du compte
```

Une exclusion globale par fichier de configuration masque aussi les occurrences
futures dans du code pas encore écrit. Une exclusion en ligne se relit dans le
diff, porte sa justification, et disparaît avec la ressource.

## Détection de secrets

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
  detect --source /repo --redact --no-banner
```

Sur l'historique complet, pas seulement sur l'arbre de travail : un secret retiré
de `HEAD` reste dans les commits antérieurs.

## Pipeline GitLab CI

```yaml
stages: [valider, scanner, planifier, appliquer]

variables:
  TF_ROOT: envs/prod
  TF_IN_AUTOMATION: "true"

default:
  image:
    name: hashicorp/terraform:1.9
    entrypoint: [""]
  before_script:
    - cd "$TF_ROOT"

# Fédération d'identité : aucun identifiant cloud à longue durée en variable de CI.
.aws_oidc: &aws_oidc
  id_tokens:
    AWS_ID_TOKEN:
      aud: https://gitlab.exemple.tld
  before_script:
    - cd "$TF_ROOT"
    - echo "$AWS_ID_TOKEN" > /tmp/web_identity_token
    - export AWS_ROLE_ARN="$AWS_ROLE_ARN"
    - export AWS_WEB_IDENTITY_TOKEN_FILE=/tmp/web_identity_token

format:
  stage: valider
  script:
    - terraform fmt -recursive -check -diff
    - terraform init -backend=false
    - terraform validate

scan:
  stage: scanner
  image:
    name: aquasec/trivy:latest
    entrypoint: [""]
  script:
    - trivy config --severity HIGH,CRITICAL --exit-code 1 --format table "$TF_ROOT"
  artifacts:
    when: always
    reports:
      # Publié comme rapport, pas seulement affiché : un journal expire.
      terraform: "$TF_ROOT/rapport.json"

plan:
  <<: *aws_oidc
  stage: planifier
  script:
    - terraform init -backend-config=backend.hcl
    - terraform plan -out=tfplan -input=false
    - terraform show -json tfplan > tfplan.json
    - |
      echo "Ressources détruites ou remplacées :"
      terraform show -json tfplan | grep -o '"actions":\["delete"[^]]*\]' | wc -l
  artifacts:
    paths: [ "$TF_ROOT/tfplan" ]
    expire_in: 1 day        # le plan contient des valeurs sensibles
  rules:
    - if: $CI_PIPELINE_SOURCE == 'merge_request_event'
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

apply:
  <<: *aws_oidc
  stage: appliquer
  script:
    - terraform init -backend-config=backend.hcl
    - terraform apply -input=false tfplan   # applique le plan approuvé, pas un nouveau
  environment:
    name: production        # protection d'environnement + approbation requise
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      when: manual          # jamais automatique en production
  resource_group: terraform-prod   # sérialise les apply concurrents
```

Points structurants :

- `apply tfplan` applique **le plan relu**. Un `apply` sans fichier de plan
  recalcule et peut appliquer autre chose que ce qui a été approuvé.
- `when: manual` + `environment: production` place une approbation humaine et un
  journal de déploiement entre le code et l'infrastructure.
- `resource_group` empêche deux `apply` simultanés — complémentaire du verrou de
  l'état, il agit avant même l'acquisition du verrou.
- L'artefact de plan expire vite : c'est un fichier sensible.

## Pipeline GitHub Actions

```yaml
name: terraform

on:
  pull_request:
    paths: ['envs/**', 'modules/**']
  push:
    branches: [main]

# Permissions minimales au niveau du workflow, élargies par job si nécessaire.
permissions:
  contents: read

concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: false        # ne jamais annuler un apply en cours

jobs:
  plan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write              # requis pour l'OIDC
      pull-requests: write         # pour commenter le plan
    steps:
      # Actions épinglées par SHA complet : un tag est réattribuable.
      # Résoudre le SHA : gh api repos/actions/checkout/git/ref/tags/v4 --jq .object.sha
      - uses: actions/checkout@<sha-complet>   # v4.2.2

      - uses: aws-actions/configure-aws-credentials@<sha-complet>   # v4.0.2
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: eu-west-3
          # Aucune clé d'accès : le jeton OIDC du job est échangé contre des
          # identifiants temporaires.

      - uses: hashicorp/setup-terraform@<sha-complet>
        with:
          terraform_version: 1.9.8

      - run: terraform init -backend-config=backend.hcl
        working-directory: envs/prod
      - run: terraform plan -out=tfplan -input=false
        working-directory: envs/prod

  apply:
    needs: plan
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: production        # règles de protection : approbateurs requis
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@<sha-complet>
      - uses: aws-actions/configure-aws-credentials@<sha-complet>
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: eu-west-3
      - run: terraform apply -input=false -auto-approve
        working-directory: envs/prod
```

Ne jamais utiliser `pull_request_target` pour un pipeline Terraform : ce
déclencheur exécute le workflow du dépôt cible avec les secrets du dépôt, sur du
code venant d'une contribution externe.

## Lecture du plan avant approbation

Le contrôle le plus utile n'est pas automatisable : quelqu'un lit le plan.

```bash
terraform show -json tfplan | jq -r '
  .resource_changes[]
  | select(.change.actions | inside(["delete","create"]) | not)
  | "\(.change.actions | join("+")) \(.address)"' | sort | uniq -c
```

Trois questions, dans l'ordre :

1. Quelles ressources sont **détruites ou remplacées** ? Un remplacement de base
   de données, de volume ou de clé de chiffrement est une perte de données jusqu'à
   preuve du contraire.
2. Quelles règles **réseau ou IAM** s'élargissent ? Chercher `0.0.0.0/0`, `"*"`,
   `allUsers`, `Contributor`.
3. Le nombre de changements correspond-il à l'intention annoncée ? Un plan de
   40 changements pour « ajouter une étiquette » signale une dérive ou un
   changement de version de provider — dans ce cas, ne pas appliquer : traiter la
   dérive d'abord.

Ne jamais déplacer la ligne de base et la configuration dans la même révision : si
le provider change de version **et** que la configuration change, un défaut n'est
attribuable à aucun des deux.

## Dérive

```bash
terraform plan -detailed-exitcode -refresh-only
# 0 = pas de dérive, 2 = dérive détectée, 1 = erreur
```

À exécuter en tâche planifiée quotidienne. Une dérive persistante signale soit une
modification manuelle en production, soit une ressource gérée à deux endroits —
les deux sont des problèmes de sécurité avant d'être des problèmes de propreté.
