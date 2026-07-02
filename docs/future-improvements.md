# Future Improvement Proposals

## 1. Secret Management: External Secrets Operator + AWS Secrets Manager
- **What:** Replace manually-created Kubernetes Secrets with the External Secrets Operator syncing from AWS Secrets Manager.
- **Why:** Manifests in Git currently only show an *example* secret shape; real secrets must never be templated by hand or risk drifting/being leaked.
- **How it helps:** Centralizes credential rotation, auditing (CloudTrail), and access control (IAM) in one place instead of scattering secrets across clusters.
- **Implementation:** Install the ESO Helm chart, define `SecretStore`/`ExternalSecret` CRs pointing at each Secrets Manager entry, and delete the static `backend-secret-example.yaml` from any real deployment path.
- **Risk reduced:** Credential leakage via Git, stale secrets after rotation, manual human error when copying passwords.

## 2. Image Vulnerability Scanning
- **What:** Enforce ECR "scan on push" (already enabled in Terraform) plus a CI gate using `trivy` or `grype` that fails the pipeline on critical/high CVEs.
- **Why:** Base images (node:20-alpine, nginx:alpine) get new CVEs over time; without scanning, vulnerable images can silently reach production.
- **How it helps:** Shifts security left, catching issues before deploy instead of after an incident.
- **Implementation:** Add a `trivy image` step in `deploy.yml` right after each `docker build`, failing the job on HIGH/CRITICAL findings.
- **Risk reduced:** Shipping known-exploitable container images.

## 3. Monitoring and Alerting
- **What:** Deploy CloudWatch Container Insights (or Prometheus + Grafana) plus Alertmanager rules for pod restarts, high latency, and node pressure.
- **Why:** Currently only health probes exist; there's no visibility into trends or automated paging.
- **How it helps:** Faster detection/response (MTTR) before customers notice an outage.
- **Implementation:** Terraform already creates the CloudWatch log group; add Container Insights add-on and CloudWatch alarms on error-rate/CPU/memory, wired to SNS → Slack/PagerDuty.
- **Risk reduced:** Silent failures and prolonged outages.

## 4. Rollback Strategy
- **What:** Adopt `kubectl rollout undo` automation triggered by failed post-deploy health checks, or progressive delivery (canary) with Argo Rollouts.
- **Why:** The current pipeline deploys directly with `kubectl set image`; a bad release currently requires manual intervention.
- **How it helps:** Reduces blast radius of a bad deploy and removes reliance on a human noticing quickly.
- **Implementation:** Add a post-deploy smoke test step; on failure, automatically `kubectl rollout undo`. Longer term, move to Argo Rollouts with automated analysis.
- **Risk reduced:** Extended downtime from bad releases.

## 5. Helm Chart
- **What:** Convert the raw `k8s/*.yaml` manifests into a parameterized Helm chart (or Kustomize overlays) per environment.
- **Why:** Copy-pasted YAML doesn't scale across dev/staging/production; image tags and replica counts are currently hardcoded/manual.
- **How it helps:** One templated source of truth, environment-specific `values-{env}.yaml` files, easier rollbacks via `helm rollback`.
- **Implementation:** `helm create backend`, migrate existing manifests into templates, wire CI to `helm upgrade --install`.
- **Risk reduced:** Configuration drift between environments.

## 6. Private EKS Cluster
- **What:** Set `endpoint_public_access = false` on the EKS cluster and access it only via a bastion host, VPN, or AWS Client VPN.
- **Why:** The current cluster has a public API endpoint (restricted by IAM but still internet-reachable).
- **How it helps:** Removes an entire attack surface for the Kubernetes API.
- **Implementation:** Update the `eks` Terraform module's `vpc_config` block and provision a bastion/VPN in the public subnet for admin access.
- **Risk reduced:** Exposure of the Kubernetes control plane to the internet.

## 7. Web Application Firewall (WAF)
- **What:** Attach AWS WAF to the ALB created by the Ingress.
- **Why:** The frontend/API is public-facing behind the ALB with no request filtering today.
- **How it helps:** Blocks common attack patterns (SQLi, XSS, bot traffic, rate-limit abuse) before they reach the pods.
- **Implementation:** Create an `aws_wafv2_web_acl` in Terraform and associate it with the ALB via `alb.ingress.kubernetes.io/wafv2-acl-arn` annotation.
- **Risk reduced:** Application-layer attacks and abusive traffic.

## 8. Terraform Remote Backend Hardening
- **What:** The S3 backend (already configured) should additionally enable S3 bucket versioning, block public access, and use a customer-managed KMS key for state encryption.
- **Why:** State files can contain sensitive data (endpoints, ARNs, sometimes secrets if misused); losing state or leaking it is a real risk.
- **How it helps:** Enables state recovery from accidental deletion and prevents accidental public exposure.
- **Implementation:** Add `aws_s3_bucket_versioning`, `aws_s3_bucket_public_access_block`, and a KMS key resource, referenced in `provider.tf`'s backend block.
- **Risk reduced:** Permanent state loss, state leakage.

## 9. GitOps with Argo CD
- **What:** Replace the `kubectl apply`/`kubectl set image` deploy step with Argo CD watching the `k8s/` (or Helm chart) directory.
- **Why:** Current CI has push-based, one-way deploys with no continuous drift detection.
- **How it helps:** Git becomes the single source of truth; any manual cluster change is detected and can be auto-reconciled or flagged; easy visual rollback via the Argo CD UI.
- **Implementation:** Install Argo CD in-cluster, create an `Application` CR pointing at this repo's `k8s/` path, and change CI to only build/push images + bump the image tag in Git (Argo CD handles the actual apply).
- **Risk reduced:** Configuration drift, untracked manual `kubectl` changes, unclear deployment history.
