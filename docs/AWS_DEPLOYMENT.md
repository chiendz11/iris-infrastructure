# AWS deployment runbook

## Vì sao tách năm repo?

Năm repository có vòng đời và quyền khác nhau:

| Repo | Sở hữu | Thay đổi khi | Quyền runtime |
|---|---|---|---|
| data-pipeline | DVC metadata, train/evaluate, Argo lifecycle | dataset/feature/model đổi | đọc DVC/Argo S3, gọi MLflow/GitHub và chỉ đọc trạng thái KServe |
| model-registry | MLflow server và local compose | schema/MLflow đổi | MLflow chỉ đọc-ghi artifact bucket |
| inference-service | API contract, KServe, metrics/drift | serving code/SLO đổi | gọi MLflow artifact proxy; không cần khóa S3 |
| iris-gitops | AppProject, platform add-ons và workload desired state | platform/release production đổi | Argo CD reconcile EKS |
| iris-infrastructure | Terraform AWS, OIDC, Argo CD Helm release và root Application | foundation/controller GitOps đổi | CI plan/apply bằng role tách biệt |

Nhờ đó không phải deploy lại database khi sửa model, không nhét training dependency vào API,
và có thể rollback serving độc lập. Ranh giới IAM cũng nhỏ hơn một monorepo dùng chung role.

## Vì sao Iris + Logistic Regression?

Iris chỉ có 150 dòng, bốn feature số, ba lớp cân bằng, không có PII và có sẵn trong sklearn.
Logistic Regression train CPU trong vài giây, model nhỏ nhưng vẫn tạo đủ accuracy/F1, signature,
artifact và prediction distribution. Vì bài tập đánh giá lifecycle chứ không đánh giá GPU hay
độ phức tạp mạng neural, lựa chọn này giữ CI/CD nhanh, rẻ và lỗi dễ truy vết.

## Thứ tự triển khai

1. Apply `terraform/bootstrap` bằng local state đúng một lần, sau đó migrate state lên S3/KMS.
2. Chạy `configure-github.sh` đúng một lần bằng owner credential để tạo/cấu hình trust gate
   `iris-infrastructure/prod`, rồi seed output bootstrap và reviewer metadata cần cho CI đầu tiên.
3. Merge `ci-gate` cùng `CODEOWNERS` vào ba repo ứng dụng; tạo/install ba control-plane GitHub App
   theo `docs/GITHUB_CONTROL_PLANE.md` và lưu từng private key trong đúng Environment `prod`.
4. Reconcile `terraform/github-governance` và `terraform/github-config`; import ruleset,
   Environment/variable hiện hữu, verify rồi xóa hai classic
   branch protection cũ theo `docs/GITHUB_GOVERNANCE.md`.
5. PR workflow luôn chạy static check, plan mọi Terraform root có thay đổi và chỉ cho `pr-gate`
   thành công khi không có plan bắt buộc nào bị skip.
6. Dispatch `terraform-domain.yml`; approve zone apply qua Environment `prod`. GitHub configuration
   root đã thay hai script trong normal lifecycle.
7. CI tạo Hosted Zone và in NS vào summary. Delegate NS tại registrar rồi approve certificate job;
   job tự verify DNS trước khi tạo/validate ACM.
8. Domain workflow dispatch `terraform-platform.yml`. Approve platform job qua Environment `prod`.
9. Platform apply tạo AWS/EKS, sau đó Terraform Helm provider cài Argo CD chart `10.4.0` và root
   Application. Terraform state quản lý mọi lần upgrade tiếp theo.
10. CI đọc `terraform output -json`, tự dispatch GitHub configuration để publish ECR/DVC/role
    metadata, rồi mở pull request cập nhật `iris-gitops` bằng GitHub App token ngắn hạn.
11. Tạo/install `iris-model-promoter` chỉ trên `iris-gitops`, rồi seed Client ID/private key vào
    Secrets Manager bằng `scripts/seed-model-promoter-secret.sh`. Terraform chỉ sở hữu secret
    container; secret value không đi vào state.
12. Review/merge output PR; root Application để Argo CD cài add-ons/workload. AWS LBC tạo NLB và
    ExternalDNS tạo Route53 record.
