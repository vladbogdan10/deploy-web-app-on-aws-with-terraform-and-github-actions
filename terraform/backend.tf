terraform {
  backend "s3" {
    bucket  = "tfstate-a123" # name of the s3 bucket you created
    key     = "production/terraform.tfstate"
    region  = "eu-west-1" # change to your region
    encrypt = true
  }
}
