# Updated: 2026-06-14T22:24:27Z
terraform {
  required_version = ">= 1.5.0"
}
module "networking" {
  source = "./modules/networking"
}

