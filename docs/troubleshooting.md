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

## 7. Pod is in CrashLoopBackOff. What do you check?
- `kubectl logs <pod> --previous` — see why the *last* attempt crashed (the current one may not have logged anything yet).
- `kubectl describe pod <pod>` — check the `Events` section for OOMKilled, failed probes, or image pull errors.
- Confirm the container's entrypoint/CMD actually runs correctly (test the image locally with `docker run`).
- Check if a liveness probe is too aggressive (short `initialDelaySeconds`) and killing the app before it finishes starting up.
- Check resource limits — an undersized memory limit causes OOMKill loops.
- Check required env vars/ConfigMap/Secret keys are all present; a missing one can crash the app on startup.

## 8. Deployment is successful, but app is not reachable. What do you check?
- `kubectl get pods` — are the pods actually `Running` and `Ready`, not just deployed?
- `kubectl get svc` — does the Service selector match the pod labels? A mismatched label is the most common cause.
- `kubectl get endpoints <service-name>` — if empty, the Service has no pods behind it despite pods running.
- Confirm the container port in the Deployment matches the `targetPort` in the Service.
- Test directly with `kubectl port-forward` to rule out Ingress/ALB routing issues.
- Check Ingress rules and that the ALB/Load Balancer Controller actually provisioned (`kubectl describe ingress`).
- Check security groups/NACLs aren't blocking traffic at the network layer.

## 9. Difference between readiness and liveness probe?
- **Readiness probe** answers "can this pod accept traffic right now?" If it fails, Kubernetes removes the pod from the Service's endpoints (stops routing traffic to it) but does **not** restart it. Used for temporary states like startup warm-up or being busy.
- **Liveness probe** answers "is this pod alive and functioning, or permanently stuck?" If it fails repeatedly (past `failureThreshold`), Kubernetes **kills and restarts** the container. Used to recover from deadlocks or unrecoverable hangs.
- In short: readiness controls traffic; liveness controls restarts. A pod can be "not ready" without being "not alive" (e.g., still loading a large config file).

## 10. Docker build works locally but fails in pipeline. Why?
- **Different base image cache state** — CI runners always start with a clean cache; a local build may be silently using stale cached layers that mask a broken step.
- **Missing files due to `.dockerignore` or `.gitignore`** — a file present locally but never committed to Git won't exist in the CI checkout.
- **Platform/architecture mismatch** — local machine (e.g., Apple Silicon/ARM) builds a different architecture than the CI runner (usually x86_64/amd64), causing package or binary incompatibilities.
- **Environment differences** — local Docker Desktop may have more resources (CPU/RAM/disk) allocated than the CI runner, causing timeouts or OOM during build steps like `npm install`.
- **Secrets/credentials** — a local `.npmrc` or registry login may exist on your machine but not in CI, causing private package fetches to fail.

## 11. Pipeline fails during Docker build. What do you check?
- Read the exact failing step/line in the CI logs — Docker build output shows precisely which instruction failed.
- Reproduce locally with `docker build --no-cache` to rule out local cache masking the same issue.
- Check network access from the CI runner — package registries (npm, apt, alpine) may be blocked or rate-limited.
- Check disk space on the runner (`df -h` in a debug step) — large multi-stage builds can exhaust ephemeral runner storage.
- Confirm build context size — an accidentally huge build context (e.g., `.git`, `node_modules` not excluded via `.dockerignore`) can slow or fail the build.
- Check for version pinning issues — an unpinned base image tag (`:latest`) may have changed since the last successful build.

## 12. Certificate renewal failed. What do you check?
- Check the certificate's expiry and issuance status: `kubectl describe certificate <name>` (if using cert-manager) or `aws acm describe-certificate` (if using ACM).
- For cert-manager: check the `Order` and `Challenge` resources for DNS-01/HTTP-01 validation failures — often a DNS record wasn't created or propagated in time.
- For ACM: confirm the DNS validation CNAME record still exists in Route 53 and hasn't been deleted or modified.
- Check rate limits — Let's Encrypt enforces strict issuance rate limits; repeated failed attempts can trigger a temporary block.
- Check the domain's DNS still points to the expected validation target and hasn't changed registrars/nameservers.
- Confirm the service/ingress referencing the certificate has correct permissions (IAM role, cert-manager ClusterIssuer credentials).

## 13. Ingress returns 502 or 504. What do you check?
- **502 (Bad Gateway)** usually means the backend pod is reachable but returned an invalid/empty response, or crashed mid-request — check `kubectl logs` on the target pod.
- **504 (Gateway Timeout)** usually means the backend didn't respond in time — check if the pod is overloaded, slow-starting, or stuck (check CPU/memory usage, readiness probe status).
- Confirm the target Service has healthy endpoints: `kubectl get endpoints <service>`.
- Check ALB/Ingress Controller target group health checks — if the health check path/port doesn't match the container's actual listening port, the ALB marks targets unhealthy and returns 502/504.
- Check timeout settings — the ALB's idle timeout may be shorter than how long the backend actually takes to respond.
- Check security groups between the ALB and the worker nodes allow traffic on the NodePort/target port.

## 14. Vendor SFTP connection to port 22 times out. What do you check?
- Confirm the destination security group actually allows inbound TCP 22 from the vendor's specific IP/CIDR — not just "is a rule present" but "is it scoped to the right source."
- Check the route table for the subnet the SFTP server lives in — confirm there's a valid route out (via IGW if public-facing, or via NAT/VPN if the vendor connects through a private link).
- Check Network ACLs (NACLs) — unlike security groups, NACLs are stateless, so both inbound AND outbound rules for port 22 (and ephemeral return ports 1024-65535) must be allowed.
- Confirm the SFTP service is actually running and listening on port 22 on the host (`sudo ss -tlnp | grep :22`).
- Check if the vendor's IP has changed (dynamic IP) and the security group rule is now stale.
- Test connectivity independently: `telnet <host> 22` or `nc -zv <host> 22` from a machine in the same network path to isolate whether it's a network-layer or application-layer issue.

## 15. Terraform plan wants to recreate the cluster. What do you check?
- Run `terraform plan` and carefully read exactly which argument triggered the diff — look for `# forces replacement` next to the specific attribute, not just the resource name.
- Common causes: changing an immutable field like `vpc_config.subnet_ids`, changing the cluster `name`, or a provider version bump that changed how an attribute is interpreted.
- Check if the Terraform AWS provider was upgraded recently — provider changelogs sometimes document new "forces replacement" behavior on previously mutable-seeming fields.
- Cross-check current live infrastructure state with `terraform state show <resource>` to see if someone made a manual change in the AWS Console that now conflicts with the Terraform config (drift).
- If the recreate is unintended, consider using a `moved` block or `terraform state mv`/`import` to reconcile state without actually destroying the resource.
- If the recreate is intentional and unavoidable, plan a blue/green cutover (create new cluster alongside the old one, migrate workloads, then decommission the old one) rather than accepting an in-place destroy/recreate that causes downtime.
