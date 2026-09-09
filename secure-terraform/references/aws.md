# Contrôles AWS

## IAM — moindre privilège

```hcl
# Politique d'application : actions listées, ressources ciblées, condition de chiffrement.
data "aws_iam_policy_document" "app" {
  statement {
    sid     = "LectureDocuments"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.documents.arn}/prod/*"]   # préfixe, pas le bucket entier

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid       = "LectureSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.bdd.arn]
  }
}
```

Interdits : `actions = ["*"]`, `resources = ["*"]`, attachement de
`AdministratorAccess` ou `PowerUserAccess` à un rôle de service, `iam:PassRole`
sans condition `iam:PassedToService`, `sts:AssumeRole` sans restriction de
principal.

`iam:PassRole` non conditionné est une escalade de privilège classique : le
titulaire peut attacher n'importe quel rôle à une ressource qu'il crée.

```hcl
statement {
  actions   = ["iam:PassRole"]
  resources = [aws_iam_role.tache.arn]
  condition {
    test     = "StringEquals"
    variable = "iam:PassedToService"
    values   = ["ecs-tasks.amazonaws.com"]
  }
}
```

### Politique de confiance d'un rôle

Le point le plus souvent trop large. Un rôle assumable par `"AWS": "*"` est un
rôle public.

```hcl
data "aws_iam_policy_document" "confiance_ecs" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    # Confused deputy : restreindre à ce compte et à cette ressource.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.actuel.account_id]
    }
  }
}
```

### Rôle OIDC pour la CI (aucune clé statique)

```hcl
# GitLab
resource "aws_iam_openid_connect_provider" "gitlab" {
  url             = "https://gitlab.exemple.tld"
  client_id_list  = ["https://gitlab.exemple.tld"]
  thumbprint_list = [var.empreinte_gitlab]
}

data "aws_iam_policy_document" "confiance_ci" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "gitlab.exemple.tld:aud"
      values   = ["https://gitlab.exemple.tld"]
    }
    # Restriction au projet ET à la branche : sans elle, n'importe quel projet
    # de l'instance peut assumer le rôle.
    condition {
      test     = "StringLike"
      variable = "gitlab.exemple.tld:sub"
      values   = ["project_path:mon-org/projets/mon-app:ref_type:branch:ref:main"]
    }
  }
}
```

Pour GitHub Actions, le fournisseur est `token.actions.githubusercontent.com` et
la condition porte sur `repo:<org>/<repo>:ref:refs/heads/main` ou
`repo:<org>/<repo>:environment:production`. La condition sur `sub` n'est pas
optionnelle : un rôle fédéré sans elle est assumable depuis n'importe quel dépôt
de la plateforme.

## S3

```hcl
resource "aws_s3_bucket" "documents" {
  bucket = "mon-app-documents-prod"
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket                  = aws_s3_bucket.documents.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.documents.arn
    }
  }
}

resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_logging" "documents" {
  bucket        = aws_s3_bucket.documents.id
  target_bucket = aws_s3_bucket.journaux.id
  target_prefix = "s3-access/documents/"
}

resource "aws_s3_bucket_lifecycle_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id
  rule {
    id     = "purge-versions-anciennes"
    status = "Enabled"
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}
```

Ajouter la politique de refus du transport non chiffré (voir
`state-and-secrets.md`). Ne jamais utiliser `acl = "public-read"` ni
`aws_s3_bucket_public_access_block` avec des valeurs à `false`.

## RDS / Aurora

```hcl
resource "aws_db_instance" "hrportal" {
  identifier     = "mon-app-prod"
  engine         = "postgres"
  engine_version = "16.4"
  instance_class = "db.t4g.medium"

  # Chiffrement au repos — non modifiable après création : à poser dès le départ.
  storage_encrypted = true
  kms_key_id        = aws_kms_key.bdd.arn

  # Jamais joignable depuis Internet.
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.privees.name
  vpc_security_group_ids = [aws_security_group.bdd.id]

  username = "hrportal"
  # Mot de passe géré par AWS et stocké dans Secrets Manager : il ne transite
  # jamais par l'état Terraform.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.bdd.arn

  backup_retention_period = 14
  copy_tags_to_snapshot   = true
  deletion_protection     = true
  skip_final_snapshot     = false
  final_snapshot_identifier = "mon-app-prod-final"

  auto_minor_version_upgrade = true
  multi_az                   = true

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.bdd.arn
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  # Chiffrement en transit imposé côté moteur.
  parameter_group_name = aws_db_parameter_group.tls_obligatoire.name
}

resource "aws_db_parameter_group" "tls_obligatoire" {
  name   = "mon-app-pg16-tls"
  family = "postgres16"
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}
```

