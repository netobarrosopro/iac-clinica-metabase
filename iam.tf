data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# --- Execution role: pull de imagem, logs e leitura do segredo do RDS --------
resource "aws_iam_role" "metabase_execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.metabase_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "read_db_secret" {
  statement {
    sid       = "ReadMetabaseDbSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.metabase_appdb.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "execution_read_secret" {
  name   = "${local.name}-read-db-secret"
  role   = aws_iam_role.metabase_execution.id
  policy = data.aws_iam_policy_document.read_db_secret.json
}

# --- Task role: permissoes do app em runtime (minimo necessario) -------------
resource "aws_iam_role" "metabase_task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# Consulta a Athena/Glue/S3 (somente leitura na origem, leitura+escrita no
# bucket de resultados). Sem esta policy, o Metabase exigiria Access/Secret
# key estaticas no formulario da UI - exatamente o que evitamos: a task
# assume esta role automaticamente via AWS Default Credentials Chain do
# driver Athena, sem nenhum segredo na UI (deixe Access key/Secret key em
# branco ao conectar).
#
# Lista de acoes do Athena e o Resource = "*" seguem literalmente a policy
# oficial da documentacao do Metabase ("Notes on connecting to Athena" /
# "Example IAM Policy"): varias acoes exigidas (ListDatabases, ListDataCatalogs,
# ListTableMetadata, GetTableMetadata) operam no nivel do catalogo/conta e nao
# aceitam ARN de workgroup - restringir so pelas que aceitam quebraria as que
# nao aceitam, sem ganho real de seguranca. Glue e S3, que suportam ARN de
# recurso de forma robusta, ficam restritos ao catalogo/database e aos dois
# buckets especificos - nunca "*".
data "aws_iam_policy_document" "athena_query_access" {
  statement {
    sid    = "AthenaQuery"
    effect = "Allow"
    actions = [
      "athena:BatchGetNamedQuery",
      "athena:BatchGetQueryExecution",
      "athena:GetNamedQuery",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetQueryResultsStream",
      "athena:GetWorkGroup",
      "athena:ListDatabases",
      "athena:ListDataCatalogs",
      "athena:ListNamedQueries",
      "athena:ListQueryExecutions",
      "athena:ListTagsForResource",
      "athena:ListWorkGroups",
      "athena:ListTableMetadata",
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
      "athena:CreatePreparedStatement",
      "athena:DeletePreparedStatement",
      "athena:GetPreparedStatement",
      "athena:GetTableMetadata",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "GlueCatalogRead"
    effect = "Allow"
    actions = [
      "glue:BatchGetPartition",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetTableVersion",
      "glue:GetTableVersions",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${local.glue_database}",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.glue_database}/*",
    ]
  }

  statement {
    sid    = "SilverBucketRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.silver.arn,
      "${aws_s3_bucket.silver.arn}/*",
    ]
  }

  statement {
    sid    = "AthenaResultsReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.athena_results.arn,
      "${aws_s3_bucket.athena_results.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "task_athena_query" {
  name   = "${local.name}-athena-query"
  role   = aws_iam_role.metabase_task.id
  policy = data.aws_iam_policy_document.athena_query_access.json
}
