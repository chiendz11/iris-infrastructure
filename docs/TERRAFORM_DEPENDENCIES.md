# Terraform dependency map

## Root stack và state

```text
operator AWS credential
        |
        v
terraform/bootstrap  -- creates --> S3 state bucket + KMS + GitHub OIDC roles
        |                                      |
        |                                      +--> GitHub governance/config backend/state
        |                                      +--> domain backend/state
        |                                      +--> platform backend/state
        v
GitHub Environment prod
        ├── governance App token --> terraform/github-governance --> five repository rulesets
        ├── configuration App token --> terraform/github-config
        |                                  ├── non-secret Actions variables
        |                                  └── three application prod Environments
        └── AWS apply gate
             |
             v
terraform/domain     -- output --> zone ID + name servers + ACM ARN
        |                                |
        |                                +--> registrar NS delegation (external/manual gate)
        v
terraform/platform   -- reads domain.tfstate --> ExternalDNS IAM + public edge outputs
        ├── EKS Access Entry --> protected Terraform apply role
        ├── Helm provider --> Argo CD + root Application
        └── outputs --> iris-gitops PR --> Argo CD platform/workloads
```

Mỗi root stack có state key riêng trong cùng bucket được mã hóa bằng KMS:

| Root stack | State key | Phụ thuộc trước khi chạy |
|---|---|---|
| `bootstrap` | `infrastructure/bootstrap.tfstate` | AWS credential của operator ở lần đầu |
| `github-governance` | `infrastructure/github-governance.tfstate` | bucket/KMS, dedicated state roles và GitHub App |
| `github-config` | `infrastructure/github-config.tfstate` | foundation state; platform state khi đã tồn tại; configuration App |
| `domain` | `infrastructure/domain.tfstate` | bucket/KMS và Terraform CI role từ bootstrap |
| `platform` | `infrastructure/platform.tfstate` | bucket/KMS từ bootstrap; output đã sẵn sàng từ domain |

## Bootstrap resource graph

```text
aws_kms_key.terraform_state
  ├── aws_kms_alias.terraform_state
  ├── S3 state encryption configuration
  └── terraform_state_access IAM policy

aws_s3_bucket.terraform_state
  ├── versioning
  ├── public access block
  ├── TLS-only bucket policy
  └── terraform_state_access IAM policy

aws_iam_openid_connect_provider.github
  ├── exact pull_request subject → terraform_plan role (internal PR only in workflow)
  └── exact environment:prod subject → terraform_apply role
        └── prevent_destroy (identity phải ổn định; break-glass nếu trust bị hỏng)

terraform_state_access policy
  └── apply role attachment (state read/write)

terraform_state_plan_access policy
  └── plan role attachment (state read-only; write/delete only S3 `.tflock`)

github_governance_plan role
  └── read governance state + manage only its `.tflock`; pull_request OIDC subject

github_governance_apply role
  └── read/write governance state + lock; environment:prod OIDC subject
      (không có AWS AdministratorAccess)

github_config_plan role
  └── read foundation/platform/config state + manage config lock; pull_request OIDC subject

github_config_apply role
  └── read foundation/platform state + read/write config state; environment:prod OIDC subject
      (không có AWS AdministratorAccess)
```

Bootstrap phải chạy local đúng lần đầu vì GitHub chưa có IAM role để assume. Sau khi state được
migrate lên S3, CI tiếp tục reconcile stack này một cách idempotent. Lần apply đầu không có
`backend.tf`, nên Terraform dùng local state. Sau khi S3/KMS tồn tại, operator copy
`backend.tf.example` thành file git-ignored `backend.tf` và chạy `init -migrate-state`; CI cũng tự
materialize file này trước khi init bootstrap remote state.

## GitHub governance resource graph

```text
bootstrap state bucket/KMS
  ├── github_governance_plan role → governance state read/lock only
  └── github_governance_apply role → governance state read/write only

GitHub Environment prod
  ├── GOVERNANCE_APP_CLIENT_ID
  └── GOVERNANCE_APP_PRIVATE_KEY
        └── one-hour installation token (five repos, Administration write)
              └── integrations/github provider
                    └── github_repository_ruleset.main[repository]
```

The App/private key is an external root of trust and never enters Terraform variables or state.
Five existing rulesets are adopted with declarative import IDs. After adoption, normal changes are
PR → credential-free speculative plan → merge → protected refreshed plan/apply. Classic branch
protection is removed once after effective ruleset verification so Terraform becomes the only
ruleset desired-state writer.

## GitHub configuration resource graph

