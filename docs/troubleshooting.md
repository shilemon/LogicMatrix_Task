# Troubleshooting Guide

## 1. How would you upgrade AKS/EKS safely?
1. Read the EKS release notes for the target version and check add-on/API deprecations (`kubectl get apiservices`, `pluto` or `kubent` to scan for removed APIs).
2. Upgrade the **control plane** one minor version at a time (EKS does not allow skipping versions) via `terraform apply` after bumping `kubernetes_version`, or `aws eks update-cluster-version`.
3. Wait for the control plane update to finish, then upgrade **add-ons** (CoreDNS, kube-proxy, VPC CNI) to versions compatible with the new control plane.
4. Upgrade **node groups** last, using a rolling/surge strategy (`update_config.max_unavailable`) or by creating a new node group on the new version and cordon/draining the old one (blue/green nodes) so workloads shift without downtime.
5. Validate with smoke tests and `kubectl get nodes`, `kubectl get pods -A` before decommissioning old nodes.
6. Always test the upgrade in dev/staging first, and keep a recent etcd/cluster backup or an IaC-based rebuild path.

## 2. Frontend loads, but backend API calls fail. What do you check?
- Browser dev tools: is the request going to the right URL (`/api/...`) and what's the HTTP status/CORS error?
- `kubectl get pods -l app=backend` — are backend pods `Running` and `Ready` (probes passing)?
- `kubectl logs deploy/backend` for stack traces or crash loops.
- `kubectl get svc backend` — confirm the Service selector matches pod labels and the port (8080) is correct.
- Ingress/ALB routing rules — confirm the `/api` path rule points at the `backend` service and port.
- Network policies or security groups blocking pod-to-pod traffic.
- If it works via `kubectl port-forward svc/backend 8080:8080` but not through the ingress, the problem is in the ingress/ALB layer, not the app.

## 3. Backend pod is running, but database connection times out. What do you check?
- Confirm the backend pod is in the same VPC/subnet group that has a route to the DB subnets (route tables, NAT not required for private-to-private traffic).
- Check the RDS security group: does it allow inbound 5432 from the EKS node/cluster security group specifically?
- Check the DB is actually `available` in the AWS console/`aws rds describe-db-instances`.
- Exec into the pod and test raw connectivity: `kubectl exec -it <pod> -- nc -zv <db-host> 5432` (or `pg_isready`).
- Confirm `DB_HOST` in the ConfigMap matches the real RDS endpoint and hasn't gone stale after a DB replacement.
- Check for an overly restrictive NACL on the private subnets.

## 4. Private DNS is not resolving database hostname. What do you check?
- Confirm the VPC has `enableDnsSupport` and `enableDnsHostnames` set to true.
- If using a custom Route 53 private hosted zone, confirm it's associated with the correct VPC.
- `kubectl exec -it <pod> -- nslookup <db-host>` from inside the pod to see exactly what resolver/response is returned.
- Confirm CoreDNS is healthy (`kubectl get pods -n kube-system -l k8s-app=kube-dns`) and its `forward` config isn't blocking resolution of the RDS domain.
- For RDS, the endpoint is normally public DNS that resolves to a private IP when queried from inside the VPC — confirm you're querying from a pod actually inside the cluster's VPC, not a local machine.

## 5. How would you rotate database credentials safely?
1. Generate a new password and store it as a new version in AWS Secrets Manager (never edit in place blindly).
2. If using RDS-managed rotation, enable automatic rotation with a Lambda rotation function; otherwise rotate manually: update the DB user's password via `ALTER USER ... PASSWORD`, then update the secret.
3. The External Secrets Operator (or CSI driver) picks up the new secret value and updates the Kubernetes Secret automatically (or triggers a sync).
4. Roll the backend deployment (`kubectl rollout restart deployment/backend`) so pods pick up the new secret via a fresh env/mount.
5. Verify connectivity with the new credentials before considering the old password fully retired; keep the old password valid briefly to avoid a hard cutover outage if rotation supports dual-password overlap.

## 6. Secrets were accidentally committed to GitHub. What do you do?
1. **Rotate the secret immediately** — assume it's compromised the moment it hits Git, regardless of whether the repo is public or private.
2. Revoke/replace the credential at the source (RDS password, cloud access key, API token) in AWS Secrets Manager / IAM.
3. Remove it from Git history (not just the latest commit) using `git filter-repo` or BFG Repo-Cleaner, then force-push and have collaborators re-clone.
4. Audit access/CloudTrail logs for any unauthorized use during the exposure window.
5. Add the pattern to `.gitignore` and set up a pre-commit secret scanner (e.g. `gitleaks`, `trufflehog`) plus a GitHub push-protection/secret-scanning rule to prevent recurrence.
6. Document the incident and the remediation steps taken.
