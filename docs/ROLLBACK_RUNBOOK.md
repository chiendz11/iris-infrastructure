# Rollback và phục hồi: năm repository, một môi trường production

Tài liệu mô tả code hiện tại và thao tác vận hành cần thiết, không phải bằng chứng đã restore thử
trên AWS. Solo bỏ required PR approval nhưng không bỏ PR/CI. Deployment jobs trong `prod` vẫn cần
owner tự approve, kể cả khi chạy lại để phục hồi; xem `SOLO_OPERATION.md`. Không có nút rollback toàn bộ hệ thống.

## 1. Ai sở hữu phần nào?

| Thành phần | Nguồn desired state / dữ liệu | Ai thực hiện thay đổi? |
|---|---|---|
| AWS, EKS, IAM, RDS/S3/ECR, domain/ACM, Argo CD | iris-infrastructure/Terraform | Infrastructure workflows |
| GitHub ruleset/variables/app Environments | Terraform governance/github-config | Hai control-plane workflows |
| Add-ons, image/config deploy, InferenceService model version | iris-gitops/main | Argo CD sau GitOps PR merge |
| MLflow image | iris-model-registry | CI phát workload intent; GitOps render |
| Serving image/config contract | iris-inference-service | CI phát workload intent; GitOps render |
| Dataset/DVC/training image/model-result | iris-data-pipeline | CI upload S3; Argo train |
| Model metadata/alias | MLflow trong RDS | Training đăng ký version; GitOps-owned promoter đổi alias |
| Artifact model/DVC/Argo | S3 versioned buckets | Owner tương ứng, recovery có kiểm soát |
| Secret value | RDS/Secrets Manager hoặc GH Environment secret | RDS hoặc operator rotate/seed |

Infrastructure gửi contract, không sửa GitOps manifest. App CI không ghi manifest. Argo CD không
reconcile GitHub Variables hoặc Terraform state. Rollback phải đi vào đúng owner để tránh lần sync
kế tiếp ghi đè sửa chữa thủ công.

## 2. Trước mọi rollback

1. Dừng phát hành mới ở tầng liên quan: không merge PR app/data/infra mới; kiểm tra run/PR đang chờ.
   Dừng merge không tự dừng Argo Workflow đang chạy: nếu cần, operator phải suspend/stop đúng workflow
   và vô hiệu hóa/đóng các proposal lỗi có thể tiếp tục promote. Không hủy mù Terraform apply.
2. Ghi baseline: Git SHA, image digest, runtime schema/config, numeric model version, champion alias,
   KServe generation/traffic, workflow UID và Terraform state version. Không ghi secret value vào log.
3. Xác minh bản cũ vẫn tồn tại và tương thích: ECR image, model artifact S3, metadata RDS, schema DB.
4. Tạo PR sửa đúng phần, giữ thay đổi hợp lệ khác đã được merge sau release lỗi.
5. Merge sau CI rồi kiểm tra trạng thái thực: Argo Ready/observedGeneration, smoke, RPS/p95/errors.
   CI xanh hay dispatch HTTP thành công không chứng minh live workload đã phục hồi.

## 3. Lỗi trước deploy

- PR test/plan/schema/signature fail: chưa đổi live desired state; sửa PR, không cần rollback cluster.
- Image đã push nhưng intent/renderer fail: image tồn tại trong ECR nhưng chưa được chọn để chạy.
  Sửa lỗi và retry đúng workflow; không cần xóa image.
- GitOps PR chưa merge: đóng/sửa PR; production vẫn dùng main cũ. Kiểm tra chưa có thay đổi khác.
- Terraform apply một phần rồi bước sau fail: tài nguyên đã tạo vẫn tồn tại/tính phí. Xem state và
  plan mới; sửa credential/network/quota rồi reconcile, không assume cả transaction đã rollback.

## 4. Model candidate không đạt offline gate

Training log metric/model-result, nhưng không có proposal canary/bootstrap khi gate không đạt.
Champion và serving baseline không đổi. Sửa data/params/code bằng PR data, phát một dataset event mới.
Không xóa baseline hoặc tự gán champion cho candidate chỉ để bypass gate.

## 5. Canary 10% đo được nhưng SLO không đạt — đã có nhánh tự động đề xuất rollback

