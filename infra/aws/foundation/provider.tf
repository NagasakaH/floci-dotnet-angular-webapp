provider "aws" {
  region = local.config.aws_region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
