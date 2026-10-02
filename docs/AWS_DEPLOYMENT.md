# AWS deployment runbook

## Vì sao tách năm repo?

Năm repository có vòng đời và quyền khác nhau:

| Repo | Sở hữu | Thay đổi khi | Quyền runtime |
|---|---|---|---|
| data-pipeline | DVC metadata, prepare/train/offline evaluate và model-result contract | dataset/feature/model đổi | đọc-ghi DVC/Argo S3 và log MLflow |
| model-registry | MLflow server và local compose | schema/MLflow đổi | MLflow chỉ đọc-ghi artifact bucket |
| inference-service | API contract, model loader, metrics/drift | serving code/SLO đổi | gọi MLflow artifact proxy; không cần khóa S3 |
| iris-gitops | AppProject, platform add-ons, deployment manifests và release renderers | platform/release production đổi | Argo CD reconcile EKS |
| iris-infrastructure | Terraform AWS, OIDC, Argo CD Helm release và root Application | foundation/controller GitOps đổi | CI plan/apply bằng role tách biệt |

Nhờ đó không phải deploy lại database khi sửa model, không nhét training dependency vào API,
và có thể rollback serving độc lập. Ranh giới IAM cũng nhỏ hơn một monorepo dùng chung role.

## Vì sao Iris + Logistic Regression?

Iris chỉ có 150 dòng, bốn feature số, ba lớp cân bằng, không có PII và có sẵn trong sklearn.
Logistic Regression train CPU trong vài giây, model nhỏ nhưng vẫn tạo đủ accuracy/F1, signature,
artifact và prediction distribution. Vì bài tập đánh giá lifecycle chứ không đánh giá GPU hay
độ phức tạp mạng neural, lựa chọn này giữ CI/CD nhanh, rẻ và lỗi dễ truy vết.

## Thứ tự triển khai

### Commit trước hay bootstrap local trước?

Không apply foundation từ code chưa có commit. Với repository hiện tại, hãy review và commit
foundation trên feature branch trước (có thể push branch để lưu/review), chạy bootstrap local từ
đúng commit đó, migrate state rồi seed GitHub root-of-trust. Sau khi PR có OIDC/backend để plan,
merge main và để CI reconcile. Commit không đồng nghĩa merge main; không cần bỏ required check
để ép merge khi CI chưa có IAM role. Nếu repo mới có một initial commit chỉ gồm bootstrap và
static CI, có thể đưa commit đó lên main trước, nhưng không merge cả platform/app để cố tình
cho publish job thất bại. Không commit state, local tfvars, plan files hay PEM.

### Version and credential preflight (2026-09-29)

The default, example and production profile now use EKS `1.34`. KServe `0.19` documents
Kubernetes `1.34` with Knative `1.20`, already pinned in GitOps:
https://kserve.github.io/website/docs/0.19/admin-guide/serverless
EKS `1.33` left standard support on 2026-07-29; `1.34` remains in standard support until
2026-12-02 per https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html.
Review this date again before deployment; do not treat this pin as permanent. GitOps schema
validation also targets `1.34`. These are documented compatibility checks, not an EKS integration
test. Validate add-on builds, Helm charts, Pod readiness, storage and traffic in the actual region.

The rollout observer currently retains its kubectl `1.33` client, one minor behind `1.34`, within
the supported kubectl skew. Image availability and runtime behavior still need deployment checks.
When upgrading beyond `1.34`, review that client too. Do not downgrade an existing cluster just
because this initial-install profile has a lower version than the live cluster.

The checked-in deployment profile uses 2 AZ, 3 x `c7i-flex.large`, one NAT and RDS Single-AZ;
interface endpoints are disabled. The compute type was verified as Free-Tier-eligible and offered
in both selected AZs for this account/region. Eligibility does not mean unlimited free usage: three
nodes, EKS, NAT and RDS consume credits quickly. This is not NAT-free, and node capacity has not
been load-tested. Configure an AWS budget before creating charged resources.

In GitOps, both dispatcher secretKeyRefs must match ExternalSecret target
`model-release-publisher-github-app` in namespace `argo`. The automated regression test verifies
the target, namespace and both keys, and excludes App credentials from train/evaluate containers.

### Training storage prerequisite

