################################################################################
# Crawler: catalogs the schema. The job overwrites the data and Athena reads
# it right away, so the crawler only matters when columns or tables change.
################################################################################

locals {
  crawler_target = coalesce(var.crawler_s3_target_path, var.output_s3_path)

  crawler_configuration = jsonencode(merge(
    {
      Version = 1.0
      # Keep table properties set outside the crawler (e.g. partition
      # projection) instead of replacing the whole table definition.
      CrawlerOutput = {
        Tables = { AddOrUpdateBehavior = "MergeNewColumns" }
      }
    },
    var.crawler_table_level != null ? { Grouping = { TableLevelConfiguration = var.crawler_table_level } } : {},
  ))
}

resource "aws_glue_crawler" "this" {
  count = var.create_crawler ? 1 : 0

  name          = local.crawler_name
  role          = local.role_arn
  database_name = var.crawler_database_name
  # A chained crawler has no cron of its own: the conditional trigger starts it.
  schedule      = var.chain_crawler ? null : var.crawler_schedule
  configuration = local.crawler_configuration

  s3_target {
    path       = local.crawler_target
    exclusions = var.crawler_exclusions
  }

  schema_change_policy {
    update_behavior = var.crawler_schema_change_update_behavior
    delete_behavior = var.crawler_schema_change_delete_behavior
  }

  tags = var.tags

  # CreateCrawler checks the role; wait for its policy (IAM is eventually consistent).
  depends_on = [aws_iam_role_policy.this]
}

resource "aws_glue_trigger" "crawler_on_job_success" {
  count = var.create_crawler && var.chain_crawler ? 1 : 0

  name = "${var.name}-crawl-ok"
  type = "CONDITIONAL"

  actions {
    crawler_name = aws_glue_crawler.this[0].name
  }

  predicate {
    conditions {
      job_name         = aws_glue_job.this.name
      state            = "SUCCEEDED"
      logical_operator = "EQUALS"
    }
  }

  tags = var.tags
}

# Glue rejects two conditions on the same job in one predicate ("Conditions
# contain duplicate job name"), so the FAILED case is a separate trigger.
resource "aws_glue_trigger" "crawler_on_job_failure" {
  count = var.create_crawler && var.chain_crawler && var.crawler_on_job_failure ? 1 : 0

  name = "${var.name}-crawl-ko"
  type = "CONDITIONAL"

  actions {
    crawler_name = aws_glue_crawler.this[0].name
  }

  predicate {
    conditions {
      job_name         = aws_glue_job.this.name
      state            = "FAILED"
      logical_operator = "EQUALS"
    }
  }

  tags = var.tags
}
