project_name                   = "iris-mlops"
environment                    = "prod"
vpc_cidr                       = "10.42.0.0/16"
az_count                       = 2
enable_nat_gateway             = true
single_nat_gateway             = true
enable_interface_vpc_endpoints = false
kubernetes_version             = "1.33"
node_instance_types            = ["t3.medium"]
# Redis HA in the production Argo CD profile requires three schedulable nodes.
node_min_size     = 3
node_desired_size = 3
node_max_size     = 4
db_instance_class = "db.t4g.micro"
db_multi_az       = true

# Add Argo CD SSO/repository credential secret ARNs when those optional
# integrations are enabled. Secret values stay in AWS Secrets Manager.
additional_external_secret_arns = []
