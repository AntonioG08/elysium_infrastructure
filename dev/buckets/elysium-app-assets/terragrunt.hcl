include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/s3"
}

inputs = {
  bucket_name_suffix = "elysium-app-assets-296062553018"
  name_prefix        = "dev"

  enable_versioning          = false
  is_public                  = false
  force_destroy              = false
  enable_intelligent_tiering = false

  additional_tags = {}
}