13. Chạy `dispatcher-image.yml` một lần sau khi GitHub variables đã được reconcile. Workflow build
    source DevOps trong `iris-gitops`, push ECR, lấy digest và mở PR pin dispatcher image. Merge PR
    này trước khi publish dataset đầu tiên; các thay đổi dispatcher về sau tự chạy cùng lifecycle.
14. Chạy/rerun CI của app repo để push image SHA và tạo GitOps PR; merge để Argo CD rollout.
15. Push dataset; S3 event truyền commit SHA để chạy đúng training image. Model lifecycle mở các
    GitOps PR canary/promote/rollback; không thành phần nào khác tranh quyền ghi các field
    InferenceService đang được Git quản lý và Argo CD reconcile.

Trong lần đầu, Argo CD controller có thể chạy trước khi output PR được merge và child Application
tạm báo lỗi do placeholder. Không có resource AWS sai được tạo từ placeholder; sau khi PR merge,
self-heal reconcile desired state hoàn chỉnh. Production nhiều team thường tách platform foundation
và GitOps-controller thành hai Terraform state để đặt approval giữa hai bước; đồ án giữ một platform
state để flow A dễ trình bày và vận hành hơn.

## Day-2 workflows

| Thay đổi | Workflow apply | Có chạy DNS không? |
|---|---|---|
| S3/KMS state, GitHub OIDC, Terraform role | `terraform-foundation.yml` | Không |
| GitHub ruleset/required check/review policy | `terraform-governance.yml` | Không |
| GitHub Actions variable/app production Environment | `terraform-github-config.yml` | Không |
| Route53 zone, ACM hoặc domain code | `terraform-domain.yml` | Có; dispatch platform nếu output đổi |
| `scripts/detect-domain-delegation.sh` | `terraform-domain.yml` | Có |
| Node count/type, EKS/add-on, IAM, RDS, S3, ECR, Argo CD | `terraform-platform.yml` | Không |
| `environments/production.tfvars` | `terraform-platform.yml` | Không |
| `scripts/sync_gitops_outputs.py` | `terraform-platform.yml` | Không |
| Tài liệu | Không apply | Không |

`terraform.yml` không apply. Nó chạy cho mọi PR để required check không bị treo khi path filter bỏ
qua workflow, nhưng chỉ tạo speculative plan cho root stack có thay đổi. Job `pr-gate` fail nếu
static validation hoặc bất kỳ plan cần thiết nào không thành công. Branch protection phải require
`pr-gate`, không chỉ require `static`.

Các AWS apply workflow dùng cùng concurrency group `terraform-production` để serialize mutation;
không dựa vào thứ tự của queue để thể hiện dependency. Nếu một push có cả foundation, domain và
platform, direct downstream run tự nhường. Foundation apply xong dispatch GitHub configuration để
publish IAM/state output mới; job này tiếp tục dispatch domain, rồi domain dispatch platform sau
ACM. Nếu không có domain, GitHub configuration dispatch thẳng platform. Nếu chỉ có domain +
platform, domain là owner của dispatch platform. Vì vậy dependency luôn là
`foundation → GitHub config → domain → platform` mà operator không phải chạy workflow lần nữa.

Trong PR khởi tạo có cả domain và platform nhưng domain state chưa ready, platform speculative plan
được gắn trạng thái `deferred` có chủ đích; `pr-gate` chỉ chấp nhận trạng thái này khi chính PR cũng
đổi domain. Sau merge, domain workflow tạo/validate ACM rồi mới dispatch authoritative platform
plan/apply. Với PR chỉ sửa platform, domain chưa ready là lỗi và PR không được merge thiếu plan.

Các lệnh day-2 thủ công:

```bash
gh workflow run terraform-foundation.yml \
  --repo chiendz11/iris-infrastructure --ref main --field source=manual

gh workflow run terraform-governance.yml \
  --repo chiendz11/iris-infrastructure --ref main --field source=manual

gh workflow run terraform-github-config.yml \
  --repo chiendz11/iris-infrastructure --ref main --field source=manual

gh workflow run terraform-domain.yml \
  --repo chiendz11/iris-infrastructure --ref main \
  --field source=manual

gh workflow run terraform-platform.yml \
  --repo chiendz11/iris-infrastructure --ref main \
  --field source=manual
```