`manage_master_user_password = true` est le motif à privilégier : il supprime le
mot de passe de l'état Terraform, ce que `random_password` ne fait pas.

## VPC et groupes de sécurité

```hcl
# Règles en ressources séparées : un bloc `ingress` inline écrase silencieusement
# les règles gérées ailleurs et complique les diffs.
resource "aws_security_group" "alb" {
  name        = "mon-app-alb"
  description = "Répartiteur de charge public"
  vpc_id      = aws_vpc.principal.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS public"
  cidr_ipv4         = "0.0.0.0/0"     # acceptable UNIQUEMENT sur 443 d'un ALB
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_depuis_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Trafic applicatif depuis l'ALB uniquement"
  referenced_security_group_id = aws_security_group.alb.id   # référence, pas de CIDR
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "bdd_depuis_app" {
  security_group_id            = aws_security_group.bdd.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
```

Le chaînage par référence de groupe (et non par CIDR) est ce qui garantit qu'un
élargissement du réseau n'élargit pas l'accès à la base.

Interdits : `0.0.0.0/0` sur 22, 3389, 3306, 5432, 6379, 27017, 9200, 5601, et sur
la plage `0-65535`. L'accès d'administration passe par SSM Session Manager :

```hcl
# Aucun port 22 ouvert, aucune clé SSH à gérer, sessions journalisées dans CloudTrail.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

Journaux de flux, obligatoires pour toute analyse d'incident réseau :

```hcl
resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.principal.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.journaux.arn
}
```

## KMS

```hcl
resource "aws_kms_key" "app" {
  description             = "Clé applicative mon-app"
  enable_key_rotation     = true      # rotation annuelle automatique
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms_app.json
}

resource "aws_kms_alias" "app" {
  name          = "alias/mon-app-app"
  target_key_id = aws_kms_key.app.key_id
}
```

La politique de clé ne doit pas se réduire à `"Action": "kms:*", "Principal": "*"`
même conditionnée par `kms:CallerAccount` : séparer les administrateurs de la clé
(gestion) des utilisateurs de la clé (chiffrement/déchiffrement). Cette séparation
est ce qui empêche qu'un rôle applicatif compromis supprime la clé.

## CloudTrail

```hcl
resource "aws_cloudtrail" "audit" {
  name                          = "audit-organisation"
  s3_bucket_name                = aws_s3_bucket.journaux.id
  is_multi_region_trail         = true    # sinon une action dans une autre région n'est pas tracée
  is_organization_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true    # détecte l'altération des journaux
  kms_key_id                    = aws_kms_key.journaux.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.documents.arn}/"]
    }
  }
}
```

Le bucket de journaux porte un verrou d'objet (`object_lock_enabled`) en mode
conformité si la rétention doit résister à un administrateur compromis.

## ECS Fargate

```hcl
resource "aws_ecs_task_definition" "app" {
  family                   = "mon-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution.arn   # tire l'image, lit les secrets
  task_role_arn            = aws_iam_role.tache.arn       # droits de l'application

  container_definitions = jsonencode([{
    name      = "app"
    image     = "${aws_ecr_repository.app.repository_url}@${var.image_digest}"  # digest, pas tag
    essential = true
    user      = "10001:10001"
    readonlyRootFilesystem = true
    linuxParameters = { initProcessEnabled = true }

    # Le secret est injecté par la plateforme, jamais écrit dans la définition.
    secrets = [{
      name      = "DB_PASSWORD"
      valueFrom = "${aws_secretsmanager_secret.bdd.arn}:password::"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}
```

Séparer `execution_role_arn` et `task_role_arn` : le premier n'a besoin que de
tirer l'image et de lire les secrets ; le second porte les droits applicatifs. Les
confondre donne à l'application le droit de lire tous les secrets de la plateforme.

Déployer par **digest** et non par tag : un tag est réattribuable, donc le
déploiement n'est pas reproductible et une image substituée passe inaperçue.

Le service tourne dans des sous-réseaux privés, avec `assign_public_ip = false` et
une sortie par passerelle NAT ou par points de terminaison VPC.

## Chiffrement ECR et scan à la publication

```hcl
resource "aws_ecr_repository" "app" {
  name                 = "mon-app"
  image_tag_mutability = "IMMUTABLE"     # un tag publié ne peut plus être réécrit
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.app.arn
  }
}
```

`IMMUTABLE` est le contrôle qui rend le déploiement par tag moins dangereux — mais
le déploiement par digest reste préférable.
