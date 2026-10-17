locals {
    aws_region  = "us-east-1"
    environment = "dev"

    tags = {
        Created       = "Terraform"
        Owner         = "Antonio Gomez Ruiz"
        Environment   = "dev"
        Project       = "Elysium-medical-app"
    }
}

generate "backend" {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"

    contents = <<EOF
terraform {
    backend "s3" {
        bucket       = "elysium-terraform-state-296062553018"
        key          = "dev/${path_relative_to_include()}/terraform.tfstate"
        region       = "us-east-1"
        encrypt      = true 
        use_lockfile = true
    }
    required_version = ">= 1.10.0, <2.0.0"
}
EOF
}

generate "provider" {
    path      = "provider.tf"
    if_exists = "overwrite_terragrunt"

    contents = <<EOF

provider "aws" {
    region = "${local.aws_region}"

    default_tags {
        tags = ${jsonencode(local.tags)}
    }
}
EOF
}