`dispatch platform` là một lời gọi GitHub Actions API tạo run mới của
`terraform-platform.yml`. Domain không chạy Terraform platform thay cho platform workflow. Run
mới dùng SHA của `main` được GitHub resolve lúc dispatch, giữ SHA khởi tạo làm audit metadata, rồi
vẫn phải qua `prod` approval và authoritative plan/apply riêng.

Thêm resource IAM vào `terraform/bootstrap` sau day-0 không chạy lại bootstrap: PR tạo
`plan-foundation`; merge tự kích hoạt `terraform-foundation.yml`, và Terraform remote state chỉ
apply diff. Từ "bootstrap" trong tên thư mục chỉ mô tả nhiệm vụ đầu tiên của root stack.

## Mapping output Terraform

- `cluster_name` → `EKS_CLUSTER_NAME`.
- `dvc_bucket` → `DVC_BUCKET`, workflow dataset bucket và DVC remote.
- `mlflow_artifact_bucket` → MLflow ConfigMap.
- `argo_artifact_bucket` → Argo artifact repository ConfigMap.
- `dataset_event_queue_name` → EventSource `queue`; URL/ARN phục vụ kiểm tra và IAM.
- `rds_endpoint`, `rds_master_secret_arn` → MLflow Kustomize.
- `model_promotion_github_app_secret_arn` → operator seed/rotation target; GitOps references the
  deterministic secret name rather than copying a secret value or account-specific ARN.
- `ecr_repository_names` → GitHub `*_ECR_REPOSITORY`; riêng `dispatcher` được GitOps CI build và
  mở PR pin digest vào WorkflowTemplate.
- `github_dispatcher_publish_role_arn` → `DISPATCHER_PUBLISH_AWS_ROLE_ARN` của `iris-gitops`; role
  chỉ có quyền push/describe dispatcher ECR repository.
- `service_account_role_arns` → annotation của Kubernetes service accounts, gồm ExternalDNS khi bật domain.
- `public_certificate_arn`, `kserve_hostname`, `route53_zone_id` → Kourier và ExternalDNS.

## Quality gates và rollback

Offline gate yêu cầu `accuracy >= min_accuracy` và
`accuracy >= champion_accuracy + min_improvement`. Model đạt gate chỉ là `candidate`.
Online gate sau 10% rollout yêu cầu có traffic, p95 không quá 500 ms và error rate không quá 1%.
Mọi rollout là một protected GitOps PR. Workflow trong `iris-gitops` chỉ tạo PR; reviewer độc lập
merge sau khi `validate` và CODEOWNER approval đạt yêu cầu. Sau merge, Argo CD reconcile và Argo
Workflow xác nhận đúng generation đã Ready. Pass: alias champion đổi atomically, PR xóa
`canaryTrafficPercent` để KServe promote
revision lên 100%. Fail: PR pin candidate ở 0%; champion không đổi.

Lần đầu chưa có champion để làm revision stable, nên workflow dùng nhánh bootstrap: model đầu tiên
qua offline gate được promote và rollout 100%. Từ model thứ hai, đường 10% → online gate → 100%
là bắt buộc. Vì vậy lần deploy InferenceService đầu có thể tạm Unready cho tới bootstrap workflow.

## Các việc phải harden trước production

- Authentication/WAF/rate limiting cho public KServe; authentication/RBAC riêng cho MLflow nội bộ.
- RDS đã Multi-AZ và deletion-protected; còn thiếu restore test và alert storage/connections.
- Production HA thực tế cần NAT theo AZ; mô hình capstone dùng một NAT và S3 Gateway Endpoint.
- NetworkPolicy egress cụ thể, admission policy, image signing và vulnerability gate.
- GitHub OIDC trust giới hạn đúng organization/repository/branch; không dùng static AWS key.
- PR cloud plan hiện dành cho collaborator tin cậy. Trước production nhiều team, chuyển plan sang
  trusted Terraform runner/required workflow hoặc approval gate độc lập và thay AWS ReadOnlyAccess
  bằng least-privilege policy; fork check không bảo vệ khỏi PR branch nội bộ độc hại.
