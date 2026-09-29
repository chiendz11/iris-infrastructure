# Vận hành solo: tự approve deployment, không cần reviewer thứ hai cho PR

## Hai loại approval khác nhau

- Ruleset của cả 5 repo: 0 required PR approvals, không required CODEOWNER/last-push approval.
  Vẫn bắt buộc PR, required CI, resolve conversation; không force-push/xóa main.
- Deployment: owner cá nhân `chiendz11` là required reviewer của Environment `prod`,
  `prevent_self_review=false` cho phép tự approve run mình khởi tạo.
- Protected-branch policy và `can_admins_bypass=false` vẫn giữ. Self-approval là duyệt bình thường,
  không phải admin bypass.
- Ba app Environments do `terraform/github-config` quản lý; reviewer lấy từ `github_owner`.
  Infrastructure `prod` là root-of-trust ngoài Terraform, cấu hình bằng owner helper.
- Chỉ có Environment `prod`; không thêm staging, dev hoặc prod-dns.
- Không cần biến `PRODUCTION_REVIEWER_USERNAMES_JSON` hay `production_reviewer_usernames`.
  Metadata cũ không được đọc. Không thêm secret, AWS role hoặc OIDC subject mới.
- GitOps receiver chỉ mở PR, không auto-merge. Bạn tự xem diff rồi merge sau khi CI xanh.

Đây là kiểm soát có chủ ý trước deploy cho người làm solo, không phải kiểm soát độc lập hai người.
Với zero PR reviews, token Contents/PR-write có thể đủ quyền merge PR đã qua CI; code receiver
không gọi merge nhưng ruleset không enforce chỉ con người được merge.

## Những job nào cần bạn approve?

Bảng áp dụng sau khi helper cấu hình infra Environment và Terraform apply app Environments.
Job chỉ chờ khi điều kiện `if` cho phép chạy; tên file không đồng nghĩa mọi job trong file đều chờ.

| Repository | Workflow / job | Khi nào bạn cần approve |
|---|---|---|
| iris-infrastructure | production-infra / foundation / apply-foundation | Reconcile state backend, OIDC, IAM foundation |
| iris-infrastructure | production-infra / governance / apply-governance | Apply GitHub rulesets |
| iris-infrastructure | production-infra / github-config-before hoặc after / apply-github-config | Apply Variables/app Environments; gọi reusable trước/sau platform theo needs |
| iris-infrastructure | production-infra / domain / apply-domain-zone | Tạo zone lần đầu hoặc reconcile domain day-2 |
| iris-infrastructure | terraform-domain-certificate.yml / apply-domain-certificate | Sau tạo zone/đổi NS; hoặc certificate retry thủ công |
| iris-infrastructure | production-infra / platform / apply-platform | Apply AWS/EKS/Argo CD |
| iris-infrastructure | production-infra / handoff | Kiểm tra state/credential và phát platform contract; dùng prod secrets |
| iris-data-pipeline | ci.yml / publish-data | Publish training image, DVC/data lên AWS; có thể khởi động cloud training |
| iris-model-registry | ci.yml / publish-workload-release | Publish image/config release intent |
| iris-inference-service | ci.yml / publish-workload-release | Publish image/config release intent |

Mở Actions run → **Review deployments** → chọn **prod** → **Approve and deploy**.
Các job thực thi trong reusable gắn `environment: prod`. GitHub UI có thể gom deployment cùng
Environment trong một run; không coi mỗi stage là một lần phê duyệt độc lập. Certificate cố ý là
run riêng để giữ checkpoint sau khi operator sửa NS.

Không cần deployment approval cho:

- PR CI/test/validate/speculative plan; các job phân loại thay đổi và dispatch-only.
- GitOps `workload-release.yml`, `model-release.yml`, `platform-reconcile.yml`: validate/render/mở PR.
- GitOps `release-automation-image.yml` hiện không có Environment gate: build/publish image DevOps,
  mở PR pin digest. Việc triển khai image vẫn qua PR merge; không thêm approval vào workflow này.
- Argo CD sync và Argo Workflows training/evaluation không phải GitHub deployment jobs.
  Các GitOps PR canary/promote/rollback vẫn cần bạn merge theo lifecycle hiện tại.
- Local Terraform/script không có nút GitHub approval; operator tự chịu trách nhiệm lệnh mình chạy.

Approve hiện cho phép job chạy trên ref được chọn; refreshed Terraform plan được tạo **sau** gate.
Bạn nên xem PR plan/diff trước khi approve. Chưa phải mô hình duyệt chính xác một saved-plan artifact.

