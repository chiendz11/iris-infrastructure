# Production infrastructure orchestration

## Mục tiêu và ownership

Chỉ có runtime environment `production` và GitHub Environment `prod`.
Refactor này thay cách GitHub Actions điều phối, không gộp Terraform state, đổi resource address,
deploy AWS, thay GitOps API hay chuyển quyền deploy workload từ Argo CD sang CI.

- `terraform.yml`: CI của mọi PR, static validation + speculative plans + required `pr-gate`.
- `production-infra.yml`: một entrypoint nhận push main hoặc yêu cầu reconcile có scope.
- `reusable-*.yml`: triển khai từng stage; chỉ có `workflow_call`, không có push/dispatch trigger.
- `terraform-domain-certificate.yml`: entrypoint riêng cho checkpoint DNS cần thao tác tại registrar.

Các workflow cũ `terraform-foundation.yml`, `terraform-governance.yml`, `terraform-github-config.yml`,
`terraform-domain.yml`, `terraform-platform.yml` đã chuyển phần thực thi sang reusable tương ứng.
Không giữ push trigger cũ, tránh hai run tranh quyền apply cùng thay đổi.

## Nhìn flow ở một chỗ

```text
PR → terraform.yml → pr-gate → merge main
                                  ↓
                          production-infra
                                  ↓
                                select
                                  ↓
                            foundation?
                                  ↓
                            governance?
                                  ↓
                        github-config-before?
                                  ↓
                               domain?
                     ┌────────────┴──────────────┐
              cần delegation                 ready/không đổi
                     ↓                           ↓
           certificate run riêng              platform?
           owner sửa NS + approve                 ↓
           verify DNS → ACM                github-config-after
                     ↓                           ↓
           orchestrator scope=platform         handoff
                                                 ↓
                                  GitOps platform-reconcile → PR
                                                 ↓ merge
                                              Argo CD
```

`?` nghĩa là chỉ chạy khi root/helper tương ứng đổi hoặc output prerequisite yêu cầu. Không phải
mỗi run đi qua mọi bước. Governance khi được chọn phải thành công trước config/domain/platform;
nó không phải một nhánh dispatch chạy song song không được kiểm tra nữa.

`needs` biểu diễn dependency. `if` phân biệt skipped (không cần chạy) với failure/cancelled.
Platform-only vẫn chạy khi foundation/domain skipped. Nếu stage bắt buộc lỗi, downstream dừng.
Không có `always()` vô điều kiện để apply sau thất bại.

## Quy tắc chọn stage

Một file `scripts/plan_production.py` được dùng bởi cả PR và production:

| Source thay đổi | Stage được chọn |
|---|---|
| `terraform/bootstrap/**` | foundation, sau đó github-config-before |
| `terraform/github-governance/**`, ruleset verifier | governance |
| `terraform/github-config/**` | github-config-before |
| `terraform/domain/**`, DNS helpers, certificate workflow | domain |
| `terraform/platform/**`, production.tfvars, contract builder/schema | platform |
| Reusable của một root | Root đó |
| Orchestrator/shared classifier/revision guard | Tất cả root, để review/reconcile dependency đầy đủ |
| README/docs/tests/PR-only workflow | Không apply |

Domain so sánh fingerprint (name/readiness/zone/cert/state existence). Output đã đổi hoặc source
platform cùng thay đổi thì chạy platform; nếu delegation chưa xong thì hoãn platform sang run sau.
Foundation apply-role ARN thay đổi cũng yêu cầu reconcile platform. Thay backend identity hoặc
rename/delete automation role vẫn là migration/break-glass có kế hoạch, không phải day-2 bình thường.

PR dùng cùng mapping nhưng không tự apply các dependency. Các deferred-plan guard trước đây vẫn giữ.
Job `select` có thể chạy cho docs-only merge nhưng không nhận cloud/App credential và không mutate.

## Output, Variables và secret

Foundation xuất một JSON context chỉ gồm bucket, KMS ARN và ba apply-role ARN. Các stage cùng run
nhận context qua output/input thay vì chờ `${{ vars.* }}` tự refresh sau khi config đã ghi Variables.
Foundation không chạy thì các stage dùng cấu hình đã được bootstrap/reconcile ở lần trước.

`github-config-before` và `github-config-after` gọi cùng `reusable-github-config.yml`:

- Before: khi foundation/config thay đổi, đồng bộ control-plane metadata trước downstream.
- After: khi platform vừa apply, đồng bộ ECR/DVC/IAM/receiver metadata trước GitOps handoff.
- Khi initial platform chưa tồn tại, config chỉ quản lý phần foundation. Chỉ S3 NotFound được hiểu
  là chưa có state; AccessDenied/network error làm job fail, không coi là môi trường mới.
- Không truyền secret value trong output/context/contract. Job thực thi gắn `environment: prod`
  và lấy đúng Environment secret. Không dùng `secrets: inherit` cấp toàn bộ secret cho mọi stage.
- AWS OIDC và dedicated governance/configuration roles giữ nguyên. Không có AWS access key mới.

## Handoff không phải AWS apply

`reusable-platform.yml` chỉ quản lý Terraform AWS/EKS/Argo CD.
Sau đó config-after thành công mới đến `reusable-platform-handoff.yml`:

1. Kiểm tra trusted repository/main/SHA trước credential.
2. Init và đọc domain readiness nếu public domain bật.
3. Plan platform có refresh với `-detailed-exitcode`; chỉ exit 0 (không có diff) được tiếp tục.
   Exit 1 hoặc 2 đều chặn; không gọi `terraform apply`.
