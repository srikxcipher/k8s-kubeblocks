# PostgreSQL Cluster Module - KubeBlocks v0.9.5
# Creates and manages PostgreSQL database clusters using KubeBlocks operator
# REQUIRES: KubeBlocks operator must be deployed first (CRDs must exist)

# Local variables for cleaner code
locals {
  cluster_name = var.instance.spec.cluster_name
  # Generate unique namespace per cluster: <cluster-name>-ns
  namespace = "${var.instance.spec.cluster_name}-ns"
  replicas  = var.instance.spec.mode == "standalone" ? 1 : lookup(var.instance.spec, "replicas", 2)

  # HA settings with defaults
  ha_enabled               = var.instance.spec.mode == "replication"
  enable_pod_anti_affinity = local.ha_enabled && lookup(lookup(var.instance.spec, "high_availability", {}), "enable_pod_anti_affinity", true)
  anti_affinity_type       = local.ha_enabled ? lookup(lookup(var.instance.spec, "high_availability", {}), "anti_affinity_type", "Preferred") : "Preferred"
  create_read_service      = local.ha_enabled && lookup(lookup(var.instance.spec, "high_availability", {}), "create_read_service", true)

  # Backup settings
  backup_config             = lookup(var.instance.spec, "backup", {})
  backup_enabled            = try(coalesce(lookup(local.backup_config, "enabled", null), false), false)
  create_backup_repo        = local.backup_enabled && try(coalesce(lookup(local.backup_config, "create_backup_repo", null), true), true)
  backup_repo_name          = local.create_backup_repo ? "${local.cluster_name}-backup-repo" : try(lookup(local.backup_config, "backup_repo_name", ""), "")
  backup_repo_storage       = try(lookup(local.backup_config, "backup_repo_storage_size", "20Gi"), "20Gi")
  backup_repo_storage_class = try(lookup(local.backup_config, "backup_repo_storage_class", ""), "")

  # Backup schedule settings (for future use)
  backup_schedule_enabled = local.backup_enabled && try(coalesce(lookup(local.backup_config, "enable_schedule", null), false), false)
  backup_schedule_cron    = try(lookup(local.backup_config, "schedule_cron", "0 2 * * *"), "0 2 * * *")
  backup_retention_period = try(lookup(local.backup_config, "retention_period", "7d"), "7d")
  backup_method           = try(lookup(local.backup_config, "backup_method", "volume-snapshot"), "volume-snapshot")

  # Component definition based on version
  component_def_ref   = "postgresql"
  cluster_version_ref = "postgresql-${var.instance.spec.postgres_version}"
}

# Kubernetes Namespace for PostgreSQL Cluster
# Creates the namespace for the PostgreSQL cluster
resource "kubernetes_namespace" "postgresql_cluster" {
  metadata {
    name = local.namespace

    annotations = {
      "kubeblocks.io/operator-release-id"    = var.inputs.kubeblocks_operator.output_interfaces.output.release_id
      "kubeblocks.io/operator-dependency-id" = var.inputs.kubeblocks_operator.output_interfaces.output.dependency_id
    }

    labels = merge(
      {
        "app.kubernetes.io/name"       = "postgresql-cluster"
        "app.kubernetes.io/instance"   = var.instance_name
        "app.kubernetes.io/managed-by" = "terraform"
      },
      var.environment.cloud_tags
    )
  }

  # Wait for resources to be deleted before namespace deletion completes
  timeouts {
    delete = "5m"
  }

  # If namespace already exists, don't fail - just import it
  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations
    ]
  }
}

# BackupRepo - PVC-based backup repository
# Using any-k8s-resource module to avoid plan-time CRD validation
module "backup_repo" {
  count  = local.create_backup_repo ? 1 : 0
  source = "github.com/Facets-cloud/facets-utility-modules//any-k8s-resource"

  name      = local.backup_repo_name
  namespace = local.namespace

  # Create implicit dependency on operator by including release_id in release name
  release_name = "backuprepo-${local.backup_repo_name}-${substr(var.inputs.kubeblocks_operator.output_interfaces.output.release_id, 0, 8)}"

  # Explicit dependency on namespace ensures this is created AFTER namespace
  depends_on = [kubernetes_namespace.postgresql_cluster]

  data = {
    apiVersion = "dataprotection.kubeblocks.io/v1alpha1"
    kind       = "BackupRepo"

    metadata = {
      name = local.backup_repo_name
      annotations = {
        "dataprotection.kubeblocks.io/is-default-repo" = "true"
        "kubeblocks.io/operator-release-id"            = var.inputs.kubeblocks_operator.output_interfaces.output.release_id
        "kubeblocks.io/operator-dependency-id"         = var.inputs.kubeblocks_operator.output_interfaces.output.dependency_id
      }
      labels = {
        "app.kubernetes.io/instance"   = var.instance_name
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }

    spec = merge(
      {
        storageProviderRef = "pvc"
        volumeCapacity     = local.backup_repo_storage
        pvReclaimPolicy    = "Retain"
        config = {
          mountOptions = ""
        }
      },
      local.backup_repo_storage_class != "" ? {
        config = {
          storageClassName = local.backup_repo_storage_class
          mountOptions     = ""
        }
      } : {}
    )
  }

  advanced_config = {
    wait            = true
    timeout         = 600 # 10 minutes
    cleanup_on_fail = true
    max_history     = 3
  }
}

# PostgreSQL Cluster
# Using any-k8s-resource module to avoid plan-time CRD validation
module "postgresql_cluster" {
  source = "github.com/Facets-cloud/facets-utility-modules//any-k8s-resource"