`terraform/platform/eks_storage.tf` tạo IAM role riêng, IRSA trust đúng
`kube-system:ebs-csi-controller-sa`, attach `AmazonEBSCSIDriverPolicyV2`, rồi tạo EKS managed add-on
`aws-ebs-csi-driver`. Argo CD Helm release chờ add-on trước khi tạo root Application. Không cài
thêm một Helm release EBS CSI ở GitOps để tránh hai owner quản lý cùng driver.

`ebs_csi_addon_version=null` chọn AWS default build tương thích Kubernetes (không lấy most_recent).
Sau khi xác nhận build ở region, pin version bằng PR; output cùng tên cho biết version đã resolve.
StorageClass `iris-training-gp3` nằm ở GitOps, dùng gp3 encrypted, WaitForFirstConsumer và không
thay default StorageClass của cluster. WorkflowTemplate chọn class này cho PVC workspace 1Gi.
CSI tự tạo PV/EBS đúng AZ; không tạo aws_ebs_volume/PV tĩnh từ Terraform. Model/data bền vững ở
S3/MLflow; workspace bị dọn khi Workflow kết thúc cả success/failure. Xem `iris-gitops/docs/TRAINING_STORAGE.md`.

Redis HA và HAProxy của Argo CD dùng hard anti-affinity cùng topology spread trên node label chuẩn
`kubernetes.io/hostname`. Không dùng `topology.kubernetes.io/hostname`: label đó không tồn tại trên
EKS nodes và `DoNotSchedule` sẽ giữ toàn bộ Redis pods ở Pending cho tới khi Helm timeout.

Khi triển khai thật, kiểm tra `kubectl get csidrivers`, `kubectl get sc iris-training-gp3`,
`kubectl -n argo get pvc`, `kubectl get pv`. PVC Pending trước Pod đầu tiên có thể là hành vi
WaitForFirstConsumer bình thường; Pending kéo dài sau scheduling cần xem events/IAM/node capacity.

### Runbook

1. Apply `terraform/bootstrap` bằng local state đúng một lần, sau đó migrate state lên S3/KMS.
2. Chạy `configure-github.sh` đúng một lần bằng owner credential để tạo/cấu hình trust gate
   `iris-infrastructure/prod`, rồi seed output bootstrap cần cho CI đầu tiên (owner tự approve deployment).
3. Merge `ci-gate` cùng `CODEOWNERS` vào ba repo ứng dụng; tạo/install các least-privilege GitHub App
   theo `docs/GITHUB_CONTROL_PLANE.md`. Inference, registry, model lifecycle và platform dùng actor
   riêng; mỗi private key chỉ nằm tại đúng owner boundary.
4. Reconcile `terraform/github-governance` và `terraform/github-config`; import ruleset,
   Environment/variable hiện hữu, verify rồi xóa hai classic
   branch protection cũ theo `docs/GITHUB_GOVERNANCE.md`.
5. PR workflow luôn chạy static check, plan mọi Terraform root có thay đổi và chỉ cho `pr-gate`
   thành công khi không có plan bắt buộc nào bị skip.
6. Merge PR hạ tầng đã qua CI để `production-infra.yml` chọn stage cần chạy; nếu code đã có trên
   main từ trước thì dispatch `scope=all` một lần. Không tạo run trùng khi chain đang chạy.
7. Approve các job dùng `prod`. Stage domain lần đầu tạo Hosted Zone/in NS và dispatch certificate
   run riêng. Đổi NS tại registrar rồi approve certificate; job kiểm tra DNS trước tạo/validate ACM.
8. Certificate hoàn tất gọi lại orchestrator `scope=platform` với đúng SHA. Nếu main đã tiến thêm
   commit, guard chặn run cũ: xem lại thay đổi và reconcile scope thích hợp trên main hiện tại.
   Domain day-2 không cần delegation mới thì ở cùng run; platform chỉ chạy nếu được chọn hoặc
   output domain được nó sử dụng đã thay đổi.
9. Stage platform plan/apply AWS/EKS/EBS CSI. Terraform Helm provider cài/nâng Argo CD trước;
   release thứ hai chỉ tạo root Application sau khi API server đã đăng ký Application CRD.
   Terraform state tiếp tục quản lý cả controller và bootstrap release.
10. `github-config-after` apply ECR/DVC/IAM/receiver Variables. Stage `handoff` đọc state, đòi hỏi
    platform plan không còn diff, build/schema-validate contract và kiểm tra AWSCURRENT của hai
    runtime App credential. Không đọc/log secret value. Thiếu seed làm handoff fail; AWS đã tồn tại.
