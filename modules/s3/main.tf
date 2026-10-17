resource "aws_s3_bucket" "this" {
    bucket        = "${var.name_prefix}-${var.bucket_name_suffix}"
    force_destroy = var.force_destroy
    tags          = var.additional_tags
}

resource "aws_s3_bucket_public_access_block" "access_block" {
    bucket = aws_s3_bucket.this.id

    block_public_acls       = !var.is_public
    block_public_policy     = !var.is_public
    ignore_public_acls      = !var.is_public
    restrict_public_buckets = !var.is_public
}

resource "aws_s3_bucket_versioning" "bucket_versioning" {
    count  = var.enable_versioning ? 1 : 0
    bucket = aws_s3_bucket.this.id

    versioning_configuration {
      status = "Enabled"
    }
}