```text
bootstrap.tfstate
  └── state bucket/KMS + Terraform/governance/config OIDC role ARNs

platform.tfstate (conditional)
  └── ECR repository names + DVC bucket + application deploy role
      + GitOps dispatcher publisher role + model-promotion secret-reader role

iris-configuration GitHub App token
  ├── github_actions_variable.infrastructure (PR-plan metadata)
  ├── github_actions_environment_variable.infrastructure_prod
  ├── github_repository_environment.application_prod
  │     ├── protected branches only
  │     ├── admin bypass disabled
  │     ├── prevent self-review
  │     └── independent reviewer
  └── github_actions_environment_variable.application_prod
  └── github_actions_variable.gitops_model_promotion
        └── dispatcher ECR/repository + two least-privilege role ARNs + secret ARN
```

The infrastructure `prod` Environment is excluded because it releases the credential that mutates
this graph. It remains the manual root-of-trust gate. App private keys are never Terraform inputs.

## Domain resource graph

```text
var.enable_public_domain
  └── aws_route53_zone.public
        ├── route53_zone_id output
        └── route53_name_servers output → registrar delegation

CI certificate phase (`TF_VAR_domain_delegated=true`)
  └── aws_acm_certificate.public (apex + wildcard)
        └── domain_validation_options
              └── aws_route53_record.certificate_validation
                    └── aws_acm_certificate_validation.public
                          ├── public_certificate_arn output
                          └── domain_ready=true
```

Zone phase đặt `TF_VAR_domain_delegated=false`, tạo Hosted Zone và in name servers vào job summary.
Sau approval, CI truy vấn DNS công khai và chỉ đặt cờ nội bộ thành `true` nếu registrar thực sự trả
về đúng bộ NS. Script dùng chung `detect-domain-delegation.sh` chạy cả ở PR plan và apply/retry;
nếu state từng ready nhưng DNS bị drift, script fail closed để không vô tình plan xóa ACM. Cờ này
không được lưu dưới dạng GitHub Variable.

## Platform resource graph

### Network và compute

```text
data.aws_availability_zones.available
  └── local.azs
        └── module.vpc
              ├── public/private subnets
              ├── route tables/NAT
              ├── module.vpc_endpoints
              ├── module.eks
              └── aws_db_subnet_group.mlflow

module.eks
  ├── EKS managed node group
  ├── EKS add-ons
  ├── explicit operator Access Entries; cluster creator admin is disabled
  ├── Terraform apply role Access Entry → install/upgrade Argo CD
  ├── node security group → RDS ingress
  ├── OIDC provider → workload IRSA roles
  └── OIDC provider → AWS Load Balancer Controller IRSA
```

### Terraform-owned GitOps controller

```text
bootstrap remote state
  └── terraform_apply_role_arn
        └── module.eks access entry (cluster admin)

module.eks (control plane + nodes + access entry)
  └── helm_release.argocd
        ├── chart argo-cd 10.4.0
        ├── argocd-values-production.yaml
        └── extraObjects
              └── root Application → iris-gitops/applications
```

Argo CD không có self-management Application trong `iris-gitops`. Terraform Helm provider dùng
EKS exec authentication và release state để install/upgrade idempotently. Root Application được
render qua chart `extraObjects`; cách này tránh yêu cầu Terraform nhận diện Application CRD ở plan
trước khi chart kịp cài CRD.

Terraform tự suy ra các cạnh này từ tham chiếu như `module.vpc.vpc_id`; không cần `depends_on`
thủ công.

### Storage, event và registry

```text
random_id.suffix
  └── S3 buckets: dvc, mlflow, argo

DVC S3 bucket
  ├── GitHub Actions upload policy
  ├── training IRSA read/write policy
  └── S3 ObjectCreated notification
        └── SQS dataset_events
              ├── SQS policy cho phép S3 SendMessage
              ├── DLQ/redrive policy
              └── Argo Events IRSA receive/delete policy

MLflow S3 bucket
  └── MLflow IRSA artifact policy

Argo S3 bucket
  └── training/Workflow artifact policy

ECR repositories: training, mlflow, inference
  └── shared application GitHub Actions build/publish role policy

ECR repository: dispatcher
  └── dedicated iris-gitops/main OIDC publisher role
```

S3 notification có `depends_on` tường minh vào SQS policy vì AWS chỉ chấp nhận notification sau
khi queue policy đã cho phép bucket gửi message.

### Database và secret

```text
VPC private subnets → RDS subnet group
EKS node security group → RDS security group ingress :5432
RDS PostgreSQL Multi-AZ
  └── RDS-managed master secret in Secrets Manager
        └── External Secrets IRSA read policy
              ├── Kubernetes Secret cho MLflow
              └── optional explicitly-listed ARNs cho Argo CD SSO/repo credential

model-promotion GitHub App secret container
  └── operator seed/rotate `{client_id, private_key}` ngoài Terraform
        └── External Secrets IRSA read policy
              └── Secret `argo/model-promotion-github-app`
                    └── Argo chỉ mở protected GitOps PR; không patch KServe
```

RDS tự sinh và rotate-compatible master password; giá trị password không đi qua GitHub hoặc
Terraform output.

### Domain dependency