Ví dụ baseline v7, candidate v8:

```text
Model PR canary v8 -> operator merge -> Argo CD/KServe 90% v7 + 10% v8
    -> smoke -> evaluator đọc metric riêng model_version=8
    -> evaluator hoàn tất, passed=false
    -> propose-rollback -> model-release intent
    -> GitOps model-release.yml -> PR:
         MODEL_URI=models:/iris-classifier/7
         MODEL_VERSION=7
         stable-model-version=7
         xóa canaryTrafficPercent và candidate annotation
    -> operator merge -> Argo CD/KServe baseline 100% -> chờ Ready
```

Champion vẫn v7 vì alias chỉ đổi sau rollout 100% thành công. Không chỉ sửa alias để rollback:
serving được pin numeric version nên alias thay đổi không tự đổi pod đang chạy.
Renderer kiểm tra candidate/baseline đang active để từ chối intent cũ. Trường hợp đã rollback đúng
baseline có thể retry an toàn. Đây là tự động mở PR, không tự merge hoặc tức thì ngắt traffic lỗi.

## 6. Smoke lỗi, Prometheus unavailable, candidate không Ready hoặc quá hạn PR — chưa tự rollback

Workflow DAG chỉ đi nhánh rollback khi observe-canary Succeeded và kết quả passed=false.
Nếu generate-traffic fail, query Prometheus ném exception, hoặc wait-rollout timeout, nhánh đó không
chạy. Canary đã merge có thể vẫn active. Nếu Prometheus trả không có traffic nhưng query thành công,
evaluator có thể hoàn tất với passed=false sau thời gian quan sát: đây khác lỗi transport/HTTP.

Operator xem KServe thực tế và main, dừng lifecycle/proposal lỗi có thể tiếp tục promote, rồi mở PR
khôi phục đúng baseline như mục 5. Chỉ replay rollback intent khi state vẫn đúng candidate/baseline;
không bỏ guard để gửi intent stale. Không có watchdog tự rollback mọi loại lỗi trong source hiện tại.

## 7. Model đã lên 100% rồi mới phát hiện sai

Nhánh action=rollback hiện tại chỉ xử lý matching active canary hoặc trạng thái đã rollback đúng
baseline. Sau action=promote, candidate marker đã bị xóa; replay intent rollback cũ sẽ bị từ chối.

Đây là operator recovery, chưa có workflow rollback-after-promotion riêng:

1. Dừng lifecycle mới/đang chờ; xác nhận version tốt và artifact còn dùng được.
2. PR GitOps khôi phục MODEL_URI/MODEL_VERSION/stable annotation về numeric version tốt, không
   canary field/annotation; giữ nguyên image/config nếu chúng không liên quan.
3. Chờ rollout Ready + smoke pass.
4. Qua MLflow API với quyền operator, đưa champion về version tốt. Có thể dùng module hiện hữu
   automation.model_release.registry_promoter với --expected-current-version là champion đã kiểm tra;
   module yêu cầu model target có quality_gate=passed. Không dùng thao tác này để vượt quality gate.
5. Đối chiếu Git desired model, live model và alias trước khi cho training tiếp tục.

Promoter chỉ đọc/kiểm tra baseline rồi ghi alias, không có atomic CAS hoặc transaction xuyên hệ
thống. Argo mutex serialize lifecycle bình thường nhưng không chặn một operator ngoài luồng.
Nếu rollout 100% đã Ready nhưng update alias fail, serving vẫn có thể chạy model mới trong khi
champion còn cũ. Retry alias step sau khi xác minh precondition; không mặc định rollback model.

Lần bootstrap model đầu tiên không có baseline: không có bản cũ để rollback. Nếu hỏng, giữ API
unready/giới hạn ingress, sửa model/image, rồi tiếp tục bootstrap với version phù hợp và intent mới.

## 8. Image hoặc runtime config sai

Normal recovery: workload-release intent mới dùng known-good digest/config/schema; hoặc GitOps PR
khôi phục đúng desired-state fields. Không dùng latest và không rebuild source cũ rồi khẳng định
đó là cùng artifact. Một image mới có thể phụ thuộc config mới: rollback cả bộ tương thích trong PR.

