# Iris infrastructure (repo 5/5)

Repository này sở hữu AWS foundation và automation cho platform MLOps: remote Terraform state,
GitHub OIDC, VPC/EKS, RDS PostgreSQL Multi-AZ, S3, SQS, ECR, IAM/IRSA, ACM và Route53 permissions.
Kubernetes desired state vẫn thuộc `iris-gitops`; AWS Load Balancer Controller tạo NLB và
ExternalDNS tự reconcile hostname `api.<domain>` vào Route53.

## Ownership

- `terraform/bootstrap`: S3/KMS state, GitHub OIDC, Terraform plan/apply roles.
- `terraform/platform`: network, compute, database, storage, registry và workload IAM.
- `environments/production.tfvars`: cấu hình production không nhạy cảm, review được bằng Git.
- `.github/workflows/terraform.yml`: validate, plan, protected apply và GitOps output PR.
- `scripts/sync_gitops_outputs.py`: render output không nhạy cảm vào repo GitOps.

## Bootstrap duy nhất chạy local

Lần đầu chưa có OIDC role cho CI, dùng AWS admin profile để tạo state và automation roles:

```bash
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
# Đặt một bucket name duy nhất toàn cầu trong terraform.tfvars.
terraform -chdir=terraform/bootstrap init -backend=false
terraform -chdir=terraform/bootstrap apply

cp terraform/bootstrap/backend.hcl.example terraform/bootstrap/backend.hcl
# Điền bucket và KMS ARN vừa được output.
terraform -chdir=terraform/bootstrap init -migrate-state \
  -backend-config=backend.hcl
```

Tạo GitHub Environment `prod`, bật required reviewer, rồi cấu hình environment variables:

```bash
./scripts/configure-github.sh \
  <state-bucket> \
  example.com \
  <route53-zone-id> \
  <eks-admin-role-arn>
```

Thêm `GITOPS_TOKEN` dưới dạng GitHub Secret. Token chỉ cần quyền tạo branch/PR trong
`chiendz11/iris-gitops`; GitHub App token ngắn hạn được ưu tiên hơn PAT dài hạn.

Sau bootstrap, pull request chạy Terraform plan. Merge vào `main` chờ approval của GitHub
Environment, apply bootstrap rồi platform, sau đó tự mở PR đồng bộ output vào `iris-gitops`.

Sau platform apply đầu tiên, cấu hình các output AWS cho ba application repository bằng một lệnh:

```bash
./scripts/configure-app-repositories.sh
```

## GitHub Variables và Secrets

Environment `prod` variables: `AWS_REGION`, `TF_STATE_BUCKET`, `TF_STATE_KMS_KEY_ARN`,
`TERRAFORM_PLAN_ROLE_ARN`, `TERRAFORM_APPLY_ROLE_ARN`, `ENABLE_PUBLIC_DOMAIN`,
`PUBLIC_DOMAIN_NAME`, `ROUTE53_ZONE_ID`, `ADMIN_ROLE_ARNS_JSON`.

Secret duy nhất pipeline hạ tầng hiện cần là `GITOPS_TOKEN` trong environment `prod`. Không lưu
AWS access key: workflow assume role bằng OIDC và trust policy chỉ chấp nhận subject của environment
`prod`. RDS password do RDS quản lý trong Secrets Manager và workload nhận qua External Secrets.

## Lưu ý quyền apply

Capstone gắn `AdministratorAccess` cho Terraform apply role vì stack phải tạo IAM, EKS, VPC, RDS
và nhiều resource type. OIDC trust chỉ cho environment `production`. Trong tổ chức production thật,
cần thêm permission boundary/SCP và thay policy này bằng policy theo account landing-zone.

Chi tiết triển khai ở [docs/AWS_DEPLOYMENT.md](docs/AWS_DEPLOYMENT.md).