- GitHub Actions trong privileged jobs được pin full commit SHA; cấu hình Dependabot/Renovate để
  nhận PR nâng pin có review thay vì đổi sang mutable major tag.
- Foundation stack quản lý chính apply role; phải có operator break-glass để repair remote state/IAM
  nếu role hoặc OIDC trust bị thay sai và CI tự khóa mình. Apply role có `prevent_destroy` để chặn
  replace/delete vô ý.
- Flow hiện có speculative plan ở PR và refreshed plan trong protected apply job; approval `prod`
  diễn ra trước refreshed plan. Enterprise yêu cầu reviewer duyệt đúng binary plan nên tách thêm
  post-merge plan artifact (retention ngắn, access chặt) và apply chính artifact đó sau gate.
- Không merge một infrastructure PR thứ hai khi domain gate đang chờ ở mô hình capstone. Nhiều team
  production dùng merge queue hoặc một release orchestrator để deterministic hóa thứ tự nhiều merge.
- Workflow-level concurrency cố ý giữ global mutation lock trong lúc chờ registrar ở đồ án. Hệ
  thống nhiều team nên tách zone và certificate thành hai run để thời gian chờ bên ngoài không chặn
  một foundation/platform emergency change.
- Bốn GitHub App đã tách quyền governance/configuration/source GitOps PR/model promotion; cần định
  kỳ rotate private key, kiểm tra installation scope và giữ `persist-credentials: false` cho
  checkout GitOps.
- PR platform plan dùng `-refresh=false` để plan role không cần đọc Kubernetes Secrets chứa Helm
  state; job apply được bảo vệ luôn tạo authoritative refreshed plan trước khi mutate.
- Argo CD SSO cần IdP/OAuth client thực; mẫu ExternalSecret đã có nhưng cố ý chưa bật bằng
  placeholder. Repository credential cũng chỉ bật khi GitOps repo chuyển private.
- Prometheus retention/remote-write, Alertmanager receiver và SLO phù hợp traffic thật.

## Profile chi phí cho đồ án

- Hai AZ đáp ứng yêu cầu subnet của EKS và cho phép RDS Multi-AZ.
- Node group mặc định gồm ba `t3.medium`, giới hạn tối đa bốn node. Ba node là mức tối thiểu để
  Redis HA của Argo CD phân tán được replica; vẫn dùng hai AZ để giữ chi phí capstone. Chưa cài
  Cluster Autoscaler/Karpenter nên `max_size=4` không tự tăng node; cần quan sát memory trước deploy.
- Một NAT Gateway dùng chung giữ egress cho GitHub, Helm và public registries. Đây là điểm single
  failure được chấp nhận trong capstone, không phải cấu hình production HA hoàn chỉnh.
- S3 Gateway Endpoint luôn bật. Interface Endpoint mặc định tắt vì mỗi service tạo ENI có phí ở
  từng AZ; chỉ bật sau khi so sánh chi phí và xác định nhu cầu private traffic.
- RDS `db.t4g.micro` bật Multi-AZ, deletion protection và backup 14 ngày.

## Public endpoint của KServe

MLflow chỉ là control plane nội bộ; client không gọi trực tiếp MLflow. `terraform/domain` sở hữu
Hosted Zone và certificate ACM dùng chung cho `<domain>` cùng `*.<domain>`. Public DNS và TLS kết
thúc tại NLB do AWS Load Balancer Controller tạo trước Kourier/KServe. `terraform/platform/edge.tf`
đọc domain remote state và tạo IRSA cho controller.
Pipeline chuyển certificate ARN/hostname vào GitOps. AWS Load Balancer Controller tạo NLB từ
Kourier Service; ExternalDNS theo dõi Service và tự tạo/cập nhật record `api.<domain>` trong hosted
zone được giới hạn bằng `domainFilters` và `zoneIdFilters`.

Không cần đọc NLB DNS bằng tay và không cần Terraform apply lần hai. Terraform sở hữu AWS
foundation/IAM/ACM; GitOps cùng các Kubernetes controller sở hữu NLB và DNS record theo workload.
