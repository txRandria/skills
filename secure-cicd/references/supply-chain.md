# Chaîne d'approvisionnement logicielle

Trois questions auxquelles une chaîne saine doit savoir répondre à tout moment :

1. **Qu'est-ce qui tourne exactement en production ?** — déploiement par digest.
2. **De quoi est-ce composé ?** — SBOM produite à la construction.
3. **Est-ce bien ce que notre CI a produit ?** — signature et vérification.

Sans ces trois réponses, la publication d'une vulnérabilité critique déclenche une
enquête manuelle de plusieurs heures au lieu d'une requête.

## 1. Épinglage — la règle transverse

| Objet | Forme mutable (à proscrire) | Forme épinglée |
|---|---|---|
| Action GitHub | `actions/checkout@v4` | `actions/checkout@11d5960a…` |
| Image de base | `node:22-slim` | `node:22-slim@sha256:…` |
| Image de déploiement | `app:latest` | `app@sha256:…` |
| Module Terraform | `ref=main` | `ref=v1.4.2` (ou empreinte) |
| Dépendance npm/pip/composer | plage de versions | fichier de verrouillage commité |
| Include GitLab CI | `ref: 'main'` | `ref: 'v1.4.2'` |

L'épinglage seul ne suffit pas : il fige aussi les vulnérabilités. Il exige un
mécanisme de mise à jour (Dependabot, Renovate) qui propose les montées de version
en merge request — révisables, traçables, réversibles.

## 2. Installation reproductible

```bash
npm ci                                    # échoue si package-lock.json diverge
pip install --require-hashes -r requirements.txt
composer install --no-dev --optimize-autoloader
mvn -B --strict-checksums package
```

`npm install`, `pip install <paquet>` et `composer update` résolvent les versions
au moment de l'exécution : deux constructions du même commit peuvent produire deux
artefacts différents. En CI et dans un Dockerfile, seule la forme reproductible est
acceptable.

`--require-hashes` (pip) et `--strict-checksums` (Maven) vérifient l'empreinte du
paquet téléchargé : c'est la protection contre la substitution en amont ou par un
miroir compromis.

### Confusion de dépendances

Un paquet interne dont le nom existe aussi sur le registre public peut être résolu
depuis le public. Contre-mesures :
- Préfixe d'organisation réservé (`@organisation/paquet`).
- Registre interne configuré comme unique source pour ce préfixe, sans repli
  automatique sur le registre public.
- Vérifier qu'aucun nom de paquet interne n'est disponible publiquement.

### Scripts d'installation

`npm ci` exécute les scripts `postinstall` des dépendances — du code arbitraire,
avec les droits du job. Sur un pipeline sensible :

```bash
npm ci --ignore-scripts
```

Puis exécuter explicitement les reconstructions natives nécessaires. Le compromis
est réel : certaines dépendances (better-sqlite3, sharp) ne fonctionnent pas sans
leur script. Le décider consciemment plutôt que par défaut.

## 3. SBOM

```bash
# À la construction, sur l'image réellement publiée
MSYS_NO_PATHCONV=1 docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --format cyclonedx --output sbom.json \
  registry.exemple.tld/app@sha256:<digest>

# Alternative : syft
MSYS_NO_PATHCONV=1 docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  anchore/syft:latest registry.exemple.tld/app@sha256:<digest> -o cyclonedx-json=sbom.json
```

La SBOM se conserve comme artefact durable (pas 24 heures), indexée par digest
d'image. Son usage réel : quand une vulnérabilité est publiée sur une bibliothèque,
répondre « quelles images déployées la contiennent, et dans quelle version » sans
rien reconstruire.

Générer la SBOM depuis l'**image**, pas depuis le code source : elle doit refléter
ce qui est déployé, dépendances transitives et paquets système compris.

## 4. Signature et vérification

```bash
# Signature sans clé, par l'identité OIDC du job — aucune clé privée à stocker
cosign sign --yes registry.exemple.tld/app@sha256:<digest>

# Attacher la SBOM comme attestation liée au digest
cosign attest --yes --predicate sbom.json --type cyclonedx \
  registry.exemple.tld/app@sha256:<digest>

# Vérification, en contraignant l'identité qui a signé
cosign verify \
  --certificate-identity-regexp 'https://gitlab\.exemple\.tld/mon-org/projets/mon-app.*' \
  --certificate-oidc-issuer https://gitlab.exemple.tld \
  registry.exemple.tld/app@sha256:<digest>
```

Les deux options `--certificate-identity-regexp` et `--certificate-oidc-issuer`
sont ce qui donne son sens à la vérification. Une vérification qui accepte
n'importe quelle identité confirme seulement que l'image est signée — par
n'importe qui.

Signer **par digest**, jamais par tag : la signature porte sur un contenu, et un
tag est réattribuable.

Côté déploiement, la vérification doit être imposée à l'admission (politique de
cluster, contrôleur d'admission, politique de registre), pas seulement exécutée
dans le pipeline : un contrôle qui vit uniquement dans la CI est contourné par
tout déploiement qui ne passe pas par la CI.

## 5. Détection de secrets sur l'historique

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
  detect --source /repo --redact --no-banner --report-path gitleaks.json
```

Deux modes, complémentaires :
- **detect** sur l'historique complet, en pipeline planifié : trouve ce qui a été
  commité par le passé.
- **protect** ou un hook de pré-commit : empêche la prochaine fuite.

Un secret trouvé dans l'historique impose la rotation, pas seulement la
suppression. Il est déjà dans tous les clones, dans les caches de la forge et
souvent dans les journaux de CI.

## 6. Protection des artefacts et du registre

- Tags immuables au registre : un tag publié ne peut plus être réécrit.
- Rétention : purger les images non déployées, mais conserver celles référencées
  par un déploiement en cours.
- Aucun artefact de CI contenant un secret, un plan Terraform ou un fichier
  d'état ne se conserve au-delà de quelques jours, ni ne devient public.
- Accès au registre par identité, pas par clé partagée ; écriture réservée aux
  jobs de construction sur branche protégée.

## 7. Contrôles périodiques, indispensables

Le scan à la construction ne voit que les vulnérabilités connues **ce jour-là**.
Une image parfaitement propre à sa publication devient vulnérable sans qu'aucun
commit n'ait eu lieu.

```yaml
# Pipeline planifié hebdomadaire : rescan des images déployées
on:
  schedule:
    - cron: '0 6 * * 1'
```

À rescanner : les images actuellement déployées (par digest), et non la dernière
image construite. C'est le seul contrôle qui détecte une CVE publiée après la
livraison.

## 8. Le pipeline lui-même est du code sensible

- `.github/workflows/`, `.gitlab-ci.yml` et les fichiers Terraform sont couverts
  par `CODEOWNERS` avec revue obligatoire de l'équipe infrastructure.
- Une modification de pipeline dans une merge request applicative est un signal :
  la traiter comme un changement de sécurité, pas comme un détail d'intégration.
- Les includes et templates distants sont épinglés par référence fixe : sans cela,
  le pipeline exécuté peut changer sans qu'aucun commit n'apparaisse dans le dépôt.

## Ce qu'un pipeline vert ne prouve pas

Un scanner qui n'a pas pu télécharger sa base de vulnérabilités — proxy
d'entreprise, quota d'API, image obsolète — bascule sur ses données embarquées ou
saute l'analyse, et sort en succès. Deux garde-fous :

1. Lire les avertissements du journal de scan, pas seulement le code de retour.
2. Exiger la production d'un rapport non vide comme artefact : un contrôle dont la
   sortie « rien trouvé » est identique à la sortie « n'a pas tourné » n'a rien
   vérifié.
