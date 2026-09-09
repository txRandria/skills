---
name: secure-terraform
description: Écrire du code Terraform (modules, ressources, backend, variables, pipelines de plan/apply) en respectant les exigences de sécurité — état distant chiffré et verrouillé, aucun secret en clair ni dans l'état, moindre privilège IAM, chiffrement au repos et en transit, réseau fermé par défaut, journalisation activée, versions épinglées, scan de configuration. À utiliser dès qu'on crée ou modifie un fichier .tf, .tfvars, un backend, une configuration de provider, ou qu'on prépare un apply. Pour l'audit d'une base Terraform existante, voir aussi le skill terraform-review.
---

# Secure Terraform

**Créé par Tahina Fabien**

Skill open-source. Il fixe les exigences de sécurité applicables à toute
infrastructure décrite en Terraform, indépendamment du fournisseur cloud, et
fournit les contrôles concrets par fournisseur.

**Licence :** CC BY 4.0 — partage et adaptation libres avec attribution.

**Retours :** si la méthodologie pose question ou si un retour constructif est
formulé sur une sortie produite par ce skill, le consigner et proposer de le
partager avec l'auteur. Si le problème vient de l'agent qui n'a pas suivi les
règles du skill, le reconnaître et corriger.

**Dépôt :** https://github.com/txRandria/skills — signaler un problème de méthodologie via une issue publique bénéficie à tous les utilisateurs du skill.

**Articulation avec `terraform-review` :** ce skill couvre l'**écriture** ; le skill
`terraform-review` couvre la **revue** d'une base existante. Les deux se chargent
ensemble sans conflit.

---

## Étape 0 — lire l'existant avant d'écrire

```bash
terraform version
ls -la *.tf *.tfvars* 2>/dev/null
grep -rn 'required_version\|required_providers' --include='*.tf' . | head
grep -rn 'backend "' --include='*.tf' .
```

Relever la version de Terraform, le fournisseur et sa version majeure, la présence
d'un backend distant, la convention de nommage et de découpage en modules déjà en
place. Un fichier `.tf` s'étend, il ne se réécrit pas : une ressource remplacée
sans précaution provoque un `destroy` puis un `create` sur une ressource de
production.

**Avant tout `apply`, vérifier les privilèges disponibles.** Une bascule
d'infrastructure entamée avec une identité incomplète s'arrête à mi-chemin et
laisse l'état incohérent — c'est plus coûteux qu'un échec au premier appel.

## Les 12 règles non négociables

1. **Versions épinglées, sur Terraform comme sur les providers.** Sans contrainte,
   la même configuration produit deux plans différents à deux dates. Les modules
   externes s'épinglent par version **et** par empreinte quand la source le permet.

2. **État distant, chiffré, versionné, verrouillé.** L'état contient en clair des
   valeurs sensibles (mots de passe générés, clés, contenus de secrets). Un état
   local est un secret sur un poste de travail ; un état sur un stockage objet
   public est une compromission complète. Exigences : chiffrement au repos, accès
   restreint à l'identité de la CI, versionnement pour restauration, verrouillage
   pour éviter deux `apply` concurrents.

3. **Aucun secret dans le code, les `.tfvars` ou les variables d'environnement du
   dépôt.** Les secrets se référencent depuis un gestionnaire de secrets au moment
   du `plan`, ou s'injectent par variable d'environnement fournie par la CI.
   `*.tfvars` (hors `*.example.tfvars`) et `*.tfstate*` vont dans `.gitignore`.

4. **Toute valeur sensible marquée `sensitive = true`.** Cela évite l'affichage
   dans les sorties de `plan`/`apply` et dans les journaux de CI. À savoir : la
   valeur reste en clair dans l'état — le marquage protège les journaux, pas
   l'état. La règle 2 protège l'état.

5. **Moindre privilège, jamais de joker.** Aucune politique avec
   `Action: "*"` ou `Resource: "*"`, aucun rôle d'administration attribué à un
   service. Partir des actions requises, pas d'un rôle large qu'on restreindra
   « plus tard ».

6. **Réseau fermé par défaut.** Aucune règle d'entrée depuis `0.0.0.0/0` sauf sur
   un répartiteur de charge en 80/443. Jamais 22, 3389, 3306, 5432, 6379, 27017
   ouverts sur Internet. L'accès d'administration passe par un service de session
   managé ou un hôte bastion, pas par une règle d'entrée large.

7. **Chiffrement au repos et en transit, partout, explicitement.** Stockage objet,
   disques, bases de données, files de messages, sauvegardes, journaux. L'écrire
   même quand le fournisseur l'active par défaut : le défaut change, la déclaration
   documente l'intention et la rend auditable.

8. **Accès public interdit par défaut sur le stockage.** Les blocages d'accès
   public au niveau du compte et du conteneur se déclarent explicitement. Le
   stockage objet public est la première cause de fuite de données d'origine
   cloud.

9. **Journalisation et audit activés.** Journal d'audit des appels d'API (activé
   sur toutes les régions, journal immuable), journaux de flux réseau, journaux
   d'accès au stockage. Sans journal antérieur à l'incident, aucun incident n'est
   analysable.

10. **Pas d'identifiants statiques dans la CI.** Le pipeline s'authentifie par
    fédération d'identité (OIDC) auprès du fournisseur, avec un rôle limité à
    l'environnement et à la branche. Une clé d'accès à longue durée de vie stockée
    en variable de CI est un secret permanent, exfiltrable par n'importe quel job.

