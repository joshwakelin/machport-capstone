terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = var.region

  # Every resource gets this tag, so mp-start, mp-stop and mp-check can find them all.
  default_tags {
    tags = {
      Project = "machport-capstone"
    }
  }
}
