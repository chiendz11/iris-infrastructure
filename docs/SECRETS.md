# Secret management contract

## Nguồn sự thật

- RDS master password: RDS tự sinh, rotate và lưu trong AWS Secrets Manager.
- Runtime secret khác: tạo trực tiếp trong Secrets Manager khi có thể.
- Kubernetes workload: chỉ đọc Kubernetes Secret do External Secrets đồng bộ; không gọi GitHub.
- GitHub Actions: dùng OIDC để nhận AWS credential ngắn hạn; không lưu static AWS access key.

## Third-party token

Nếu nhà cung cấp chưa có integration ghi trực tiếp vào Secrets Manager, có thể seed token một lần:

1. Lưu tạm token trong GitHub Environment Secret được giới hạn reviewer/branch.
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

Chỉ thêm resource/job seed khi workload thực sự có third-party token. Model promotion là integration
đầu tiên như vậy: Terraform tạo container không có version, operator seed GitHub App credential sau
platform apply, và External Secrets không thể materialize Kubernetes Secret trước bước seed.

## Argo CD SSO và repository credential

Hai loại secret này là opt-in. Tạo JSON secret trực tiếp trong Secrets Manager, thêm **ARN** vào
`additional_external_secret_arns`, rồi enable ExternalSecret tương ứng trong `iris-gitops`.
Terraform chỉ mở quyền `GetSecretValue/DescribeSecret` cho ARN được liệt kê; wildcard secret access
không được dùng. GitOps repo hiện public nên repository credential chưa cần được tạo. SSO chưa bật
cho tới khi có OAuth/IdP client thật; trong thời gian đó admin local tắt và operator dùng EKS RBAC
qua `argocd login --core`.

## GitHub control-plane credentials

Ba App control-plane có identity và blast radius riêng:

- `GOVERNANCE_APP_PRIVATE_KEY`: ruleset của năm repo, Administration write.
- `CONFIG_SYNC_APP_PRIVATE_KEY`: non-secret variables và app `prod` Environments, install cả năm repo.
- `GITOPS_APP_PRIVATE_KEY`: chỉ tạo branch/pull request trong `iris-gitops`.

Client ID là metadata không nhạy cảm; private key là root credential dài hạn trong Environment
secret `prod` và chỉ được release sau approval. Workflow dùng pinned
`actions/create-github-app-token` để mint installation token có hạn một giờ và scope đúng repo.

Private key/token không được khai báo thành Terraform variable, không được commit vào tfvars và
không được quản lý bằng `github_actions_*_secret`, vì secret value khi đó có thể đi vào Terraform
state. Đây là credential control plane GitHub, không phải Kubernetes runtime secret nên không copy
sang AWS Secrets Manager. Quy trình bootstrap/rotation nằm trong `GITHUB_CONTROL_PLANE.md`.

## Model-promotion runtime identity

`iris-model-promoter` là App runtime thứ tư, tách khỏi ba App quản trị control plane. Chỉ Dispatch
Pod chạy dispatcher image do DevOps sở hữu nhận identity này để phát release intent; training image
không còn chứa dispatcher code hay nhận key. Workflow nằm trong `iris-gitops` dùng cùng App để tạo
branch/PR trong chính repo đó. App không có Kubernetes write, AWS administration hoặc quyền
ruleset. Terraform tạo duy nhất Secrets Manager container
`<project>-<environment>/github-app/model-promoter` và policy đọc cho External Secrets, nhưng không
tạo `aws_secretsmanager_secret_version`.

Giá trị JSON `{client_id, private_key}` được seed/rotate trực tiếp bằng
`scripts/seed-model-promoter-secret.sh`. External Secrets materialize thành Secret
`argo/model-promotion-github-app`. GitOps Actions đọc cùng giá trị bằng OIDC role chỉ có
`GetSecretValue/DescribeSecret`. Branch protection vẫn yêu cầu GitOps validation và CODEOWNER
review; reviewer là chủ thể merge production PR.
