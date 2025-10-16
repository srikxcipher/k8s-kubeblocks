# PostgreSQL Cluster Outputs
# Exposes connection credentials and endpoints

locals {
  # Decode credentials from KubeBlocks-generated secret
  # Use simple base64decode with empty string fallback (not null)
  # After deployment, run terraform refresh to get actual password values
  postgres_username = try(base64decode(data.kubernetes_secret.postgres_credentials.data["username"]), "postgres")
  postgres_password = try(base64decode(data.kubernetes_secret.postgres_credentials.data["password"]), "")
  postgres_database = "postgres"

  # Primary endpoint (always exists)
  primary_host = "${local.cluster_name}-postgresql.${local.namespace}.svc.cluster.local"
  primary_port = 5432

  # PgBouncer connection pool endpoints
  pgbouncer_host = local.primary_host
  pgbouncer_port = 6432

  # Read endpoint (only for replication mode with read service)
  read_host = local.create_read_service ? "${local.cluster_name}-postgresql-read.${local.namespace}.svc.cluster.local" : null
  read_port = local.create_read_service ? 5432 : null

  # Connection strings
  connection_string      = "postgresql://${local.postgres_username}:${local.postgres_password}@${local.primary_host}:${local.primary_port}/${local.postgres_database}"
  read_connection_string = local.read_host != null ? "postgresql://${local.postgres_username}:${local.postgres_password}@${local.read_host}:${local.read_port}/${local.postgres_database}" : null

  # Output attributes
  output_attributes = {
    cluster_name      = local.cluster_name
    namespace         = local.namespace
    postgres_version  = var.instance.spec.postgres_version
    mode              = var.instance.spec.mode
    replicas          = local.replicas
    primary_service   = try(data.kubernetes_service.postgres_primary.metadata[0].name, "${local.cluster_name}-postgresql")
    read_service      = local.read_host != null ? try(kubernetes_service.postgres_read[0].metadata[0].name, null) : null
    connection_secret = try(data.kubernetes_secret.postgres_credentials.metadata[0].name, "${local.cluster_name}-conn-credential")
  }

  # Output interfaces (credentials and connection details)
  output_interfaces = {
    postgres = {
      postgres_host          = local.primary_host
      postgres_port          = local.primary_port
      postgres_database      = local.postgres_database
      postgres_username      = local.postgres_username
      postgres_password      = sensitive(local.postgres_password)
      pgbouncer_host         = local.pgbouncer_host
      pgbouncer_port         = local.pgbouncer_port
      postgres_read_host     = local.read_host
      postgres_read_port     = local.read_port
      connection_string      = sensitive(local.connection_string)
      read_connection_string = sensitive(local.read_connection_string)
      secrets                = ["postgres_password", "connection_string", "read_connection_string"]
    }
  }
}