11. Seed bằng `scripts/seed-github-app-secret.sh` ngoài Terraform. Sau đó rerun failed jobs nếu SHA
    vẫn là main hiện tại, hoặc dispatch `production-infra.yml --field scope=handoff`. Handoff-only
    vẫn reconcile GitHub config nhưng không chạy Terraform apply AWS; có AWS diff thì chặn và yêu
    cầu `scope=platform` trước.
12. Dedicated platform App chỉ có Actions write gửi contract sang GitOps; infrastructure không
    checkout GitOps, không sửa manifest hoặc auto-merge PR.
13. Review/merge platform-reconcile PR do `iris-gitops` tạo; root Application để Argo CD cài
    add-ons/workload. AWS LBC tạo NLB và
    ExternalDNS tạo Route53 record.
14. Chạy `release-automation-image.yml` một lần sau khi GitHub variables đã được reconcile. Workflow
    build source DevOps trong `iris-gitops`, push physical ECR repository `dispatcher`, lấy digest và
    mở PR pin release-automation image. Merge PR này trước khi publish dataset đầu tiên; các thay đổi
    automation về sau tự chạy cùng lifecycle.
15. Chạy/rerun CI của app repo, approve publish job trong `prod` để push image digest và dispatch `workload-release-v1`. Khi runtime
    code cần config mới, cùng một intent/PR chứa cả image digest lẫn config; config-only không push
    image. Renderer GitOps tạo PR; merge để Argo CD rollout.
16. Push dataset; S3 event truyền commit SHA để chạy đúng training image. Model lifecycle mở các
    GitOps PR canary/promote/rollback; không thành phần nào khác tranh quyền ghi các field
    InferenceService đang được Git quản lý và Argo CD reconcile.

Trong lần đầu, Argo CD controller có thể chạy trước khi platform-reconcile PR được merge và child
Application tạm báo lỗi do placeholder. Không có resource AWS sai được tạo từ placeholder; sau khi PR merge,
self-heal reconcile desired state hoàn chỉnh. Production nhiều team thường tách platform foundation
và GitOps-controller thành hai Terraform state để đặt approval giữa hai bước; đồ án giữ một platform
state để flow A dễ trình bày và vận hành hơn.

## Day-2 orchestration

`terraform.yml` tiếp tục là required PR CI (`pr-gate`), không có apply hay App write credential.
Sau merge, `production-infra.yml` dùng chung `scripts/plan_production.py` để chọn stage:

| Thay đổi | Stage | Chạy domain? |
|---|---|---|
| Backend/OIDC/IAM foundation | foundation → github-config-before | Không, trừ khi domain cũng đổi |
| Ruleset | governance | Không |
| Variables/app Environments | github-config-before | Không |
| Route53/ACM/DNS helpers | domain → platform nếu output đổi | Có |
| Node/RDS/EKS/Argo CD/production.tfvars | platform → github-config-after → handoff | Không; chỉ đọc output readiness nếu public domain bật |
| Platform contract producer/schema | platform → config → handoff | Không |
| Tài liệu/tests/PR CI | Không apply | Không |

Logic `needs` cho phép bỏ qua stage không đổi nhưng không đi qua upstream failure/cancellation.
Governance là gate khi được chọn trong cùng run. Các root/state vẫn riêng; không có transaction
rollback toàn bộ. Lần đầu PR có domain+platform chưa đủ prerequisite vẫn dùng cơ chế deferred
plan hiện hữu, rồi authoritative plan sau merge/approval.

Retry/drift không cần tạo commit rỗng:

```bash
gh workflow run production-infra.yml --repo chiendz11/iris-infrastructure --ref main --field scope=foundation
gh workflow run production-infra.yml --repo chiendz11/iris-infrastructure --ref main --field scope=governance
gh workflow run production-infra.yml --repo chiendz11/iris-infrastructure --ref main --field scope=github-config
gh workflow run production-infra.yml --repo chiendz11/iris-infrastructure --ref main --field scope=domain
gh workflow run production-infra.yml --repo chiendz11/iris-infrastructure --ref main --field scope=platform
gh workflow run production-infra.yml --repo chiendz11/iris-infrastructure --ref main --field scope=handoff
```

