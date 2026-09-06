# Iris infrastructure (repo 5/5)

Repository này sở hữu AWS foundation và automation cho platform MLOps: remote Terraform state,
GitHub OIDC, public Route53/ACM domain, VPC/EKS, RDS PostgreSQL Multi-AZ, S3, SQS, ECR và IAM/IRSA.
Repo này cũng sở hữu Helm release Argo CD và root Application. Desired state phía trên Argo CD
thuộc `iris-gitops`; AWS Load Balancer Controller tạo NLB và ExternalDNS tự reconcile hostname
`api.<domain>` vào Route53.

## Ownership

- `terraform/bootstrap`: S3/KMS state, GitHub OIDC Terraform roles và các role state-only riêng cho
  GitHub governance/configuration.
- `terraform/github-governance`: source of truth cho `protect-main` ruleset của cả năm repository.
- `terraform/github-config`: source of truth cho non-secret GitHub Variables và ba application
  Environment `prod`; root `iris-infrastructure/prod` vẫn là trust gate thủ công.
- `terraform/domain`: public Route53 Hosted Zone, apex/wildcard ACM certificate và DNS validation.
- `terraform/platform`: network, EKS, database, storage, registry, workload IAM,
  `helm_release.argocd` và root Application.
- `environments/production.tfvars`: cấu hình production không nhạy cảm, review được bằng Git.
- `.github/workflows/terraform.yml`: required PR gate, validate toàn bộ và bắt buộc plan mọi root
  stack đã đổi; platform chỉ được defer khi cùng PR còn phải tạo domain trước.
- `.github/workflows/terraform-foundation.yml`: protected apply cho state/KMS/OIDC/IAM foundation
  sau khi thay đổi `terraform/bootstrap/**` được merge; `workflow_dispatch` dùng để retry/reconcile.
- `.github/workflows/terraform-domain.yml`: Route53/ACM lifecycle và DNS delegation gate.
- `.github/workflows/terraform-governance.yml`: import/reconcile GitHub rulesets bằng GitHub App
  token ngắn hạn sau approval `prod`.
- `.github/workflows/terraform-github-config.yml`: đồng bộ output foundation/platform sang GitHub
  Variables và enforce production reviewer bằng GitHub App token ngắn hạn.
- `.github/workflows/terraform-platform.yml`: day-2 platform apply và GitOps output PR.
- `scripts/sync_gitops_outputs.py`: render output không nhạy cảm vào repo GitOps.
- `scripts/migrate-rulesets.sh`: verify ruleset và chỉ xóa classic branch protection cũ khi operator
  truyền rõ `--remove-legacy`; script không tạo hoặc cập nhật desired ruleset.
- `.github/dependabot.yml`: PR định kỳ cho pin GitHub Actions và Terraform providers.

## Bootstrap duy nhất chạy local

Lần đầu chưa có OIDC role cho CI, dùng AWS admin profile để tạo state và automation roles:

```bash
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
# Đặt một bucket name duy nhất toàn cầu trong terraform.tfvars.
terraform -chdir=terraform/bootstrap init -backend=false
terraform -chdir=terraform/bootstrap apply

cp terraform/bootstrap/backend.tf.example terraform/bootstrap/backend.tf
cp terraform/bootstrap/backend.hcl.example terraform/bootstrap/backend.hcl
# Điền bucket và KMS ARN vừa được output.
terraform -chdir=terraform/bootstrap init -migrate-state \
  -backend-config=backend.hcl
```

Mời reviewer độc lập vào repo, rồi tạo/cấu hình root Environment `prod` và seed variables:

```bash
./scripts/configure-github.sh \
  example.com \
  <eks-admin-role-arn> \
  '["mentor-github-login"]'
```

Script day-0 tự đọc state bucket, KMS ARN và CI role ARN từ output bootstrap. Từ lần reconcile
`terraform/github-config` đầu tiên, Terraform tiếp quản các biến không nhạy cảm và không chạy lại
script cho update thông thường. Sau đó chạy
`terraform-domain.yml` bằng Actions UI hoặc GitHub CLI. Workflow tạo Hosted Zone và công bố
`route53_name_servers`; cập nhật chúng tại registrar rồi approve job certificate đang chờ ở
Environment `prod`. Job tự so sánh DNS công khai trước khi tạo ACM. Khi domain hoàn tất, workflow
so sánh fingerprint của domain name, readiness, zone ID và certificate ARN trước/sau; chỉ dispatch
`terraform-platform.yml` khi output mà platform dùng thay đổi hoặc cùng commit có source platform.

`Dispatch platform` nghĩa là domain job dùng repository `GITHUB_TOKEN` để yêu cầu GitHub tạo một
workflow run mới của `terraform-platform.yml`; domain workflow không tự chạy code Terraform
platform. Run mới vẫn phải qua concurrency lock, Environment `prod` approval và authoritative
platform plan trước khi apply.

```bash
gh workflow run terraform-domain.yml --repo chiendz11/iris-infrastructure --ref main
```

