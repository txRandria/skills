# Contrôles GCP et Azure

Les principes du SKILL.md ne changent pas ; seuls les mécanismes diffèrent. La
différence la plus structurante est le modèle d'autorisation : AWS attache des
politiques à des identités, GCP lie des rôles à des ressources hiérarchisées,
Azure attribue des rôles sur des portées (souscription / groupe de ressources /
ressource).

---

# GCP

## IAM

```hcl
# Liaison par membre : n'écrase pas les autres liaisons de la ressource.
resource "google_storage_bucket_iam_member" "app_lecture" {
  bucket = google_storage_bucket.documents.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.app.email}"
}
```

Piège majeur : `google_project_iam_policy` et `google_*_iam_binding` sont
**autoritaires** — ils remplacent l'ensemble des liaisons existantes pour ce rôle
ou cette ressource, y compris celles créées hors Terraform. Un `apply` peut ainsi
retirer les accès des administrateurs humains. Utiliser `_iam_member` sauf
intention explicite de tout gérer depuis Terraform.

Interdits : `roles/owner`, `roles/editor` (bien plus large qu'il n'y paraît) et
`roles/iam.serviceAccountUser` accordés à un compte de service applicatif.
Préférer des rôles prédéfinis étroits, ou un rôle personnalisé :

```hcl
resource "google_project_iam_custom_role" "app" {
  role_id     = "hrPortalApp"
  title       = "mon-app application"
  permissions = [
    "storage.objects.get",
    "storage.objects.create",
    "secretmanager.versions.access",
  ]
}
```

Ne jamais créer de clé de compte de service (`google_service_account_key`) : c'est
un identifiant permanent au format JSON, qui finit dans une variable de CI ou un
dépôt. Utiliser la fédération d'identité de charge de travail :

```hcl
resource "google_iam_workload_identity_pool_provider" "gitlab" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.ci.workload_identity_pool_id
  workload_identity_pool_provider_id = "gitlab"
  oidc { issuer_uri = "https://gitlab.exemple.tld" }
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.project_path"
  }
  # Sans condition, tout projet de l'instance peut usurper le compte de service.
  attribute_condition = "attribute.repository == 'mon-org/projets/mon-app'"
}
```

## Cloud Storage

```hcl
resource "google_storage_bucket" "documents" {
  name                        = "mon-app-documents-prod"
  location                    = "europe-west1"
  uniform_bucket_level_access = true       # supprime les ACL par objet
  public_access_prevention    = "enforced" # empêche toute exposition publique
  versioning { enabled = true }
  encryption { default_kms_key_name = google_kms_crypto_key.documents.id }

  lifecycle_rule {
    condition { num_newer_versions = 5 }
    action { type = "Delete" }
  }

  logging {
    log_bucket        = google_storage_bucket.journaux.name
    log_object_prefix = "documents/"
  }
}
```

Ne jamais accorder `roles/storage.objectViewer` au membre `allUsers` ou
`allAuthenticatedUsers` : `allAuthenticatedUsers` désigne tout titulaire d'un
compte Google, pas les utilisateurs de l'organisation.

## Cloud SQL

```hcl
resource "google_sql_database_instance" "hrportal" {
  name                = "mon-app-prod"
  database_version    = "POSTGRES_16"
  region              = "europe-west1"
  deletion_protection = true

  settings {
    tier              = "db-custom-2-7680"
    availability_type = "REGIONAL"
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false          # aucune adresse publique
      private_network = google_compute_network.principal.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
    }

    database_flags {
      name  = "log_connections"
      value = "on"
    }
  }
  encryption_key_name = google_kms_crypto_key.bdd.id
}
```

`ipv4_enabled = false` est le point critique : une instance Cloud SQL avec IP
publique et un réseau autorisé trop large est directement exposée.

## Réseau

```hcl
resource "google_compute_firewall" "https" {
  name          = "autoriser-https"
  network       = google_compute_network.principal.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["0.0.0.0/0"]       # acceptable seulement vers le répartiteur
  target_tags   = ["lb-frontal"]
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

# Journalisation des flux : obligatoire pour toute analyse d'incident.
resource "google_compute_subnetwork" "privee" {
  name                     = "privee"
  ip_cidr_range            = "10.10.0.0/20"
  network                  = google_compute_network.principal.id
  private_ip_google_access = true
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}
```

Le réseau `default` créé automatiquement par GCP ouvre SSH et RDP depuis
Internet : le supprimer ou désactiver sa création
(`google_project.auto_create_network = false`), ne jamais y déployer.

Accès d'administration par IAP TCP forwarding, pas par IP publique + port 22.

## Journalisation d'audit

```hcl
resource "google_project_iam_audit_config" "tout" {
  project = var.projet
  service = "allServices"
  audit_log_config { log_type = "ADMIN_READ" }
  audit_log_config { log_type = "DATA_READ" }
  audit_log_config { log_type = "DATA_WRITE" }
}
```

Les journaux d'accès aux données ne sont pas activés par défaut et sont facturés :
c'est une décision à prendre explicitement, pas à omettre par défaut.

---

# Azure

## Rôles et identités