```text
data.terraform_remote_state.domain
  ├── route53_zone_id → ExternalDNS IAM policy
  ├── domain_name → ExternalDNS domain filter + KServe hostname
  └── certificate ARN → Kourier/NLB TLS annotation
```

Platform check `domain_ready`; nếu certificate chưa issued thì plan/apply dừng thay vì đưa ARN
chưa dùng được vào GitOps.

## CI orchestration dependency

```text
terraform.yml (every PR; required check)
  ├── static: fmt + validate bootstrap/governance/github-config/domain/platform + Helm render
  ├── changed-root detection
        ├── terraform/bootstrap/** → plan-foundation
        ├── terraform/github-governance/** → plan-governance (no GitHub write token)
        ├── terraform/github-config/** → plan-github-config (no GitHub write token after adoption)
        ├── terraform/domain/** or delegation helper → plan-domain
        └── platform/**, production.tfvars or GitOps sync script → plan-platform
  └── pr-gate: require static + each plan (or explicit domain-blocked platform defer)

terraform-foundation.yml (foundation path or manual retry)
  └── prod approval → reconcile bootstrap state/OIDC/IAM diff
        └── dispatch GitHub config with new state-role ARN
              ├── domain changed → dispatch domain (carry platform intent)
              └── otherwise, platform changed/apply-role ARN changed → dispatch platform

terraform-governance.yml (GitHub governance path or manual drift retry)
  └── prod approval → dedicated state role + scoped short-lived GitHub App token
        └── refreshed saved plan → delete/replace guard → apply → API verification

terraform-github-config.yml (configuration path, foundation/platform dispatch or manual)
  └── prod approval → dedicated state role + scoped configuration App token
        └── detect platform state → refreshed saved plan → Environment delete guard → apply

terraform-domain.yml (domain path, foundation dispatch or manual)
  └── prod approval → create/reconcile Route53 zone
        ├── domain state exists → derive delegation from authoritative public NS
        └── first run → publish NS → prod approval
              └── verify public DNS → create/validate ACM
                    └── if platform source or platform-consumed output changed
                          └── workflow_dispatch terraform-platform.yml

terraform-platform.yml (platform path, domain dispatch or manual)
  └── prod approval → refreshed plan/apply
        ├── AWS/EKS resources
        ├── helm_release.argocd + root Application
        ├── dispatch GitHub config to publish selected outputs
        └── export/render/open iris-gitops PR with short-lived GitOps App token
```

Foundation, domain và platform apply cùng dùng concurrency group `terraform-production`. Chúng
không mutate AWS/state song song, nhưng routing không giả định queue có thứ tự nghiệp vụ. Khi một
push chạm nhiều root, direct downstream run tự skip; foundation dispatch domain và domain dispatch
platform. Platform day-2 update không gọi hoặc refresh domain resources.

GitOps App/private key không phải Terraform dependency; workflow chỉ dùng nó để mint token ngắn hạn
ở bước mở PR sau khi AWS apply thành công. Argo CD là Terraform Helm provider dependency có
lifecycle nằm trong platform state. Sau khi
root Application tồn tại, Argo CD pull desired state từ `iris-gitops` và reconcile mọi add-on cùng
workload nhưng không reconcile chính Argo CD.

## Dependency bên ngoài Terraform

- Domain phải được mua/đăng ký trước.
- Registrar phải delegate NS sang Route53; Terraform không thể tự làm nếu registrar không có API
  hoặc provider được cấu hình.
- `iris-infrastructure/prod` phải được tạo thủ công với protected-branch policy, prevent-self-review
  và reviewer độc lập; ba app Environment sau đó do Terraform quản lý.
- Ba control-plane GitHub App phải được install đúng scope trong `github-apps/README.md`; Client ID
  là variable, private key nằm trong protected Environment và không nằm trong Terraform state.
- App runtime `iris-model-promoter` chỉ install trên `iris-gitops`; private key được seed vào secret
  container do platform Terraform tạo. External Secrets chiếu nó vào namespace `argo`; chỉ
  dispatcher image riêng nhận key để phát release intent. Workflow `model-release` của GitOps đọc
  cùng secret qua dedicated OIDC role để tạo protected PR.
- Dispatcher source nằm trong `iris-gitops`; workflow `dispatcher-image` dùng publisher OIDC role
  chỉ ghi ECR repository `dispatcher`, sau đó mở protected PR pin image digest vào WorkflowTemplate.
- GitOps repo private phải có Argo CD repository credential được External Secrets đồng bộ trước.
- Cả năm repo cần phát required aggregate check ít nhất một lần trước khi Terraform kích hoạt
  corresponding `protect-main` rule.
- Production review policy cần collaborator thứ hai; PR author không thể tự approve last push.
- Terraform apply role phải còn EKS Access Entry để Terraform refresh/upgrade Helm release.
- Application images phải tồn tại trong ECR trước khi merge image references vào GitOps.
