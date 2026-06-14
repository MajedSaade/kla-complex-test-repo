# Updated: 2026-06-14T23:25:55Z
terraform {
  required_version = ">= 1.5.0"
}
module "networking" {
  source = "./modules/networking"
}