```hcl
resource "azurerm_role_assignment" "app_lecture_secret" {
  scope                = azurerm_key_vault.principal.id   # portée la plus étroite possible
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}
```

Toujours attribuer à la portée la plus étroite : ressource plutôt que groupe de
ressources, groupe de ressources plutôt que souscription. Les rôles `Owner`,
`Contributor` et `User Access Administrator` ne s'attribuent pas à une identité
applicative — `User Access Administrator` permet de s'auto-accorder n'importe quel
droit.

Ne jamais créer d'enregistrement d'application avec un secret client à longue
durée de vie pour une charge de travail : utiliser une identité managée
(`azurerm_user_assigned_identity`), ou la fédération d'identité pour la CI :

```hcl
resource "azuread_application_federated_identity_credential" "ci" {
  application_id = azuread_application.ci.id
  display_name   = "gitlab-main"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://gitlab.exemple.tld"
  subject        = "project_path:mon-org/projets/mon-app:ref_type:branch:ref:main"
}
```

## Compte de stockage

```hcl
resource "azurerm_storage_account" "documents" {
  name                            = "sthrportaldocsprod"
  resource_group_name             = azurerm_resource_group.principal.name
  location                        = azurerm_resource_group.principal.location
  account_tier                    = "Standard"
  account_replication_type        = "GRS"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false   # force l'authentification Entra ID
  public_network_access_enabled   = false

  blob_properties {
    versioning_enabled = true
    delete_retention_policy         { days = 30 }
    container_delete_retention_policy { days = 30 }
  }

  network_rules {
    default_action = "Deny"                 # fermé par défaut
    bypass         = ["AzureServices"]
    virtual_network_subnet_ids = [azurerm_subnet.applicative.id]
  }
}
```

`shared_access_key_enabled = false` supprime la clé de compte — un secret partagé
qui, une fois divulgué, donne un accès complet et ne peut être ni tracé par
identité ni révoqué individuellement.

## Base de données

```hcl
resource "azurerm_postgresql_flexible_server" "hrportal" {
  name                          = "psql-mon-app-prod"
  resource_group_name           = azurerm_resource_group.principal.name
  location                      = azurerm_resource_group.principal.location
  version                       = "16"
  public_network_access_enabled = false
  delegated_subnet_id           = azurerm_subnet.bdd.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false     # pas de mot de passe à gérer ni à faire fuir
  }

  backup_retention_days        = 14
  geo_redundant_backup_enabled = true
  high_availability { mode = "ZoneRedundant" }

  customer_managed_key {
    key_vault_key_id                  = azurerm_key_vault_key.bdd.id
    primary_user_assigned_identity_id = azurerm_user_assigned_identity.bdd.id
  }
}
```

Ne jamais créer de règle de pare-feu `0.0.0.0` à `255.255.255.255`, ni la règle
« autoriser les services Azure » qui ouvre l'accès depuis n'importe quelle
souscription Azure, y compris celles d'autres organisations.

## Key Vault

```hcl
resource "azurerm_key_vault" "principal" {
  name                          = "kv-mon-app-prod"
  resource_group_name           = azurerm_resource_group.principal.name
  location                      = azurerm_resource_group.principal.location
  tenant_id                     = data.azurerm_client_config.actuel.tenant_id
  sku_name                      = "standard"

  enable_rbac_authorization     = true    # RBAC plutôt que les politiques d'accès héritées
  purge_protection_enabled      = true    # empêche la destruction définitive immédiate
  soft_delete_retention_days    = 90
  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}
```

`purge_protection_enabled` est irréversible une fois activé — c'est le but : il
empêche qu'un attaquant disposant de droits supprime définitivement les clés et
rende les données chiffrées irrécupérables.

## Journalisation

```hcl
resource "azurerm_monitor_diagnostic_setting" "stockage" {
  name                       = "diag-stockage"
  target_resource_id         = "${azurerm_storage_account.documents.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.principal.id

  enabled_log { category = "StorageRead" }
  enabled_log { category = "StorageWrite" }
  enabled_log { category = "StorageDelete" }
  metric { category = "Transaction" }
}
```

Le journal d'activité de la souscription est conservé 90 jours par défaut : pour
une rétention conforme, l'exporter vers un espace de travail Log Analytics ou un
compte de stockage immuable.

---

## Équivalences rapides

| Besoin | AWS | GCP | Azure |
|---|---|---|---|
| Identité de charge sans clé | Rôle IAM + OIDC | Workload Identity Federation | Identité managée / fédération |
| Coffre à secrets | Secrets Manager | Secret Manager | Key Vault |
| Clé de chiffrement gérée | KMS | Cloud KMS | Key Vault Key |
| Blocage d'accès public | Public Access Block | `public_access_prevention` | `allow_nested_items_to_be_public=false` |
| Journal d'audit d'API | CloudTrail | Cloud Audit Logs | Activity Log + Diagnostic Settings |
| Journaux de flux réseau | VPC Flow Logs | Subnetwork `log_config` | NSG Flow Logs |
| Administration sans port 22 | SSM Session Manager | IAP TCP forwarding | Azure Bastion |
