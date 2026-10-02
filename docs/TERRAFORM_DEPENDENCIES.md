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
        ├── EKS OIDC --> EBS CSI IRSA + scoped policy --> EKS EBS CSI add-on
        ├── Helm provider --> Argo CD + root Application
        └── platform-contract-v1 --> GitOps renderer PR --> Argo CD platform/workloads
```

Argo CD Helm install also waits for the EBS CSI add-on. GitOps then reconciles the non-default
`iris-training-gp3` StorageClass; Argo Workflows creates per-run PVCs and CSI dynamically creates
their PV/EBS volumes. These runtime disks are not Terraform state resources. CSI uses
WaitForFirstConsumer for AZ selection; the 1Gi training workspace is deleted on workflow
completion (success or failure), while durable artifacts stay in S3/MLflow.

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
  └── ECR repository names + DVC bucket + three component-scoped application publisher roles
      + release-automation publisher role + GitOps automation secret-reader role

iris-configuration GitHub App token
  ├── github_actions_variable.infrastructure (PR-plan metadata)
  ├── github_actions_environment_variable.infrastructure_prod
  ├── github_repository_environment.application_prod
  │     ├── protected branches only
  │     ├── admin bypass disabled
  │     ├── allow self-review (prevent_self_review=false)
  │     └── required deployment reviewer: personal github_owner
  └── github_actions_environment_variable.application_prod
  └── github_actions_variable.gitops_automation
        └── release-automation ECR/repository + two least-privilege role ARNs + secret ARN
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

Zone phase đầu tiên đặt `TF_VAR_domain_delegated=false`, tạo Hosted Zone và in NS sau prod approval.
Workflow tự dispatch certificate run riêng, vẫn dùng `prod`; bạn đổi NS rồi approve run mới.
Sau approval, CI poll DNS công khai có thời hạn và chỉ đặt cờ nội bộ thành `true` nếu public DNS trả
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
        └── argocd-values-production.yaml
              └── installs Argo CD CRDs/controllers
                    └── helm_release.argocd_root
                          └── root Application → iris-gitops/applications
```

Argo CD không có self-management Application trong `iris-gitops`. Terraform Helm provider dùng
EKS exec authentication và release state để install/upgrade idempotently. Root Application nằm
trong local chart/release riêng, phụ thuộc tường minh vào controller release. Cạnh này bắt buộc API
server đăng ký `applications.argoproj.io` trước khi Helm build/validate custom resource.

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
  ├── data-pipeline OIDC role -> chỉ training ECR + DVC bucket
  ├── model-registry OIDC role -> chỉ mlflow ECR
  └── inference-service OIDC role -> chỉ inference ECR

ECR repository: dispatcher
  └── physical compatibility name for the release-automation image
        └── dedicated iris-gitops/main OIDC publisher role
```

S3 notification có `depends_on` tường minh vào SQS policy vì AWS chỉ chấp nhận notification sau
khi queue policy đã cho phép bucket gửi message.

### Database và secret

```text
VPC private subnets → RDS subnet group
EKS node security group → RDS security group ingress :5432
RDS PostgreSQL (Single-AZ trong Free Tier profile; module hỗ trợ Multi-AZ)
  └── RDS-managed master secret in Secrets Manager
        └── External Secrets IRSA read policy
              ├── Kubernetes Secret cho MLflow
              └── optional explicitly-listed ARNs cho Argo CD SSO/repo credential

model-release-publisher GitHub App secret container
  └── operator seed/rotate `{client_id, private_key}` ngoài Terraform
        └── External Secrets IRSA read policy
              └── chỉ release-intent dispatcher Pod nhận Actions-only credential

gitops-automation GitHub App secret container
  └── dedicated iris-gitops/main OIDC role read policy
        └── trusted renderer workflows mở protected GitOps PR
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

