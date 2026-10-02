# Iris infrastructure (repo 5/5)

Repository này sở hữu AWS foundation và automation cho platform MLOps: remote Terraform state,
GitHub OIDC, public Route53/ACM domain, VPC/EKS, configurable RDS PostgreSQL, S3, SQS, ECR và IAM/IRSA.
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
  Profile triển khai hiện tại chịu guardrail của AWS Free Tier: EC2 eligible instance type,
  RDS Single-AZ, backup một ngày và không storage autoscaling. Terraform vẫn hỗ trợ bật lại
  Multi-AZ/retention dài khi account được nâng cấp.
- `.github/workflows/terraform.yml`: required PR gate, validate toàn bộ và bắt buộc plan mọi root
  stack đã đổi; platform chỉ được defer khi cùng PR còn phải tạo domain trước.
- `.github/workflows/production-infra.yml`: orchestrator duy nhất nhận push main; chọn stage
  bằng một bộ phân loại chung với PR, điều phối qua `needs` và gọi `reusable-*.yml` cùng commit.
- `.github/workflows/reusable-*.yml`: foundation, governance, github-config, domain, certificate,
  platform và handoff; mỗi job có OIDC/prod gate, không tự route/dispatch các stage hạ tầng.
- `.github/workflows/terraform-domain-certificate.yml`: entrypoint riêng sau đổi NS, gọi reusable
  certificate qua prod approval, rồi tiếp tục orchestrator với `scope=platform`.
- `contracts/platform-contract-v1.schema.json`: API version hóa giữa Terraform producer và GitOps
  renderer; `scripts/build_platform_contract.py` chỉ ánh xạ output đã chọn vào API này.
- `scripts/migrate-rulesets.sh`: verify ruleset và chỉ xóa classic branch protection cũ khi operator
  truyền rõ `--remove-legacy`; script không tạo hoặc cập nhật desired ruleset.
- `.github/dependabot.yml`: PR định kỳ cho pin GitHub Actions và Terraform providers.

## Bootstrap duy nhất chạy local

Nếu PR thất bại với `Not authorized to perform sts:AssumeRoleWithWebIdentity`,
đối chiếu subject có immutable ID với IAM trust theo [OIDC_RECOVERY.md](docs/OIDC_RECOVERY.md).
Không mở wildcard hoặc tắt required check để bỏ qua lỗi xác thực.

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

Tạo/cấu hình root Environment `prod` và seed variables cho profile solo:

```bash
./scripts/configure-github.sh \
  example.com \
  <eks-admin-role-arn>
```

Script day-0 tự đọc output bootstrap để seed metadata CI. Sau khi tạo/install các GitHub Apps và
đặt đúng Environment secrets theo [GITHUB_CONTROL_PLANE.md](docs/GITHUB_CONTROL_PLANE.md), merge
PR hạ tầng đã qua CI. `production-infra.yml` tự chọn những root có thay đổi.
Nếu code đã trên main, có thể chạy thủ công một lần `scope=all` sau khi root-of-trust sẵn sàng.

```bash
gh workflow run production-infra.yml --repo chiendz11/iris-infrastructure --ref main --field scope=all
```

Lần tạo zone đầu tiên, stage domain in nameserver và dispatch certificate run riêng. Bạn đổi NS
tại registrar rồi approve run đó; chỉ sau khi DNS và ACM hợp lệ mới tiếp tục platform.
Mọi deployment job dùng `prod`; không tạo Environment staging/dev mới.

Sau bootstrap, thư mục `terraform/bootstrap` vẫn là cùng root/state. Foundation apply chỉ reconcile
diff, không tạo lại backend/IAM không đổi. Update node/RDS chỉ chọn platform, không chạy lại DNS.
Terraform GitHub configuration cập nhật Variables thay hai script cấu hình trong normal lifecycle.

Toàn bộ sơ đồ, lựa chọn scope, approval, retry và giới hạn concurrency nằm trong
[WORKFLOW_ORCHESTRATION.md](docs/WORKFLOW_ORCHESTRATION.md).
Danh sách job cần duyệt: [SOLO_OPERATION.md](docs/SOLO_OPERATION.md).
Ruleset import/migration: [GITHUB_GOVERNANCE.md](docs/GITHUB_GOVERNANCE.md).

Ownership phải giữ cố định:

```text
Terraform: AWS + EKS + Argo CD Helm release + root Application
Argo CD:    AppProject + add-ons + platform configuration + workloads
```

Hiện chỉ có một environment triển khai là `production`; repository này chỉ có
`environments/production.tfvars` và không tạo cấu trúc staging giả.

