# AWS deployment runbook

## Vì sao tách năm repo?

Năm repository có vòng đời và quyền khác nhau:

| Repo | Sở hữu | Thay đổi khi | Quyền runtime |
|---|---|---|---|
| data-pipeline | DVC metadata, train/evaluate, Argo lifecycle | dataset/feature/model đổi | đọc DVC/Argo S3, gọi MLflow, patch KServe |
| model-registry | MLflow server và local compose | schema/MLflow đổi | MLflow chỉ đọc-ghi artifact bucket |
| inference-service | API contract, KServe, metrics/drift | serving code/SLO đổi | gọi MLflow artifact proxy; không cần khóa S3 |
| iris-gitops | desired state production và Argo CD Applications | platform/release production đổi | Argo CD reconcile EKS |
| iris-infrastructure | Terraform AWS, OIDC và CI automation | AWS foundation/IAM đổi | CI plan/apply bằng role tách biệt |

Nhờ đó không phải deploy lại database khi sửa model, không nhét training dependency vào API,
và có thể rollback serving độc lập. Ranh giới IAM cũng nhỏ hơn một monorepo dùng chung role.

## Vì sao Iris + Logistic Regression?

Iris chỉ có 150 dòng, bốn feature số, ba lớp cân bằng, không có PII và có sẵn trong sklearn.
Logistic Regression train CPU trong vài giây, model nhỏ nhưng vẫn tạo đủ accuracy/F1, signature,
artifact và prediction distribution. Vì bài tập đánh giá lifecycle chứ không đánh giá GPU hay
độ phức tạp mạng neural, lựa chọn này giữ CI/CD nhanh, rẻ và lỗi dễ truy vết.

## Thứ tự triển khai

1. Apply `terraform/bootstrap` bằng local state đúng một lần, sau đó migrate state lên S3/KMS.
2. `configure-github.sh` đặt output bootstrap vào GitHub Variables của repo infrastructure.
3. Pull request chạy plan; merge `main` và approve GitHub Environment để CI apply platform.
4. CI đọc `terraform output -json` và tự mở pull request cập nhật `iris-gitops`.
5. Bootstrap Argo CD bằng `iris-gitops/bootstrap/install-argocd.sh`.
6. Root Application cài add-ons/workload; AWS LBC tạo NLB, ExternalDNS tạo Route53 record.
7. App repo push image và tạo PR GitOps; review/merge để Argo CD rollout.
8. Push dataset; S3 event truyền commit SHA để chạy đúng training image.

## Mapping output Terraform

- `cluster_name` → `EKS_CLUSTER_NAME`.
- `dvc_bucket` → `DVC_BUCKET`, workflow dataset bucket và DVC remote.
- `mlflow_artifact_bucket` → MLflow ConfigMap.
- `argo_artifact_bucket` → Argo artifact repository ConfigMap.
- `dataset_event_queue_name` → EventSource `queue`; URL/ARN phục vụ kiểm tra và IAM.
- `rds_endpoint`, `rds_master_secret_arn` → MLflow Kustomize.
- `ecr_repository_names` → GitHub `*_ECR_REPOSITORY`; URLs → Kubernetes image placeholder.
- `service_account_role_arns` → annotation của Kubernetes service accounts, gồm ExternalDNS khi bật domain.
- `public_certificate_arn`, `kserve_hostname`, `route53_zone_id` → Kourier và ExternalDNS.

## Quality gates và rollback

Offline gate yêu cầu `accuracy >= min_accuracy` và
`accuracy >= champion_accuracy + min_improvement`. Model đạt gate chỉ là `candidate`.
Online gate sau 10% rollout yêu cầu có traffic, p95 không quá 500 ms và error rate không quá 1%.
Pass: alias champion đổi atomically rồi KServe lên 100%. Fail: KServe về 0%; champion không đổi.

Lần đầu chưa có champion để làm revision stable, nên workflow dùng nhánh bootstrap: model đầu tiên
qua offline gate được promote và rollout 100%. Từ model thứ hai, đường 10% → online gate → 100%
là bắt buộc. Vì vậy lần deploy InferenceService đầu có thể tạm Unready cho tới bootstrap workflow.

## Các việc phải harden trước production

- Authentication/WAF/rate limiting cho public KServe; authentication/RBAC riêng cho MLflow nội bộ.
- RDS đã Multi-AZ và deletion-protected; còn thiếu restore test và alert storage/connections.
- Production HA thực tế cần NAT theo AZ; mô hình capstone dùng một NAT và S3 Gateway Endpoint.
- NetworkPolicy egress cụ thể, admission policy, image signing và vulnerability gate.
- GitHub OIDC trust giới hạn đúng organization/repository/branch; không dùng static AWS key.
- Prometheus retention/remote-write, Alertmanager receiver và SLO phù hợp traffic thật.

## Profile chi phí cho đồ án

- Hai AZ đáp ứng yêu cầu subnet của EKS và cho phép RDS Multi-AZ.
- Node group mặc định gồm hai `t3.medium`, giới hạn tối đa ba node. Chưa cài Cluster Autoscaler hay
  Karpenter nên `max_size=3` không tự tăng node; cần quan sát memory và tăng desired size thủ công
  nếu Argo, Knative/KServe cùng kube-prometheus-stack không vừa hai node.
- Một NAT Gateway dùng chung giữ egress cho GitHub, Helm và public registries. Đây là điểm single
  failure được chấp nhận trong capstone, không phải cấu hình production HA hoàn chỉnh.
- S3 Gateway Endpoint luôn bật. Interface Endpoint mặc định tắt vì mỗi service tạo ENI có phí ở
  từng AZ; chỉ bật sau khi so sánh chi phí và xác định nhu cầu private traffic.
- RDS `db.t4g.micro` bật Multi-AZ, deletion protection và backup 14 ngày.

## Public endpoint của KServe

MLflow chỉ là control plane nội bộ; client không gọi trực tiếp MLflow. Public DNS và TLS kết thúc
tại NLB do AWS Load Balancer Controller tạo trước Kourier/KServe. `terraform/platform/edge.tf` tạo
IRSA cho controller và, khi bật, một certificate ACM dùng chung cho `<domain>` cùng `*.<domain>`.
Pipeline chuyển certificate ARN/hostname vào GitOps. AWS Load Balancer Controller tạo NLB từ
Kourier Service; ExternalDNS theo dõi Service và tự tạo/cập nhật record `api.<domain>` trong hosted
zone được giới hạn bằng `domainFilters` và `zoneIdFilters`.

Không cần đọc NLB DNS bằng tay và không cần Terraform apply lần hai. Terraform sở hữu AWS
foundation/IAM/ACM; GitOps cùng các Kubernetes controller sở hữu NLB và DNS record theo workload.
