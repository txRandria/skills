# État distant et gestion des secrets

## Pourquoi l'état est un secret

`terraform.tfstate` contient en clair : mots de passe générés par `random_password`,
clés d'accès créées par Terraform, contenus de secrets lus par une source de
données, chaînes de connexion, clés privées. `sensitive = true` masque l'affichage
dans les sorties — **il ne chiffre rien dans l'état**. Quiconque lit l'état lit
l'infrastructure entière et ses identifiants.

Conséquences pratiques :
- L'état ne va jamais dans git, même dans un dépôt privé.
- Le stockage de l'état est traité comme un coffre : chiffré, non public, accès
  restreint à l'identité de la CI et à un petit groupe d'administrateurs, journalisé.
- Une fuite d'état impose la rotation de tout ce qu'il contient, pas seulement sa
  suppression.

## Backend S3 durci (AWS)

Le bucket d'état se crée **en dehors** de la configuration qu'il servira (amorçage
séparé, ou création manuelle documentée) : une configuration ne peut pas stocker
son propre état dans un bucket qu'elle est en train de créer.

```hcl
resource "aws_s3_bucket" "tfstate" {
  bucket = "tfstate-org-prod"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true   # réduit le coût des appels KMS — mesure de coût, pas de sécurité
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Refuse tout accès non chiffré en transit.
resource "aws_s3_bucket_policy" "tfstate_tls" {
  bucket = aws_s3_bucket.tfstate.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_kms_key" "tfstate" {
  description             = "Chiffrement de l'état Terraform"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}
```

Note : `bucket_key_enabled` est une optimisation de coût des appels KMS. Ne pas la
présenter comme un contrôle de sécurité — elle ne change pas le niveau de
protection.

Verrouillage : depuis Terraform 1.10, `use_lockfile = true` dans le bloc `backend`
suffit et rend la table DynamoDB inutile. Sur une version antérieure, la table
reste nécessaire :

```hcl
resource "aws_dynamodb_table" "tfstate_locks" {
  name         = "tfstate-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  server_side_encryption { enabled = true }
  point_in_time_recovery { enabled = true }
}
```

## Backend GCS (GCP)

```hcl
terraform {
  backend "gcs" {
    bucket = "tfstate-org-prod"
    prefix = "mon-app/prod"
  }
}

resource "google_storage_bucket" "tfstate" {
  name                        = "tfstate-org-prod"
  location                    = "europe-west1"
  uniform_bucket_level_access = true    # désactive les ACL par objet
  public_access_prevention    = "enforced"
  versioning { enabled = true }
  encryption { default_kms_key_name = google_kms_crypto_key.tfstate.id }
}
```

GCS verrouille l'état nativement : aucune ressource supplémentaire n'est requise.

## Backend AzureRM (Azure)

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateorgprod"
    container_name       = "tfstate"
    key                  = "mon-app/prod.tfstate"
    use_azuread_auth     = true    # identité Entra ID plutôt qu'une clé de compte
  }
}
```

Sur le compte de stockage : `min_tls_version = "TLS1_2"`,
`allow_nested_items_to_be_public = false`, `https_traffic_only_enabled = true`,
suppression réversible activée. Le verrouillage est assuré par les baux de blob.

## Configuration partielle du backend

Le bloc `backend` n'accepte ni variable ni interpolation. Pour éviter de dupliquer
la configuration par environnement :

```hcl
terraform {
  backend "s3" {}
}
```

```hcl
# backends/prod.hcl — commité, ne contient aucun secret
bucket       = "tfstate-org-prod"
key          = "mon-app/prod/terraform.tfstate"
region       = "eu-west-3"
encrypt      = true
use_lockfile = true
```

```bash
terraform init -backend-config=backends/prod.hcl -reconfigure
```

Ce fichier ne contient que des identifiants de ressources, jamais d'identifiants
d'authentification — ceux-ci viennent de la fédération d'identité de la CI.

## D'où viennent les secrets

### 1. Généré par Terraform, stocké dans le gestionnaire de secrets

```hcl
resource "random_password" "bdd" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "bdd" {
  name                    = "mon-app/prod/db"
  kms_key_id              = aws_kms_key.app.arn
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret_version" "bdd" {
  secret_id     = aws_secretsmanager_secret.bdd.id
  secret_string = jsonencode({ username = "hrportal", password = random_password.bdd.result })
}
```

La valeur existe dans l'état — d'où l'importance de la règle 2. L'application lit
le secret à l'exécution ; elle ne le reçoit jamais par variable Terraform.

### 2. Créé hors Terraform, lu en données

```hcl
data "aws_secretsmanager_secret_version" "bdd" {
  secret_id = "mon-app/prod/db"
}