Không chạy các lệnh cùng lúc. Chọn một scope đúng với việc cần phục hồi. `all` dành cho lần đầu hoặc
cần reconcile đầy đủ sau các run bị hủy/đứt chain. Certificate vẫn có entrypoint riêng để bạn approve
sau đổi NS. Xem [WORKFLOW_ORCHESTRATION.md](WORKFLOW_ORCHESTRATION.md) trước vận hành.

## Platform contract output## Platform contract output

`scripts/build_platform_contract.py` dùng allowlist output để tạo object theo
`contracts/platform-contract-v1.schema.json`: cluster/VPC, ba bucket, SQS, RDS endpoint + secret
ARN, ECR names/URLs, IRSA/controller roles, model-release-publisher secret ARN và public-domain metadata.
Builder từ chối output được đánh dấu sensitive và schema từ chối field lạ.

Đây là producer API, không phải mapping manifest. Việc `storage.dvc_bucket` đi vào resource nào,
`domain.kserve_hostname` đi vào DomainMapping nào hay role nào annotate ServiceAccount nào hoàn toàn
thuộc renderer của `iris-gitops`. Chi tiết compatibility ở `docs/PLATFORM_CONTRACT.md`.

## Quality gates và rollback

Offline gate yêu cầu `accuracy >= min_accuracy` và
`accuracy >= champion_accuracy + min_improvement`. Model đạt gate chỉ là `candidate`.
Online gate sau 10% rollout yêu cầu có traffic, p95 không quá 500 ms và error rate không quá 1%.
Mọi rollout là một protected GitOps PR. Workflow trong `iris-gitops` chỉ tạo PR; solo operator
kiểm tra diff và tự merge sau khi `validate` đạt yêu cầu; không cần CODEOWNER approval. Sau merge, Argo CD reconcile và Argo
Workflow xác nhận đúng generation đã Ready. Pass: PR xóa `canaryTrafficPercent`, KServe rollout 100% và Ready rồi mới cập nhật alias champion.
Fail dạng evaluator trả `passed=false`: PR pin đúng baseline version, xóa canary field/annotation;
champion không đổi. Smoke lỗi, Prometheus exception hoặc rollout timeout chưa tự tạo rollback PR.
Alias updater đọc/kiểm tra baseline rồi ghi alias, không phải một giao dịch atomic xuyên Git/KServe/MLflow.
Xem `ROLLBACK_RUNBOOK.md` trước khi phục hồi.

Lần đầu chưa có champion để làm revision stable, nên workflow dùng nhánh bootstrap: model đầu tiên
qua offline gate được promote và rollout 100%. Từ model thứ hai, đường 10% → online gate → 100%
là bắt buộc. Vì vậy lần deploy InferenceService đầu có thể tạm Unready cho tới bootstrap workflow.

## Các việc phải harden trước production

- Authentication/WAF/rate limiting cho public KServe; authentication/RBAC riêng cho MLflow nội bộ.
- RDS module hỗ trợ Multi-AZ nhưng deployment profile hiện dùng Single-AZ do account Free Tier;
  trước production thật phải nâng account plan, bật lại Multi-AZ/retention dài, chạy restore test
  và bổ sung alert storage/connections.
- Production HA thực tế cần NAT theo AZ; mô hình capstone dùng một NAT và S3 Gateway Endpoint.
- NetworkPolicy egress cụ thể, admission policy, image signing và vulnerability gate.
- ECR hiện chỉ dọn image untagged sau 14 ngày; SHA-tag bất biến đang được GitOps pin được giữ để
  rollback không mất artifact. Production quy mô lớn nên bổ sung release-retention controller hoặc
  protected release tags thay vì giới hạn mù theo 30 image gần nhất.
- GitHub OIDC trust giới hạn đúng organization/repository/branch; không dùng static AWS key.
- PR cloud plan hiện dành cho collaborator tin cậy. Trước production nhiều team, chuyển plan sang
  trusted Terraform runner/required workflow hoặc approval gate độc lập và thay AWS ReadOnlyAccess
  bằng least-privilege policy; fork check không bảo vệ khỏi PR branch nội bộ độc hại.
- GitHub Actions trong privileged jobs được pin full commit SHA; cấu hình Dependabot/Renovate để
  nhận PR nâng pin có review thay vì đổi sang mutable major tag.