Tạo ba GitHub App control-plane cho governance, configuration và source-repo GitOps PR, cùng App
runtime `iris-model-promoter` chỉ phục vụ release dispatch và model-rollout PR; không dùng
`GITOPS_TOKEN`/PAT dài hạn.
Manifest quyền, phạm vi install và nơi đặt Client ID/private key nằm ở
[`docs/GITHUB_CONTROL_PLANE.md`](docs/GITHUB_CONTROL_PLANE.md). Quy trình import/migration ruleset
nằm tại [`docs/GITHUB_GOVERNANCE.md`](docs/GITHUB_GOVERNANCE.md).

Sau bootstrap, PR workflow luôn chạy để branch protection có required check, nhưng chỉ plan stack
thực sự thay đổi. Apply lifecycle được tách biệt:

```text
terraform/bootstrap/**  -> terraform-foundation.yml
terraform/github-governance/** -> terraform-governance.yml
terraform/github-config/** -> terraform-github-config.yml
terraform/domain/**     -> terraform-domain.yml -> downstream platform dispatch
detect-domain script    -> terraform-domain.yml
terraform/platform/**   -> terraform-platform.yml
production.tfvars       -> terraform-platform.yml
sync-gitops script      -> terraform-platform.yml
docs only               -> không có apply
```

Ba AWS apply workflow dùng chung concurrency group để không chạy đồng thời; hai GitHub control-plane
root có state và concurrency group riêng.
Platform update như node count, EKS add-on, RDS, IAM hay Argo CD không chạy domain workflow. Domain
update có chiều phụ thuộc xuống platform vì certificate ARN/zone ID mới phải được đồng bộ vào
GitOps. Platform apply tạo EKS, sau đó Helm provider cài hoặc nâng cấp Argo CD và root Application;
cuối job CI mở PR đồng bộ output AWS không nhạy cảm vào `iris-gitops`.

Nếu một merge chạm nhiều root, path-trigger vẫn có thể tạo nhiều workflow run nhưng các run phía
sau tự nhường quyền. Chuỗi duy nhất được phép mutate là:

```text
foundation apply
  └── dispatch github-config để publish IAM/state output mới
        └── domain changed? dispatch domain
              └── platform changed/output domain changed? dispatch platform
        └── không có domain nhưng platform changed? dispatch platform

platform apply
  └── dispatch github-config để publish ECR/DVC/deploy-role/dispatcher output mới
  └── mở GitOps output PR bằng token ngắn hạn
```

GitHub concurrency chỉ serialize, không được dùng để suy đoán thứ tự queue; routing trên mới giữ
đúng dependency `foundation → GitHub config → domain → platform`.

Tên thư mục `terraform/bootstrap` mô tả vai trò day-0 của root stack. Sau khi state đã migrate,
`terraform-foundation.yml` vẫn chạy `plan`/`apply` bình thường trên remote state và chỉ reconcile
diff; nó không tạo lại các resource không đổi. Ví dụ thêm một IAM role vào root này sẽ đi qua
`plan-foundation` ở PR, merge `main`, approval `prod`, rồi apply đúng role mới. Không có thao tác
"bootstrap lại". Environment `prod` là approval gate nên merge PR tự tạo apply run, không yêu cầu
operator dispatch thêm.

Ownership phải giữ cố định:

```text
Terraform: AWS + EKS + Argo CD Helm release + root Application
Argo CD:    AppProject + add-ons + platform configuration + workloads
```

Để nâng Argo CD, sửa duy nhất
`terraform/platform/argocd-chart-version.txt`, mở infrastructure PR, xem speculative plan và Helm
render, sau đó merge và approve job `terraform-platform` qua `prod`. Terraform refreshed plan sẽ
nâng `helm_release.argocd`;
không tạo GitOps PR cho version của Argo CD.

Nếu muốn retry hoặc chủ động kiểm tra drift của foundation mà không có commit mới:

```bash
gh workflow run terraform-foundation.yml \
  --repo chiendz11/iris-infrastructure \
  --ref main \
  --field source=manual
```

Lần bootstrap đầu tiên vẫn phải chạy local vì trước đó chưa có OIDC role để GitHub Actions assume.
Từ lần thứ hai: foundation PR → plan → merge → `prod` approval → apply diff.

## GitHub ruleset as code

Ruleset của cả năm repository được khai báo trong `terraform/github-governance`. Các ruleset
`protect-main` đã tồn tại được nhận vào state bằng Terraform `import` block, không tạo bản thứ hai.
Mỗi thay đổi day-2 đi theo flow:

```text
governance PR -> plan-governance (không có GitHub write token) -> pr-gate
              -> merge main -> approval prod -> short-lived App token
              -> refreshed saved plan -> destructive-plan guard -> apply -> verify
```

Policy yêu cầu một approval, CODEOWNER, dismiss stale review, last-push approval, resolved
conversation, linear history, check strict từ đúng GitHub Actions App và cấm force-push/delete.
Không có permanent bypass actor. Vì GitHub cộng dồn classic branch protection và ruleset, sau lần
apply/verify đầu phải chạy một lần `scripts/migrate-rulesets.sh --remove-legacy` để xóa classic rule
cũ ở `iris-infrastructure` và `iris-gitops`.

