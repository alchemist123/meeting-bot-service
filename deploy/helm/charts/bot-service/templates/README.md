# bot-service chart · templates

Kubernetes manifests rendered by the `bot-service` Helm chart — one `deployment-*.yaml` per service
(gateway, admin-api, meeting-api, runtime, redis, minio, postgres) plus supporting resources
(RBAC for the runtime's k8s spawn backend, the shared Secret, PDBs, the minio-init Job, ingress).
Values come from the chart `values.yaml`.