Workflow platform/handoff dùng `require-domain-ready.sh` để đọc domain readiness từ state và chặn
khi chưa ready/khác domain cấu hình. Không chỉ dựa vào Terraform `check`, vì check có thể chỉ cảnh báo.

## CI orchestration dependency

PR: `terraform.yml` → shared path classifier → static checks + changed-root plans → `pr-gate`.
Apply: `production-infra.yml` → selected reusable workflows, dependency bằng `needs` trong một run.

```text
select → foundation? → governance? → github-config-before? → domain?
                                                           ├─ delegation required → certificate run riêng
                                                           │   approve → verify DNS → ACM → orchestrator scope=platform
                                                           └─ ready/unchanged dependency
                                                              → platform? → github-config-after → handoff
                                                                                                → GitOps PR
```

Stage có dấu `?` chỉ chạy khi classifier hoặc output upstream yêu cầu. Platform-only không chạy
foundation/domain. `github-config-before` và `github-config-after` gọi cùng một reusable workflow.
Foundation context truyền trực tiếp các selected ARN/backend outputs, không chờ vars refresh trong
cùng run. Handoff không nhận arbitrary contract; đọc state, kiểm tra no-diff plan, build/validate JSON,
verify hai runtime secret có AWSCURRENT, rồi dedicated App dispatch GitOps receiver.

Orchestrator và certificate entrypoint giữ outer concurrency `terraform-production`; reusable không
giữ cùng lock. Certificate dispatch không chờ workflow con hoàn thành. GitHub concurrency không
bảo đảm FIFO hoặc lưu mọi pending run; xem giới hạn/recovery tại `WORKFLOW_ORCHESTRATION.md`.
Guard chặn SHA lỗi thời trước credentials, sau plan/trước apply và trước publication.

GitOps renderer tự mở protected PR. Argo CD controller/root Application thuộc Terraform platform
state; Argo CD không reconcile chính nó. Workflow apply thành công không có nghĩa mọi workload đã
Ready. App publish và training/model lifecycle vẫn độc lập.

## Dependency bên ngoài Terraform## Dependency bên ngoài Terraform

- Domain phải được mua/đăng ký trước.
- Registrar phải delegate NS sang Route53; Terraform không thể tự làm nếu registrar không có API
  hoặc provider được cấu hình.
- `iris-infrastructure/prod` được cấu hình ngoài Terraform: protected-branch policy, owner reviewer,
  `prevent_self_review=false`; ba app Environment do Terraform quản lý với cùng owner self-approval.
- Bảy GitHub App phải được install đúng scope trong `github-apps/README.md`; Client ID là variable,
  private key nằm trong protected owner boundary và không nằm trong Terraform state.
- Inference, model-registry, in-cluster model release và platform contract dùng bốn publisher App
  khác nhau, tất cả chỉ install trên `iris-gitops` với Actions write. Receiver kiểm tra actor theo
  component; các key không được chia sẻ giữa producer.
- `iris-gitops-automation` chỉ install trên `iris-gitops`; trusted receiver workflows đọc key từ
  container riêng qua dedicated OIDC role để tạo protected PR.
- Release-automation source nằm trong `iris-gitops`; workflow image publisher chỉ ghi physical ECR
  repository `dispatcher`, sau đó renderer mở protected PR pin image digest.
- GitOps repo private phải có Argo CD repository credential được External Secrets đồng bộ trước.
- Cả năm repo cần phát required aggregate check ít nhất một lần trước khi Terraform kích hoạt
  corresponding `protect-main` rule.
- Solo policy không cần collaborator; PR, CI, protected branches và no-bypass vẫn giữ. Xem SOLO_OPERATION.md.
- Terraform apply role phải còn EKS Access Entry để Terraform refresh/upgrade Helm release.
- Application images phải tồn tại trong ECR trước khi merge workload-release PR vào GitOps. ECR
  repository được platform contract allow-list; app intent chỉ được thay digest trong repository
  được cấp cho component đó.
