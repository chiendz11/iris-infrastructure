# Secret management contract

## Nguồn sự thật

- RDS master password: RDS tự sinh, rotate và lưu trong AWS Secrets Manager.
- Runtime secret khác: tạo trực tiếp trong Secrets Manager khi có thể.
- Kubernetes workload: chỉ đọc Kubernetes Secret do External Secrets đồng bộ; không gọi GitHub.
- GitHub Actions: dùng OIDC để nhận AWS credential ngắn hạn; không lưu static AWS access key.

## Third-party token

Nếu nhà cung cấp chưa có integration ghi trực tiếp vào Secrets Manager, có thể seed token một lần:

1. Lưu tạm token trong GitHub Environment Secret được giới hạn protected branch và owner self-approval.
2. Workflow dùng AWS OIDC gọi `secretsmanager:PutSecretValue` và tuyệt đối không log giá trị.
3. Xóa GitHub Secret sau khi seed, hoặc rotate token nếu nó phải tồn tại lâu ở hai nơi.
4. External Secrets đồng bộ từ Secrets Manager xuống namespace/service account được phép.

GitHub Secret không nên là nguồn sự thật dài hạn cho runtime secret vì tạo hai nơi cần rotate và
audit. ARN/tên secret là metadata không nhạy cảm và có thể commit; secret value thì không.

## Thứ tự provisioning

AWS Secrets Manager là dịch vụ có sẵn; Terraform tạo resource metadata/container bằng
`aws_secretsmanager_secret`, nhưng không quản lý `aws_secretsmanager_secret_version` cho giá trị
nhạy cảm để value không đi vào Terraform state. Job seed phải `needs` Terraform apply, chạy trong
GitHub Environment `prod`, assume AWS role bằng OIDC rồi gọi `secretsmanager:PutSecretValue`.

RDS là trường hợp riêng: `manage_master_user_password=true` khiến RDS tự sinh và lưu password vào
Secrets Manager ngay trong Terraform apply. Không tạo GitHub Secret và không chạy seed job cho RDS.

Chỉ thêm resource/job seed khi workload thực sự có third-party token. Release automation là
integration đầu tiên như vậy: Terraform tạo container không có version, operator seed GitHub App
credential sau platform apply, và External Secrets không thể materialize Kubernetes Secret trước
bước seed. `reusable-platform-handoff.yml` kiểm tra `AWSCURRENT` bằng `DescribeSecret` và dừng trước GitOps
dispatch nếu thiếu; check không đọc value. Seed xong rerun failed jobs hoặc dispatch `production-infra.yml` với `scope=handoff`; không apply AWS lại.

## Argo CD SSO và repository credential

Hai loại secret này là opt-in. Tạo JSON secret trực tiếp trong Secrets Manager, thêm **ARN** vào
`additional_external_secret_arns`, rồi enable ExternalSecret tương ứng trong `iris-gitops`.
Terraform chỉ mở quyền `GetSecretValue/DescribeSecret` cho ARN được liệt kê; wildcard secret access
không được dùng. GitOps repo hiện public nên repository credential chưa cần được tạo. SSO chưa bật
cho tới khi có OAuth/IdP client thật; trong thời gian đó admin local tắt và operator dùng EKS RBAC
qua `argocd login --core`.

## GitHub control-plane credentials

Các App control-plane có identity và blast radius riêng:

- `GOVERNANCE_APP_PRIVATE_KEY`: ruleset của năm repo, Administration write.
- `CONFIG_SYNC_APP_PRIVATE_KEY`: non-secret variables và app `prod` Environments, install cả năm repo.
- `INTENT_PUBLISHER_APP_PRIVATE_KEY`: cùng tên biến nhưng mỗi app Environment giữ key khác nhau:
  inference chỉ giữ `iris-inference-publisher`, model-registry chỉ giữ
  `iris-model-registry-publisher`. Cả hai chỉ có Actions write.
- `PLATFORM_CONTRACT_PUBLISHER_APP_PRIVATE_KEY`: chỉ tồn tại trong
  `iris-infrastructure/prod`, có Actions write và dispatch riêng platform contract. Receiver kiểm
  tra exact bot identity trước khi dùng AWS/GitOps credential.

Client ID là metadata không nhạy cảm; private key là root credential dài hạn trong Environment
secret `prod` và chỉ được dùng trong job đúng Environment/protected branch. Workflow dùng pinned
`actions/create-github-app-token` để mint installation token có hạn một giờ và scope đúng repo.

Private key/token không được khai báo thành Terraform variable, không được commit vào tfvars và
không được quản lý bằng `github_actions_*_secret`, vì secret value khi đó có thể đi vào Terraform
state. In-cluster dispatcher dùng App thứ ba `iris-model-release-publisher`, được seed riêng vào
AWS và không chia sẻ key với application repo. Platform publisher không chạy trong cluster và
không được seed vào AWS. Quy trình bootstrap/rotation nằm trong `GITHUB_CONTROL_PLANE.md`.

## Release automation runtime identities

Hai identity không dùng chung quyền:

- `iris-model-release-publisher`: Actions write only. Chỉ Dispatch Pod chạy image automation của DevOps
  nhận key qua External Secrets để phát model-release contract. Training image không chứa dispatcher
  code và không nhận key. Terraform tạo container
  `<project>-<environment>/github-app/model-release-publisher` và External Secrets chỉ được đọc container
  này.
- `iris-gitops-automation`: Contents/Pull requests write chỉ trên `iris-gitops`. Renderer workflow
  trên trusted `main` assume OIDC role riêng và đọc container
  `<project>-<environment>/github-app/gitops-automation`; Kubernetes không được đọc container này.

Platform contract không chứa role ARN hoặc secret ARN của `iris-gitops-automation`. Receiver lấy
hai reference đó từ Terraform-managed repository variables. Vì vậy dispatch payload không thể chọn
AWS role hay secret khác để lợi dụng receiver như một confused deputy.

Các App đều không có Kubernetes write, AWS administration, ruleset bypass hay quyền merge.
Terraform không tạo `aws_secretsmanager_secret_version`.

Mỗi giá trị JSON `{client_id, private_key}` được seed/rotate trực tiếp bằng
`scripts/seed-github-app-secret.sh` với kind `model-release-publisher` hoặc `gitops-automation`. Branch
protection vẫn yêu cầu GitOps validation; solo operator là chủ thể merge production
PR.