Inference model lifecycle và workload release có shared concurrency, open-PR checks và guard
active-canary. Khôi phục model/giải quyết PR model trước khi đổi image/config thông thường. PR thủ
công không tự được các receiver guard bảo vệ; operator phải giữ nguyên nguyên tắc này.

- Config-only: không cần rebuild image. Giữ đúng type/key/schema.
- Image + config: phục hồi coherent pair. Config đã render vào env/ConfigMap không phải secret.
- Runtime schema breaking: có thể cần expand/migrate/contract, không phải một revert nguyên khối.
- Automation image lỗi: GitOps PR pin release-automation digest cũ cho workflow mới. Workflow/pod
  đang chạy đã resolve image không tự đổi theo WorkflowTemplate mới; xử lý riêng đúng workflow.
- MLflow image downgrade: kiểm tra database migration compatibility trước. Git revert không undo
  schema/data migration. Khi cần, phục hồi DB riêng theo mục 12.

Sửa source release/config phía app bằng PR tương ứng để đợt release kế tiếp không đưa config lỗi
trở lại. Desired state đang deploy vẫn là GitOps main.

## 9. GitOps platform/add-on hỏng

PR iris-gitops pin chart/manifests về bản tương thích đã biết; Argo CD reconcile. Revert có chọn lọc,
đặc biệt khi PR platform contract sửa nhiều resource. Không chỉ chạy kubectl rollout undo/helm
rollback rồi để Git giữ bản lỗi: self-heal có thể áp lại desired state lỗi.

CRD/schema/controller downgrade cần compatibility check; không xóa CRD để cài lại vì có thể xóa
custom resources. Controller chết hoặc Argo CD mất quyền cần repair controller/credential trước.
Argo CD chart thuộc Terraform infrastructure, không sửa chart Argo CD ở GitOps.
Auto-sync không phải auto-rollback theo sức khỏe. Xem [Argo CD automated sync](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/).

## 10. AWS/Terraform hoặc Argo CD release hỏng

- IAM/network/node config: revert/sửa HCL bằng PR infra -> plan -> apply. Đọc plan kỹ: giảm node,
  thay subnet hoặc resource replacement có thể gây gián đoạn, không phải mọi resource đều đảo ngược.
- Foundation IAM tự khóa CI: dùng operator break-glass sửa đúng trust/policy, giữ state, sau đó PR
  và reconcile. Không cấp wildcard administrator như cách sửa mặc định.
- Platform apply xong nhưng GitHub config/contract fail: sửa đoạn bàn giao rồi retry từ state hiện
  hữu. Không destroy EKS/RDS vì credential GitHub thiếu.
- helm_release.argocd và helm_release.argocd_root có atomic=true: Helm có thể phục hồi từng release khi upgrade/install thất bại;
  điều đó không rollback các tài nguyên AWS đã apply, database hoặc toàn bộ CRDs. Với bản chart
  đã deploy thành công nhưng lỗi chức năng, sửa pin/values trong infrastructure rồi plan/apply.