- Foundation stack quản lý chính apply role; phải có operator break-glass để repair remote state/IAM
  nếu role hoặc OIDC trust bị thay sai và CI tự khóa mình. Apply role có `prevent_destroy` để chặn
  replace/delete vô ý.
- Flow solo có speculative plan ở PR, owner self-approval trước apply job và refreshed plan trong job.
  Nút approve hiện duyệt quyền chạy job/ref, không duyệt đúng binary plan được tạo sau gate. Enterprise muốn duyệt đúng plan nên tách thêm
  post-merge plan artifact (retention ngắn, access chặt) và apply chính artifact đó sau gate.
- Không merge infrastructure PR thứ hai khi chain cũ đang chờ approval. Orchestrator hiện tại chưa
  có persistent deployment queue/checkpoint; main tiến thêm làm stale guard chặn run cũ. Review rồi
  dùng scope=all nếu cần reconcile các root từ nhiều commit bị gián đoạn.
- Zone và certificate đã tách thành hai workflow run dùng cùng Environment `prod`. Các AWS apply
  vẫn dùng global concurrency `terraform-production`; chưa có orchestration ưu tiên emergency run
  hay bảo đảm FIFO. Không merge nhiều đợt infra khi chain cũ chưa xong.
- Bảy GitHub App tách riêng governance, configuration, ba producer Actions-only, platform publisher
  và GitOps PR automation; cần định kỳ rotate private key và kiểm tra installation scope. Producer không checkout
  GitOps nên không có repository write credential bị lưu lại trong Git config.
- PR platform plan dùng `-refresh=false` để plan role không cần đọc Kubernetes Secrets chứa Helm
  state; job apply được bảo vệ luôn tạo authoritative refreshed plan trước khi mutate.
- Argo CD SSO cần IdP/OAuth client thực; mẫu ExternalSecret đã có nhưng cố ý chưa bật bằng
  placeholder. Repository credential cũng chỉ bật khi GitOps repo chuyển private.
- Prometheus retention/remote-write, Alertmanager receiver và SLO phù hợp traffic thật.

## Profile chi phí cho đồ án

- Hai AZ đáp ứng yêu cầu subnet của EKS và cho phép bật RDS Multi-AZ sau khi nâng account plan.
- Node group hiện gồm ba `c7i-flex.large`, giới hạn tối đa bốn node. Ba node là mức tối thiểu để
  Redis HA của Argo CD phân tán được replica; vẫn dùng hai AZ để giữ chi phí capstone. Chưa cài
  Cluster Autoscaler/Karpenter nên `max_size=4` không tự tăng node; cần quan sát memory trước deploy.
- Một NAT Gateway dùng chung giữ egress cho GitHub, Helm và public registries. Đây là điểm single
  failure được chấp nhận trong capstone, không phải cấu hình production HA hoàn chỉnh.
- S3 Gateway Endpoint luôn bật. Interface Endpoint mặc định tắt vì mỗi service tạo ENI có phí ở
  từng AZ; chỉ bật sau khi so sánh chi phí và xác định nhu cầu private traffic.
- RDS `db.t4g.micro` hiện dùng Single-AZ, deletion protection, backup một ngày và không storage
  autoscaling để thỏa guardrail Free Tier. Đây là demo constraint, không phải production HA.

## Public endpoint của KServe

MLflow chỉ là control plane nội bộ; client không gọi trực tiếp MLflow. `terraform/domain` sở hữu
Hosted Zone và certificate ACM dùng chung cho `<domain>` cùng `*.<domain>`. Public DNS và TLS kết
thúc tại NLB do AWS Load Balancer Controller tạo trước Kourier/KServe. `terraform/platform/edge.tf`
đọc domain remote state và tạo IRSA cho controller.
Platform contract công bố certificate ARN/hostname; GitOps renderer sở hữu cách đưa chúng vào
desired state. AWS Load Balancer Controller tạo NLB từ
Kourier Service; ExternalDNS theo dõi Service và tự tạo/cập nhật record `api.<domain>` trong hosted
zone được giới hạn bằng `domainFilters` và `zoneIdFilters`.

Không cần đọc NLB DNS bằng tay và không cần Terraform apply lần hai. Terraform sở hữu AWS
foundation/IAM/ACM; GitOps cùng các Kubernetes controller sở hữu NLB và DNS record theo workload.
