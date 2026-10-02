project_name                   = "iris-mlops"
environment                    = "prod"
vpc_cidr                       = "10.42.0.0/16"
az_count                       = 2
enable_nat_gateway             = true
single_nat_gateway             = true
enable_interface_vpc_endpoints = false
kubernetes_version             = "1.34"
# Day-0 uses AWS's default compatible build. Pin the resolved output in a
# reviewed PR before subsequent upgrades.
ebs_csi_addon_version = null
# This AWS Free Tier account rejects non-eligible instance types. In
# ap-southeast-1 c7i-flex.large keeps the original 2 vCPU/4 GiB node capacity,
# uses x86_64 images, and is offered in both selected AZs.
node_instance_types = ["c7i-flex.large"]
# Redis HA in the production Argo CD profile requires three schedulable nodes.
node_min_size     = 3
node_desired_size = 3
node_max_size     = 4
db_instance_class = "db.t4g.micro"
# The July 2025+ Free Tier account plan permits only Single-AZ RDS and limits
# automated-backup retention. The Terraform module remains Multi-AZ capable;
# set these back to true/14 after upgrading the AWS account plan.
db_multi_az              = false
db_backup_retention_days = 1
db_max_allocated_storage = null

# Add Argo CD SSO/repository credential secret ARNs when those optional
# integrations are enabled. Secret values stay in AWS Secrets Manager.
additional_external_secret_arns = []