## Bật cấu hình trên hệ thống hiện hữu

Sửa file local không tự cập nhật GitHub Settings.

1. Từ repo infrastructure, dùng owner credential chạy đúng một helper:

   ```bash
   bash scripts/configure-solo-environment.sh
   ```

   Script GET user ID của repository owner rồi PUT protection của `iris-infrastructure/prod`:
   reviewer là owner, cho phép self-review, không bypass. Không thay variables/secrets/rulesets,
   không xóa/recreate Environment, không đụng app Environments và không đọc Terraform state.
   Script từ chối owner không phải tài khoản cá nhân trước khi mutate.

2. Đưa thay đổi qua PR/CI và merge main. Approve run `production-infra / github-config-before hoặc after` để Terraform
   thêm cùng owner reviewer cho ba app Environments. Workflow tự chạy theo thay đổi root config;
   orchestrator cũng gọi nó khi foundation/platform cần cập nhật metadata. Không tạo run trùng một chain đang chạy.
3. Kiểm tra Settings: infra và 3 app có required reviewer `chiendz11`, Prevent self-review tắt,
   admin bypass tắt; protected branches giữ nguyên. PR requirements vẫn zero reviews.
4. Các lần update sau dùng CI bình thường. Không chạy lại day-0 `configure-github.sh` chỉ để đổi gate.

Nếu dựng mới: bootstrap foundation + migrate state trước, rồi chạy
`./scripts/configure-github.sh <domain> <admin-role-or-empty>` một lần. Nó gọi cùng helper để
seed infra gate và các biến cần thiết. Sau đó thiết lập Apps như `GITHUB_CONTROL_PLANE.md`.

Không chạy helper bằng producer App hoặc đưa vào CI tự thay protection của chính job đó.
Required reviewers phải được GitHub plan/visibility hỗ trợ; nếu API báo không hỗ trợ thì không
được bỏ gate âm thầm để workflow xanh. Kiểm tra Settings trước khi triển khai.

## DNS: chờ bạn approve sau khi đổi nameserver

Lần tạo domain đầu tiên:

```text
production-infra / domain
  → bạn approve prod
  → tạo Route53 Hosted Zone, in NS vào summary
  → tự dispatch terraform-domain-certificate.yml
       → run mới chờ prod approval (chưa bắt đầu poll DNS)
       → bạn cập nhật NS tại registrar, rồi approve
       → đọc lại domain/NS từ Terraform state, kiểm tra đúng domain
       → kiểm tra public DNS
       → tạo/validate ACM
       → tự dispatch production-infra.yml scope=platform
            → bạn approve prod rồi platform apply
```

Tách certificate thành workflow run riêng để có approval boundary rõ ràng sau zone, vẫn dùng
cùng `prod`, cùng backend và OIDC role. Không giữ runner chỉ để chờ bạn đăng nhập registrar.
`wait-for-dns-delegation.sh` chỉ chạy sau approval; poll khoảng 20 phút (40 lần, cách 30 giây)
để chịu được propagation trễ. Không khớp thì fail, không request ACM hoặc dispatch platform.
ACM còn phải tự DNS-validation thành công; resolver runner khớp không có nghĩa mọi cache toàn cầu đã hết hạn.

Retry certificate khi zone đã có, NS đã sửa nhưng lần trước propagation/handoff lỗi:

```bash
gh workflow run terraform-domain-certificate.yml \
  --repo chiendz11/iris-infrastructure --ref main
```

Run này vẫn phải được bạn approve. Nếu domain/state cần sửa trước, dùng domain lifecycle thay vì
ép `DOMAIN_DELEGATED=true`. Domain day-2 đã sẵn sàng được kiểm tra/reconcile ngay trong
`apply-domain-zone` đã approve; không tạo lại gate delegation mỗi lần. Domain day-2 cùng run cho phép stage platform chạy khi output/source đổi. Certificate hoàn tất
dispatch orchestrator với scope=platform và expected_sha; SHA lỗi thời bị chặn trước credentials.

AWS workflows vẫn chung concurrency `terraform-production`, không đảm bảo FIFO. Không merge
nhiều đợt infrastructure khi chain cũ chưa xong; chưa có cơ chế ưu tiên emergency run.

## Khi có thêm team

Làm PR riêng để đổi required PR reviews/CODEOWNERS và deployment reviewer sang người/team phù hợp,
bật prevent-self-review nếu cần separation of duties. Cập nhật tests/verifier và root Environment
ngoài Terraform tương ứng. Chỉ enforce sau khi collaborator và required checks đã sẵn sàng.
