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