11. **Séparation stricte des environnements.** Un état, un jeu d'identifiants et
    un espace de nommage par environnement. `plan` automatique sur la merge
    request, `apply` en production derrière une approbation humaine et une
    protection d'environnement.

12. **Aucun `provisioner` ni `local-exec` manipulant des identifiants.** Ils
    s'exécutent sur l'agent de CI, écrivent dans les journaux, ne sont pas
    idempotents, et leur échec laisse la ressource marquée « corrompue ».
    Préférer les données utilisateur, un outil de configuration, ou une image
    préconstruite.

## Références — charger à la demande

| Fichier | Contenu |
|---|---|
| `references/state-and-secrets.md` | Backends distants durcis (S3+DynamoDB, GCS, Azure, Terraform Cloud), gestion des secrets, `.gitignore`, procédure en cas de fuite d'état |
| `references/aws.md` | Contrôles AWS : IAM, S3, RDS, VPC/SG, KMS, CloudTrail, EKS, OIDC pour la CI |
| `references/gcp-azure.md` | Contrôles GCP et Azure équivalents, avec les différences de modèle d'autorisation |
| `references/scanning-ci.md` | fmt/validate, tflint, trivy config, checkov, plan en CI, garde-fous sur `apply` |

Le choix du fournisseur se lit dans `required_providers`, il ne se suppose pas.

## Squelette de départ

```hcl
terraform {
  # Contrainte pessimiste : accepte les correctifs, refuse les changements mineurs.
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Le backend ne peut pas utiliser de variables : valeurs littérales,
  # ou fichier de configuration partielle passé à `terraform init -backend-config`.
  backend "s3" {
    bucket       = "tfstate-org-prod"
    key          = "mon-app/prod/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    kms_key_id   = "arn:aws:kms:eu-west-3:111122223333:key/<id>"
    use_lockfile = true            # verrouillage natif S3 (Terraform 1.10+)
    # Sur une version antérieure : dynamodb_table = "tfstate-locks"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Projet      = var.projet
      Environment = var.environnement
      ManagedBy   = "terraform"
      Owner       = var.equipe
    }
  }
}
```

Les étiquettes par défaut ne sont pas cosmétiques : sans elles, on ne peut ni
attribuer un coût, ni identifier un propriétaire lors d'un incident, ni
distinguer une ressource gérée d'une ressource créée à la main.

## Écriture des variables

```hcl
variable "environnement" {
  type        = string
  description = "Environnement cible"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environnement)
    error_message = "environnement doit valoir dev, staging ou prod."
  }
}

variable "cidrs_admin_autorises" {
  type        = list(string)
  description = "Plages autorisées à joindre les ports d'administration"
  validation {
    condition     = !contains(var.cidrs_admin_autorises, "0.0.0.0/0")
    error_message = "0.0.0.0/0 est interdit sur les ports d'administration."
  }
}

variable "mot_de_passe_bdd" {
  type      = string
  sensitive = true
  # Jamais de default sur un secret : un default est une valeur en clair dans le code.
}
```

Les blocs `validation` déplacent le contrôle au moment du `plan`, avant que la
ressource n'existe. C'est le seul endroit où une règle de sécurité coûte zéro à
appliquer.

## Contrôle avant livraison (obligatoire)

```bash
terraform fmt -recursive -check
terraform init -backend=false
terraform validate

# Scan de configuration (commande vérifiée ; MSYS_NO_PATHCONV=1 requis sous Git Bash)
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/src" aquasec/trivy:latest config \
  --severity HIGH,CRITICAL /src

# Secrets et états qui n'ont rien à faire dans le dépôt
git ls-files | grep -E '\.tfstate|\.tfvars$' | grep -v example
git grep -nIE '(secret|password|token|access_key)\s*=\s*"[^"$]{8,}' -- '*.tf' '*.tfvars'
```

Liste à cocher sur le code réellement écrit :

- [ ] `required_version` et toutes les versions de providers contraintes.
- [ ] Backend distant, chiffré, versionné, verrouillé — pas d'état local.
- [ ] Aucun secret littéral ; toute sortie sensible marquée `sensitive = true`.
- [ ] `.gitignore` couvre `*.tfstate*`, `*.tfvars` (sauf exemples), `.terraform/`, `crash.log`.
- [ ] Aucune politique avec `"*"` en action ou en ressource.
- [ ] Aucune règle d'entrée `0.0.0.0/0` hors 80/443 sur un répartiteur de charge.
- [ ] Chiffrement déclaré explicitement sur chaque ressource de stockage et de base de données.
- [ ] Blocage d'accès public déclaré sur chaque ressource de stockage objet.
- [ ] Journal d'audit et journaux de flux activés.
- [ ] Aucun `provisioner` manipulant un identifiant.
- [ ] `plan` relu : compter les `destroy` et les `replace`, et les justifier un par un.

## La relecture du plan est un contrôle de sécurité

```bash
terraform plan -out=tfplan
terraform show -json tfplan | jq -r '
  .resource_changes[] | select(.change.actions | index("delete")) |
  "\(.change.actions | join(",")) \(.address)"'
```

Un `apply` en production se lit avant de s'exécuter. Les remplacements silencieux
— une base de données recréée parce qu'un attribut immuable a changé — sont la
première cause d'incident majeur d'origine Terraform. Ne jamais déployer le code
avant d'avoir l'autorisation d'effectuer la migration correspondante.
