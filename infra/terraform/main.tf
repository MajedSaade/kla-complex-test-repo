# Updated: 2026-06-15T16:56:47Z
terraform {
  required_version = ">= 1.5.0"
}
module "networking" {
  source = "./modules/networking"
}

