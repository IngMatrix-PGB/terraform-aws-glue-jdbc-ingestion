################################################################################
# Least-privilege role for the job and the crawler. Every statement is scoped
# to this job's script, output prefix, secret, connection and catalog
# database; only the ENI and metric actions need "*" (AWS offers no
# resource-level permissions for them).
################################################################################

locals {
  s3_arn = "arn:${local.partition}:s3:::"

  # s3://bucket/key -> arn:aws:s3:::bucket/key
  extra_read_object_arns = [
    for uri in var.extra_py_files : "${local.s3_arn}${trimprefix(uri, "s3://")}"
  ]
  additional_read_prefix_arns = [
    for uri in var.iam_additional_read_s3_paths : "${local.s3_arn}${trimprefix(uri, "s3://")}*"
  ]

  crawler_bucket = regex("^s3://([^/]+)/?(.*)$", local.crawler_target)[0]
  crawler_prefix = regex("^s3://([^/]+)/?(.*)$", local.crawler_target)[1]

  glue_catalog_arn = "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog"
}

data "aws_iam_policy_document" "assume" {
  count = var.create_iam_role ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }

    # Confused-deputy guard: only Glue acting for this account.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "this" {
  count = var.create_iam_role ? 1 : 0

  statement {
    sid       = "ReadScriptAndLibraries"
    actions   = ["s3:GetObject"]
    resources = concat(["${local.s3_arn}${var.scripts_bucket}/${local.script_key}"], local.extra_read_object_arns, local.additional_read_prefix_arns)
  }

  statement {
    sid       = "ListOutputPrefix"
    actions   = ["s3:ListBucket"]
    resources = ["${local.s3_arn}${local.output_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [local.output_prefix, "${local.output_prefix}*"]
    }
  }

  statement {
    sid       = "WriteOutputPrefix"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    resources = ["${local.s3_arn}${local.output_bucket}/${local.output_prefix}*"]
  }

  statement {
    sid       = "ReadSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.secret_arn]
  }

  dynamic "statement" {
    for_each = var.secret_kms_key_arn != null ? [1] : []
    content {
      sid       = "DecryptSecret"
      actions   = ["kms:Decrypt"]
      resources = [var.secret_kms_key_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${local.region}.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.rds_iam_auth_resource_arns) > 0 ? [1] : []
    content {
      sid       = "RdsIamAuth"
      actions   = ["rds-db:connect"]
      resources = var.rds_iam_auth_resource_arns
    }
  }

  dynamic "statement" {
    for_each = var.create_connection ? [1] : []
    content {
      sid     = "ReadConnection"
      actions = ["glue:GetConnection"]
      resources = [
        local.glue_catalog_arn,
        "arn:${local.partition}:glue:${local.region}:${local.account_id}:connection/${local.connection_name}",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.create_connection ? [1] : []
    content {
      sid = "VpcNetworkInterfaces"
      actions = [
        "ec2:CreateNetworkInterface",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs",
        "ec2:DescribeVpcAttribute",
        "ec2:DescribeVpcEndpoints",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
      ]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.create_connection ? [1] : []
    content {
      # Glue tags the ENIs it creates; nothing else.
      sid       = "TagGlueNetworkInterfaces"
      actions   = ["ec2:CreateTags", "ec2:DeleteTags"]
      resources = ["arn:${local.partition}:ec2:*:*:network-interface/*"]

      condition {
        test     = "ForAllValues:StringEquals"
        variable = "aws:TagKeys"
        values   = ["aws-glue-service-resource"]
      }
    }
  }

  statement {
    sid     = "GlueLogs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws-glue/*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws-glue/*:log-stream:*",
    ]
  }

  statement {
    sid       = "GlueMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Glue"]
    }
  }

  dynamic "statement" {
    for_each = var.create_crawler ? [1] : []
    content {
      sid       = "CrawlerListTarget"
      actions   = ["s3:ListBucket"]
      resources = ["${local.s3_arn}${local.crawler_bucket}"]

      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = [local.crawler_prefix, "${local.crawler_prefix}*"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.create_crawler ? [1] : []
    content {
      sid       = "CrawlerReadTarget"
      actions   = ["s3:GetObject"]
      resources = ["${local.s3_arn}${local.crawler_bucket}/${local.crawler_prefix}*"]
    }
  }

  dynamic "statement" {
    for_each = var.create_crawler ? [1] : []
    content {
      sid = "CrawlerCatalog"
      actions = concat(
        [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:BatchGetPartition",
          "glue:CreatePartition",
          "glue:BatchCreatePartition",
          "glue:UpdatePartition",
          "glue:BatchUpdatePartition",
        ],
        # Only granted when the schema change policy may drop catalog objects.
        var.crawler_schema_change_delete_behavior == "LOG" ? [] : [
          "glue:DeleteTable",
          "glue:BatchDeleteTable",
          "glue:DeletePartition",
          "glue:BatchDeletePartition",
        ],
      )
      resources = [
        local.glue_catalog_arn,
        "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/${coalesce(var.crawler_database_name, "-")}",
        "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/${coalesce(var.crawler_database_name, "-")}/*",
      ]
    }
  }
}

resource "aws_iam_role" "this" {
  count = var.create_iam_role ? 1 : 0

  name                 = "${var.name}-glue"
  description          = "Glue JDBC ingestion job ${var.name}"
  assume_role_policy   = data.aws_iam_policy_document.assume[0].json
  permissions_boundary = var.iam_role_permissions_boundary

  tags = var.tags
}

resource "aws_iam_role_policy" "this" {
  count = var.create_iam_role ? 1 : 0

  name   = "glue-jdbc-ingestion"
  role   = aws_iam_role.this[0].id
  policy = data.aws_iam_policy_document.this[0].json
}