Một người không thể tự approve PR của chính mình. Cấu hình production này yêu cầu mời mentor hoặc
collaborator thứ hai; không thêm admin bypass chỉ để làm bài chạy được.

Không dùng `static` làm required check: `pr-gate` tổng hợp kết quả và fail nếu một root đã đổi nhưng
plan tương ứng bị skip (ví dụ thiếu OIDC plan role hoặc PR đến từ fork). Trạng thái platform được
ghi rõ là `planned` hoặc `deferred`; `deferred` chỉ hợp lệ khi cùng PR có domain dependency chưa
thể tồn tại trước merge.

Sau platform apply, workflow tự dispatch `terraform-github-config.yml`; không cần chạy
`configure-app-repositories.sh`. Script cũ chỉ còn break-glass và mặc định từ chối chạy để tránh
tạo configuration drift ngoài Terraform.

## GitHub Variables và Secrets

Repository variables và Environment `prod` variables: `AWS_REGION`, `TF_STATE_BUCKET`,
`TF_STATE_KMS_KEY_ARN`,
`TERRAFORM_PLAN_ROLE_ARN`, `TERRAFORM_APPLY_ROLE_ARN`, `ENABLE_PUBLIC_DOMAIN`,
`PUBLIC_DOMAIN_NAME`, `ADMIN_ROLE_ARNS_JSON`, `TF_GOVERNANCE_PLAN_ROLE_ARN` và
`TF_GOVERNANCE_APPLY_ROLE_ARN`, `TF_GITHUB_CONFIG_PLAN_ROLE_ARN` và
`TF_GITHUB_CONFIG_APPLY_ROLE_ARN`.

Metadata không nhạy cảm được ghi ở cả hai scope: PR plan cần repository scope để không bị xem như
một production deployment; apply dùng Environment scope sau approval. Plan role chỉ tin OIDC
subject `pull_request`, job từ fork bị chặn; apply role chỉ tin subject `environment:prod`.

Pipeline không lưu AWS access key: workflow assume role bằng OIDC và trust policy chỉ chấp nhận
subject của environment `prod`. RDS password do RDS quản lý trong Secrets Manager và workload nhận
qua External Secrets.
SSO/repository token tùy chọn nằm trong Secrets Manager; Terraform chỉ nhận ARN qua
`additional_external_secret_arns`, không nhận secret value.

GitHub governance, configuration và GitOps bot dùng ba App riêng. Client ID là variable; private key
là Environment secret. Workflow mint installation token có hạn một giờ và scope đúng repo/quyền của
từng nhiệm vụ. Private key, token và mọi secret value không đi qua Terraform variable/tfvars/state.
Đây là credential quản trị GitHub, không phải runtime secret của Kubernetes nên không seed sang AWS
Secrets Manager.

Platform workflow kiểm tra App token có quyền push vào `iris-gitops` và checkout với
`persist-credentials: false`, nên token không nằm lại trong Git config. Các GitHub Action có
quyền OIDC/secret đều được pin full commit SHA; cập nhật action phải đi qua Dependabot/Renovate PR
hoặc PR review thủ công.

## Lưu ý quyền apply

Capstone gắn `AdministratorAccess` cho Terraform apply role vì stack phải tạo IAM, EKS, VPC, RDS
và nhiều resource type. OIDC trust chỉ cho environment `prod`. Trong tổ chức production thật,
cần thêm permission boundary/SCP và thay policy này bằng policy theo account landing-zone.

Plan role hiện dùng AWS `ReadOnlyAccess` và chỉ chạy cho branch nội bộ của chính repository. Đây
vẫn chưa phải trust boundary đủ mạnh cho contributor không tin cậy, vì PR có thể sửa HCL/workflow.
Công ty nên dùng managed Terraform runner/required workflow không sửa được bởi app team hoặc thêm
approval riêng trước cloud plan, đồng thời sinh least-privilege plan policy thay `ReadOnlyAccess`.

Foundation stack đang quản lý chính Terraform apply role. Không rename/xóa role đó như một thay đổi
day-2 thông thường; resource có `prevent_destroy`. Nếu trust policy hoặc role bị hỏng khiến CI
không assume được, dùng credential break-glass của operator để `terraform init` với remote backend
và apply lại root
`terraform/bootstrap`, sau đó chạy lại `configure-github.sh` để refresh ARN trong GitHub Variables.

Chi tiết triển khai ở [docs/AWS_DEPLOYMENT.md](docs/AWS_DEPLOYMENT.md) và sơ đồ phụ thuộc đầy đủ
ở [docs/TERRAFORM_DEPENDENCIES.md](docs/TERRAFORM_DEPENDENCIES.md). GitHub control plane nằm ở
[docs/GITHUB_CONTROL_PLANE.md](docs/GITHUB_CONTROL_PLANE.md); ruleset lifecycle và break-glass ở
[docs/GITHUB_GOVERNANCE.md](docs/GITHUB_GOVERNANCE.md).
