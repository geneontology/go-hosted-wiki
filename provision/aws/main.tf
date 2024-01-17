variable "tags" {
  type = map
  default = { Name = "go-hosted-wiki" }
}

variable "instance_type" {
  default = "t2.micro"
}

variable "disk_size" {
  default = 100
  description = "size of disk in Gigabytes"
}

variable "public_key_path" {
  default = "~/SSH/go-ssh.pub"
}

provider "aws" {
  region = "us-east-1" 
  shared_credentials_files = [ "~/.aws/credentials" ]
  profile = "default"
}

module "base" {
  source = "git::https://github.com/geneontology/devops-aws-go-instance.git?ref=V2.0"
  instance_type = var.instance_type
  public_key_path = var.public_key_path
  tags = var.tags
  open_ports = [8080, 80, 22]
  disk_size = var.disk_size
}

output "public_ip" {
   value                  = module.base.public_ip
}