locals {
  mot_de_passe = jsondecode(data.aws_secretsmanager_secret_version.bdd.secret_string)["password"]
}
```

C'est le motif préférable : Terraform ne crée pas le secret, il s'y réfère.
La valeur transite quand même par l'état si elle est utilisée dans une ressource.

### 3. Injecté par la CI

```bash
export TF_VAR_mot_de_passe_bdd="$SECRET_DEPUIS_LE_COFFRE"
terraform apply -auto-approve
```

Toute variable `TF_VAR_<nom>` alimente `var.<nom>`. La valeur n'apparaît ni dans
le dépôt ni dans un `.tfvars`. Vérifier que la variable de CI est masquée dans les
journaux.

### Ce qui est interdit

```hcl
variable "mot_de_passe" {
  default = "Motdepasse123!"        # secret en clair dans le code
}
```

```hcl
resource "aws_db_instance" "bdd" {
  password = "Motdepasse123!"       # secret en clair, et dans l'état
}
```

```bash
prod.tfvars   # contenant des secrets, commité
```

## `.gitignore` de référence

```
*.tfstate
*.tfstate.*
*.tfstate.backup
.terraform/
.terraform.lock.hcl.bak
crash.log
crash.*.log
*.tfvars
*.tfvars.json
!*.example.tfvars
!terraform.tfvars.example
override.tf
override.tf.json
*_override.tf
.terraformrc
terraform.rc
```

`.terraform.lock.hcl` est **commité** : il épingle les empreintes des providers et
protège d'une substitution de provider. Ne pas le confondre avec les fichiers
d'état.

## Si un état ou un secret a fuité

L'ordre compte — la suppression du fichier ne restaure rien.

1. **Rotationner** tout ce que l'état contient : mots de passe de base de données,
   clés d'accès, jetons, clés d'API. Un secret exposé une fois est compromis, même
   si le fichier a été retiré de `HEAD` : il reste dans l'historique git, dans les
   caches de forge, dans les clones locaux et dans les journaux de CI.
2. **Révoquer** les identifiants qui ne peuvent pas être rotationnés, puis les
   recréer.
3. **Chercher l'usage** dans les journaux d'audit du fournisseur, sur la fenêtre
   allant de la date d'exposition à aujourd'hui.
4. **Corriger la cause** : `.gitignore`, backend distant, secret déplacé vers un
   coffre.
5. **Purger l'historique** en dernier — c'est la partie visible, pas la partie
   protectrice.

Un inventaire statique ne permet pas de conclure à l'absence d'utilisation
malveillante. Le dire explicitement dans le rapport d'incident.

## Séparation des environnements

Un état par environnement, avec des identifiants distincts :

```
envs/
  dev/     main.tf  backend.hcl  terraform.tfvars
  staging/ ...
  prod/    ...
modules/
  reseau/  bdd/  application/
```

Les espaces de travail (`terraform workspace`) partagent le même backend et
souvent les mêmes identifiants : ils conviennent pour des variantes éphémères, pas
pour séparer production et développement. La séparation par répertoire et par
identité est la seule qui empêche un `apply` de développement d'atteindre la
production.