  name      = local.cluster_name
  namespace = local.namespace

  # Create implicit dependency on operator by including release_id in release name
  release_name = "pgcluster-${local.cluster_name}-${substr(var.inputs.kubeblocks_operator.output_interfaces.output.release_id, 0, 8)}"

  # Explicit dependency on namespace ensures this is created AFTER namespace
  depends_on = [kubernetes_namespace.postgresql_cluster]

  data = {
    apiVersion = "apps.kubeblocks.io/v1alpha1"
    kind       = "Cluster"

    metadata = {
      name      = local.cluster_name
      namespace = local.namespace

      annotations = {
        "kubeblocks.io/operator-release-id"    = var.inputs.kubeblocks_operator.output_interfaces.output.release_id
        "kubeblocks.io/operator-dependency-id" = var.inputs.kubeblocks_operator.output_interfaces.output.dependency_id
      }

      labels = merge(
        {
          "app.kubernetes.io/name"       = "postgresql"
          "app.kubernetes.io/instance"   = var.instance_name
          "app.kubernetes.io/managed-by" = "terraform"
          "app.kubernetes.io/version"    = var.instance.spec.postgres_version
        },
        var.environment.cloud_tags
      )
    }

    spec = merge(
      {
        clusterDefinitionRef = "postgresql"
        clusterVersionRef    = local.cluster_version_ref
        terminationPolicy    = var.instance.spec.termination_policy

        componentSpecs = [
          {
            name            = "postgresql"
            componentDefRef = local.component_def_ref
            serviceVersion  = var.instance.spec.postgres_version
            replicas        = local.replicas

            resources = {
              limits = {
                cpu    = var.instance.spec.resources.cpu_limit
                memory = var.instance.spec.resources.memory_limit
              }
              requests = {
                cpu    = var.instance.spec.resources.cpu_request
                memory = var.instance.spec.resources.memory_request
              }
            }

            volumeClaimTemplates = [
              {
                name = "data"
                spec = merge(
                  {
                    accessModes = ["ReadWriteOnce"]
                    resources = {
                      requests = {
                        storage = var.instance.spec.storage.size
                      }
                    }
                  },
                  var.instance.spec.storage.storage_class != "" ? {
                    storageClassName = var.instance.spec.storage.storage_class
                  } : {}
                )
              }
            ]

            # Add tolerations to allow scheduling on spot instances and tainted nodes
            tolerations = [
              {
                key      = "kubernetes.azure.com/scalesetpriority"
                operator = "Equal"
                value    = "spot"
                effect   = "NoSchedule"
              }
            ]
          }
        ]
      },
      # Conditional affinity for HA mode
      local.enable_pod_anti_affinity ? {
        affinity = {
          podAntiAffinity = local.anti_affinity_type
          topologyKeys    = ["kubernetes.io/hostname"]
        }
      } : {}
    )
  }

  advanced_config = {
    wait            = true
    timeout         = 2700 # 45 minutes - increased to handle slow image pulls and volume initialization
    cleanup_on_fail = true
    max_history     = 3
  }
}

# Read-Only Service (only for replication mode)
resource "kubernetes_service" "postgres_read" {
  count = local.create_read_service ? 1 : 0

  metadata {
    name      = "${local.cluster_name}-postgresql-read"
    namespace = local.namespace

    labels = {
      "app.kubernetes.io/instance"        = local.cluster_name
      "app.kubernetes.io/managed-by"      = "kubeblocks"
      "apps.kubeblocks.io/component-name" = "postgresql"
      "facets.io/created-by"              = "terraform"
    }
  }

  spec {
    type = "ClusterIP"

    # Target only secondary (read-only) replicas
    selector = {
      "app.kubernetes.io/instance"        = local.cluster_name
      "app.kubernetes.io/managed-by"      = "kubeblocks"
      "apps.kubeblocks.io/component-name" = "postgresql"
      "kubeblocks.io/role"                = "secondary"
    }

    port {
      name        = "tcp-postgresql"
      port        = 5432
      protocol    = "TCP"
      target_port = "tcp-postgresql"
    }

    port {
      name        = "tcp-pgbouncer"
      port        = 6432
      protocol    = "TCP"
      target_port = "tcp-pgbouncer"
    }

    session_affinity = "None"
  }

  depends_on = [
    kubernetes_namespace.postgresql_cluster,
    module.postgresql_cluster
  ]
}

# Data Source: Connection Credentials Secret
# KubeBlocks auto-creates this secret with format: {cluster-name}-conn-credential
data "kubernetes_secret" "postgres_credentials" {
  metadata {
    name      = "${local.cluster_name}-conn-credential"
    namespace = local.namespace
  }

  depends_on = [module.postgresql_cluster]
}

# Data Source: Primary Service
# KubeBlocks auto-creates this service with format: {cluster-name}-postgresql
data "kubernetes_service" "postgres_primary" {
  metadata {
    name      = "${local.cluster_name}-postgresql"
    namespace = local.namespace
  }

  depends_on = [module.postgresql_cluster]
}

# Volume Expansion
# KubeBlocks v0.9.5+ automatically handles volume expansion when you update
# the storage size in the Cluster spec above. No separate OpsRequest needed.
# When storage size increases, KubeBlocks will automatically:
# 1. Detect the change in volumeClaimTemplates
# 2. Create an OpsRequest internally
# 3. Expand the PVCs gracefully
#
# To expand storage: simply update var.instance.spec.storage.size and apply
