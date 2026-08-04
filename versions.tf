terraform {
  required_version = "~> 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # Backend remoto obrigatório para equipe/producao.
  # S3 nativo com lockfile (Terraform 1.10+) — dispensa DynamoDB.
  #
  # Configuracao PARCIAL de proposito: "bucket" fica fora do codigo porque o
  # nome do bucket de state costuma conter o account ID, e este repositorio e
  # publico. Informe no init:
  #
  #   terraform init -backend-config=backend.hcl        (local, gitignored)
  #   terraform init -backend-config="bucket=$TF_STATE_BUCKET"   (CI)
  #
  # "key" tambem pode ser sobrescrito para isolar ambientes:
  #   -backend-config="key=metabase/prod/terraform.tfstate"
  backend "s3" {
    key          = "metabase/dev/terraform.tfstate"
    region       = "sa-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.prefix
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