- EKS version: không coi giảm chuỗi version HCL là rollback đã được kiểm chứng. AWS hiện có rollback
  về previous minor trong 7 ngày sau in-place upgrade, có điều kiện; managed node groups/add-ons cần
  xử lý riêng. Repo chưa có runbook automation cho API này. Kiểm tra readiness và provider/module
  support trước thao tác; nếu không đủ điều kiện, dùng repair/forward-fix hoặc cluster thay thế.
  Xem [AWS EKS rollback](https://docs.aws.amazon.com/eks/latest/userguide/rollback-cluster.html).
- Terraform state là sổ ánh xạ, không phải backup tài nguyên. Restore state cũ không hồi phục RDS
  hay EKS; có thể làm Terraform mất track tài nguyên thật. Chỉ sửa/restore state trong sự cố state,
  khi đã ngừng writer, giữ bản backup hiện tại, đối chiếu AWS và import/refresh có kiểm soát.

## 11. Domain/TLS/NLB/ExternalDNS

Terraform sở hữu zone/ACM/IAM; GitOps khai báo ingress hostname/certificate, AWS LBC tạo NLB và
ExternalDNS ghi record. Khôi phục đúng tầng: cert/zone metadata sai -> domain/infra PR rồi contract;
Service/hostname annotation sai -> GitOps PR. Không để Terraform và ExternalDNS cùng ghi một record.
Registrar delegation nằm ngoài code: operator khôi phục NS đúng; việc này không tức thì do cache.
Không xóa zone hoặc revoke certificate đang phục vụ chỉ để thử lại workflow. Domain đổi output sẽ
dispatch platform; một thay đổi DNS chưa chắc cần rollback image/model.

## 12. RDS/S3/data recovery

Multi-AZ phục vụ availability/failover, không bảo vệ khỏi ghi sai dữ liệu hoặc migration lỗi.
Deployment profile Free Tier hiện là Single-AZ, backup retention một ngày và deletion protection;
do đó khả năng phục hồi thấp hơn production thật. Sau khi nâng account plan, đặt lại Multi-AZ và
retention tối thiểu 14 ngày rồi kiểm thử restore. PITR tạo DB instance mới, không ghi đè instance
cũ tại chỗ. Xem [AWS RDS PITR](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIT.html).

Trình tự khôi phục cần operator phối hợp:

1. Ngừng training/promotion/MLflow writes liên quan; ghi endpoint và mốc dữ liệu.
2. Restore DB mới; xác minh registry/model-version/alias và quyền truy cập artifact S3 còn nhất quán.
3. Đưa DB phục hồi vào quản lý Terraform bằng quy trình adopt/import hoặc thiết kế resource mới đã
   review; root hiện tại chưa có switch PITR tự động. Không đổi endpoint thủ công rồi để Terraform
   tạo lại database mặc định.
4. Công bố endpoint/secret reference mới qua platform contract -> GitOps PR; External Secrets sync
   secret tương ứng, MLflow rollout/reconnect, kiểm tra health và model load rồi mới bật writers.

S3 bật versioning; noncurrent object versions có retention 90 ngày. Chỉ restore đúng object/version
đã kiểm tra. Metadata model ở RDS phải trỏ tới artifact thật. Dataset restore/copy vào prefix
datasets/ có thể phát S3 event mới; kiểm soát Sensor/training trước khi thao tác.

DVC giúp chọn lại data/params/code bằng Git revision + dvc pull; train lại là một candidate/release
mới, không tự đưa model đang phục vụ về baseline. Rerun CI cùng SHA/digest có thể bỏ upload dataset
đã tồn tại, nên không mặc định phát event mới.

## 13. Secrets, SQS và monitoring

- Key bị revoke/lộ: tạo key mới, cập nhật đúng GH Environment secret hoặc ASM container rồi kiểm tra
  workflow mới. Không rollback về key đã compromise. Không chứa PEM trong GitOps/Terraform state.
- External Secrets sync không có nghĩa process đã reload env. Với ứng dụng đọc secret qua env,
  cần rollout/restart có kiểm soát; repo chưa có generic secret-change reloader. GitOps receiver đọc
  ASM khi run mới; pod workflow đã chạy không tự nhận key mới.
- SQS main retention 4 ngày, DLQ 14 ngày. DLQ redrive có thể gây train trùng; không purge queue để
  xử lý model lỗi. Message đã được EventSource nhận/ack không có nghĩa Argo train cuối cùng thành
  công; train fail không được bảo đảm quay về SQS/DLQ. Xác minh event/workflow trước replay.
- Monitoring hỏng: khôi phục chart/config scrape trước đánh giá canary. Missing metric không phải
  bằng chứng pass; lỗi Prometheus transport hiện chưa tự mở rollback PR.

## 14. Kiểm tra sau phục hồi

```bash
kubectl -n argocd get applications.argoproj.io
kubectl -n mlops get inferenceservice iris-classifier -o yaml
kubectl -n mlops get pods
kubectl -n argo get workflows.argoproj.io
kubectl get externalsecrets -A
```

Đối chiếu numeric model version trong response/readiness, GitOps main và champion alias.
Chạy tools/external_smoke.py của inference-service với domain thật, xem p95/errors/RPS và metric
theo model_version. Ghi incident/recovery SHA và chỉ mở lại release sau khi xác nhận live state.

Chưa có automated PITR restore, universal onExit rollback, rollback-after-promotion workflow hay
disaster-recovery drill. Các thao tác repair ở đây là runbook cho operator, không phải automation
mới được triển khai trong lần sửa solo policy.