4. Đọc output state, tạo contract theo allowlist, validate JSON Schema.
5. Kiểm tra metadata `AWSCURRENT` của hai runtime App secret, không đọc value.
6. Kiểm tra SHA chưa lỗi thời, mint dedicated platform-publisher token và dispatch GitOps receiver.

Không còn nhận JSON contract tùy ý qua infrastructure dispatch hoặc kiểm tra actor bot của một
internal dispatch đã bị bỏ. Trust boundary mới là main được bảo vệ, prod approval, state có thẩm
quyền, no-diff preflight và dedicated publisher. Receiver GitOps vẫn kiểm tra exact App bot.

Lần đầu thiếu seed: AWS đã apply và GitHub Variables đã reconcile; handoff fail-closed. Seed bằng
`seed-github-app-secret.sh`, rồi retry failed jobs ở cùng main hoặc dùng scope=handoff. Nếu có thay
đổi AWS chưa apply, handoff không được dùng để lách platform gate: nó yêu cầu scope=platform trước.

Scope handoff vẫn có thể **apply GitHub configuration**; chỉ không apply AWS platform.
No-diff plan chứng minh config/state được refresh phù hợp, không chứng minh workload healthy.
Không upload tfstate/tfplan hoặc secret làm artifact để chuyển giữa workflow.

## Approval, DNS và concurrency

Actual mutation/handoff jobs nằm trong reusable và gắn `environment: prod`; caller chỉ gọi bằng
`uses`. OIDC trust vẫn là repository + environment prod. Infra prod reviewer do owner cấu hình
ngoài Terraform. Self-approval giữ nguyên, không thêm reviewer thứ hai hay Environment mới.

Trong cùng một run, GitHub có thể gom deployment cùng Environment; không hứa mỗi stage là một
nút approve độc lập. Certificate giữ run riêng để có checkpoint rõ ràng sau khi in NS. Run đó đọc
lại zone state, xác minh public DNS, chờ ACM validation rồi mới dispatch scope=platform.
Approval không thay cho kiểm tra DNS và cũng không phải duyệt exact saved-plan artifact: plan được
tạo sau gate, được kiểm tra rồi apply ngay trong job như trước.

Orchestrator và certificate entrypoint chung outer concurrency `terraform-production`,
`cancel-in-progress: false`. Reusable không lấy lại lock đó. Dispatch chỉ tạo run mới, không giữ
runner chờ run con, nên không deadlock chính lock mình đang giữ. Terraform vẫn lock từng state.

Concurrency không phải hàng đợi FIFO bền vững. GitHub có thể thay một pending run bằng run mới;
không merge nhiều đợt infra khi một chain đang chờ approve. Guard kiểm tra remote main trước
credentials, trước apply và trước publication: run cũ bị chặn, không âm thầm deploy revision mới.
Nếu main tiến thêm/pending run bị thay, review lại rồi dispatch `scope=all` để không bỏ sót root từ
commit trước. Đây là giới hạn vận hành được ghi rõ, chưa có persistent deployment queue/checkpoint.

Guard không phải khóa GitHub branch: main vẫn có thể tiến thêm sau lần kiểm tra cuối. Không merge
đợt mới giữa deployment là quy tắc vận hành của project; shared state lock không giải quyết race đó.

## Cách chạy

Day-0 vẫn là bootstrap foundation local → migrate S3/KMS → seed root-of-trust/Apps/prod credentials.
Sau đó merge PR đã qua CI sẽ tự trigger. Nếu code đã có trên main, chỉ cần dispatch scope=all một
lần khi prerequisite đã sẵn sàng. Không chạy đồng thời với chain đang tồn tại.

```bash
# Cập nhật/reconcile AWS platform; không đi lại vòng DNS
gh workflow run production-infra.yml --repo chiendz11/iris-infrastructure --ref main --field scope=platform

# Sau khi đã seed runtime App credentials, không apply lại AWS
gh workflow run production-infra.yml --repo chiendz11/iris-infrastructure --ref main --field scope=handoff

# Sau khi đã sửa NS nhưng certificate lần trước lỗi/timeout
gh workflow run terraform-domain-certificate.yml --repo chiendz11/iris-infrastructure --ref main
```

Scope khác: `foundation`, `governance`, `github-config`, `domain`, `all`.
Manual dispatch là retry/drift reconciliation, không thay lifecycle PR → CI → merge cho thay đổi code.
Không truyền `foundation` context bằng tay; đó là interface nội bộ giữa trusted reusable jobs.

## Lỗi và kiểm thử

- Stage lỗi trước apply: downstream dừng, sửa prerequisite rồi retry.
- Terraform apply lỗi một phần: đọc state/plan mới, không mặc định đã rollback AWS.
- Config-after lỗi: không gửi contract; repair configuration, retry scope=handoff.
- Handoff/seed lỗi: không destroy platform; seed/fix App rồi retry phần bàn giao.
- DNS chưa xong: không chạy platform; approve/retry certificate sau khi sửa registrar.
- GitOps PR chưa merge/Argo CD chưa Ready: kiểm tra lifecycle GitOps, không coi infra run xanh là
  ứng dụng đã được deploy thành công.

Local checks: actionlint, shell syntax, Python unit tests (path classification, DAG expression
simulation, skipped/failed/cancelled dependencies, stale SHA, handoff boundary), Terraform fmt và
mock-provider tests hiện hữu. Simulator không thay GitHub scheduler, approval/OIDC thật hoặc AWS
integration test. Refactor chưa được triển khai lên cloud.