Để nâng Argo CD, sửa duy nhất
`terraform/platform/argocd-chart-version.txt`, mở infrastructure PR, xem speculative plan và Helm
render, sau đó merge để stage `platform` của orchestrator chạy trong `prod`. Terraform refreshed plan sẽ
nâng `helm_release.argocd`;
không tạo GitOps PR cho version của Argo CD.

Nếu muốn retry hoặc chủ động kiểm tra drift của foundation mà không có commit mới:

```bash
gh workflow run production-infra.yml \
  --repo chiendz11/iris-infrastructure \
  --ref main \
  --field scope=foundation
```

Lần bootstrap đầu tiên vẫn phải chạy local vì trước đó chưa có OIDC role để GitHub Actions assume.
Từ lần thứ hai: foundation PR → plan → merge → owner tự approve job `prod` → apply diff.

## GitHub ruleset as code

Ruleset của cả năm repository được khai báo trong `terraform/github-governance`. Các ruleset
`protect-main` đã tồn tại được nhận vào state bằng Terraform `import` block, không tạo bản thứ hai.
Mỗi thay đổi day-2 đi theo flow:

```text
governance PR -> plan-governance (không có GitHub write token) -> pr-gate
              -> merge main -> protected-branch prod job -> short-lived App token
              -> refreshed saved plan -> destructive-plan guard -> apply -> verify
```

Policy solo bắt buộc PR, required checks, resolved conversation, linear history và cấm force-push/delete.
Approval count là 0; không bắt buộc CODEOWNER/last-push approval. CODEOWNERS vẫn ghi ownership.
Không có permanent bypass actor. Vì GitHub cộng dồn classic branch protection và ruleset, sau lần
apply/verify đầu phải chạy một lần `scripts/migrate-rulesets.sh --remove-legacy` để xóa classic rule
cũ ở `iris-infrastructure` và `iris-gitops`.

Solo operator có thể tự merge PR khi required checks đạt; không cần collaborator và không thêm bypass.
Xem `docs/SOLO_OPERATION.md` để migrate cấu hình GitHub đã tồn tại, và `docs/ROLLBACK_RUNBOOK.md`
để phân biệt rollback model, image/config, AWS và dữ liệu.

Không dùng `static` làm required check: `pr-gate` tổng hợp kết quả và fail nếu một root đã đổi nhưng
plan tương ứng bị skip (ví dụ thiếu OIDC plan role hoặc PR đến từ fork). Trạng thái platform được
ghi rõ là `planned` hoặc `deferred`; `deferred` chỉ hợp lệ khi cùng PR có domain dependency chưa
thể tồn tại trước merge.

Sau platform apply, orchestrator gọi reusable GitHub configuration bằng `needs`; không cần chạy
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
một production deployment; apply dùng Environment scope trên protected branch. Plan role chỉ tin OIDC
subject `pull_request`, job từ fork bị chặn; apply role chỉ tin subject `environment:prod`.

Pipeline không lưu AWS access key: workflow assume role bằng OIDC và trust policy chỉ chấp nhận
subject của environment `prod`. RDS password do RDS quản lý trong Secrets Manager và workload nhận
qua External Secrets.
SSO/repository token tùy chọn nằm trong Secrets Manager; Terraform chỉ nhận ARN qua
`additional_external_secret_arns`, không nhận secret value.

GitHub governance, configuration, ba application/model publisher, platform contract publisher và
GitOps automation dùng identity riêng. Client ID/actor là variable; private key của publisher chạy
trong Actions nằm trong Environment secret, còn model-release publisher nằm trong Secrets Manager.
Workflow mint installation token có hạn một giờ và scope đúng repo/quyền của từng nhiệm vụ. Bốn
publisher chỉ có Actions write, nên không thể sửa desired state. Hai runtime credential container
do Terraform tạo trong Secrets Manager; operator seed value ngoài Terraform, vì vậy key không đi
qua variable/tfvars/state.

Sau platform apply, orchestrator chạy `github-config-after` trước `handoff`. Handoff kiểm tra
platform không còn diff chưa apply, đọc selected output từ state và validate contract. Nó kiểm tra
hai runtime secret có `AWSCURRENT` qua DescribeSecret, không đọc value, rồi dùng dedicated publisher
App gửi contract. Thiếu credential thì seed ngoài Terraform và retry `scope=handoff`, không cần apply
lại AWS. Receiver lấy role/secret ARN từ trusted GitOps Variables và kiểm tra exact bot actor.
Infra không có Contents/Pull requests permission và không biết đường dẫn manifest GitOps.

## Lưu ý quyền apply## Lưu ý quyền apply

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
