# Provision AWS instance.

## Requirements 

- The steps below were successfully tested using:
    - Terraform (0.14.4)

#### Install Terraform

- Go to [url](https://learn.hashicorp.com/tutorials/terraform/install-cli)

#### AWS Credentials.
- Create a credential file at `~/.aws/credentials` or override the provider in `aws/main.tf`

```
[default]
aws_access_key_id = XXXX
aws_secret_access_key = XXXX
```
#### SSH Credentials.
- In `aws/main.tf`the private key and the public keys are assumed to be in the standard location

```
variable "public_key_path" {
  default = "~/.ssh/id_rsa.pub"
}

```

#### Create AWS instance: 

Note: Terraform creates some folders and files to maintain the state. 
      Once terraform is applied, you can see them using <i>ls -a aws</i>

```sh
cd provision

# This will install the aws provider. 
terraform -chdir=aws init

# Validate the terraform scripts' syntax
terraform -chdir=aws validate

# View the plan that is going to be created.
# This is very useful as it will also search for the elastic ip using 
# the supplied eip_alloc_id. And would fail if it does not find it.
terraform -chdir=aws plan

# This will create the vpc, security group and the instance
terraform -chdir=aws apply

# To view the outputs
terraform -chdir=aws output 

#To view what was deployed:
terraform -chdir=aws show 
```

#### Access AWS Instance: 

```sh
export HOST=`terraform -chdir=aws output -raw public_ip`
export PRIVATE_KEY="~/.ssh/id_rsa"

ssh -o StrictHostKeyChecking=no -i $PRIVATE_KEY ubuntu@$HOST
docker ps
which docker-compose
```

#### Destroy AWS instance:

Destroy when done.

Note: The terraform state is stored in the directory aws. 
      Do not lose it or delete it

```
terraform -chdir=aws destroy
```
