# AWS Emulator Lab (Floci)

Run a local AWS cloud on your own machine, with no AWS account, no cost and no internet calls to AWS. You can use it to develop, test CI/CD pipelines, try Terraform or CloudFormation, and learn AWS services safely.

> **Status:** verified end-to-end. **29 of 29 core AWS services passed** on an Ubuntu Server VM. The web console works.

---

## 1. Why Floci?

| | LocalStack (latest) | **Floci** |
|---|---|---|
| Account / auth token | Required since March 2026 | **Not needed** |
| License | Proprietary tiers | **MIT, free** |
| Port | 4566 | **4566** (drop-in replacement) |
| Works with AWS CLI / SDKs / Terraform / CDK | Yes | **Yes**: point them at `http://<host>:4566` |
| Web console | Paid | **Included** (port 4500) |
| Container-backed services (Lambda, RDS, EKS, …) | Yes | **Yes**, using real Docker containers |

Since March 2026 the `localstack/localstack:latest` image needs an account and a `LOCALSTACK_AUTH_TOKEN`, which breaks CI pipelines and requires a token for every developer. Floci is a free, open-source replacement that listens on the same port.

Project: https://github.com/floci-io/floci · Docs: https://floci.io

---

## 2. Architecture

```
 Windows host (browser, AWS CLI, VS Code, Terraform)
        │  http://<vm-ip>:4566  (AWS APIs)
        │  http://<vm-ip>:4500  (web console)
        ▼
 VMware Workstation ── Ubuntu Server VM
        └── Docker Engine
              ├── floci          :4566   all AWS APIs
              ├── floci-aws-ui   :4500   web console
              └── on-demand containers: Lambda runtimes, RDS Postgres,
                  ElastiCache Redis, OpenSearch, EKS, ECS tasks, EC2 …
```

We use a Linux VM instead of Docker Desktop on Windows because:
- Container-backed services such as Lambda and RDS use the native Docker socket with no Docker Desktop quirks.
- It matches how we run things on our Linux servers.
- The VM disk can live on any drive, which keeps the Windows system drive free.

---

## 3. Folder contents

| File | Purpose |
|---|---|
| `docker-compose.yml` | Runs Floci on port 4566 with the Docker socket mounted so it can start Lambda, RDS and other containers |
| `setup-vm.sh` | One-shot VM prep: installs Docker (if missing), AWS CLI v2, starts Floci, prints the endpoints |
| `test-all.sh` | Linux smoke test covering about 35 AWS services; writes `results.csv` |
| `test-all.ps1` | Same test for Windows PowerShell (when running against Docker Desktop or the VM from Windows) |
| `aws-config` | Isolated AWS CLI config used by the tests, so your real `~/.aws` is **never** touched |
| `lambda/handler.py` | Sample Python Lambda used by the Lambda test |

---

## 4. Build the VM (VMware Workstation)

1. **Download** the Ubuntu Server LTS ISO from https://ubuntu.com/download/server. We tested on 24.04; 26.04 LTS is the latest release.
2. **Create the VM:**
   - 4 vCPU, **8 GB RAM** (6 GB minimum), **60 GB disk**
   - Store the VM files on a drive with plenty of space
   - Network: **NAT** (default). The host reaches the VM on the VMnet8 address, for example `192.168.184.x`
3. **Install Ubuntu:** tick **Install OpenSSH server**, then connect with MobaXterm or any SSH client.
4. **Copy this folder** into the VM, for example with MobaXterm's SFTP panel, to `~/aws elminator`.

---

## 5. Install and start

```bash
cd ~/"aws elminator"
chmod +x *.sh
./setup-vm.sh
```

`setup-vm.sh` installs prerequisites, runs `docker compose up -d`, waits for Floci and prints:

```
From this VM:      export AWS_ENDPOINT_URL=http://localhost:4566 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
From Windows host: http://<vm-ip>:4566   (console: http://<vm-ip>:4500)
```

> If Docker was just installed, log out and back in (or run `newgrp docker`) and run `setup-vm.sh` again.

Check that it's running:
```bash
docker ps
# floci          Up (healthy)  0.0.0.0:4566->4566/tcp
# floci-aws-ui   Up            0.0.0.0:4500->4500/tcp
```

---

## 6. Test every service

```bash
./test-all.sh                   # core services (~2–3 min; first Lambda run pulls an image)
./test-all.sh --heavy           # + RDS, ElastiCache, OpenSearch, EKS, ECS run-task, EC2 instance
./test-all.sh --only s3,lambda  # specific services
./test-all.sh --endpoint http://<vm-ip>:4566   # test a remote Floci
```

From Windows PowerShell against the VM:
```powershell
powershell -ExecutionPolicy Bypass -File .\test-all.ps1 -Endpoint http://<vm-ip>:4566
```

Each service prints **PASS**, **FAIL** or **SKIP**. The results are saved to `results.csv`.

### What gets tested

| Area | Services | What the test proves |
|---|---|---|
| Core | STS, IAM | Caller identity; role + policy + user + access key |
| Storage / data | S3 | Upload/download, versioning, tagging, **presigned URL** |
| | DynamoDB | Create table, put/update/get item (atomic counter) |
| | KMS | Key + alias, encrypt → decrypt round-trip |
| | Secrets Manager, SSM | Secret versions; String + SecureString parameters |
| | Glue, Athena | Data catalog database; work groups |
| Messaging / events | SQS | Standard send/receive + FIFO queue |
| | SNS | Topic → SQS **fan-out delivered** |
| | EventBridge | Custom bus + rule → SQS **routed** |
| | Scheduler, Kinesis, Firehose | Schedule; stream put/get records; delivery stream → S3 |
| Compute | **Lambda** | Python 3.12 function **actually invoked** in a container + function URL |
| | **Step Functions** | State machine Pass → Wait → Succeed **executed** |
| | ECR, ECS, EC2 | Repository; cluster + task definition; VPC, subnet, SG, IGW, key pair |
| | CloudFormation | Stack with S3 + SQS + SSM → CREATE_COMPLETE |
| API / auth / network | API Gateway (REST + HTTP) | REST API with `/health` deployed; HTTP API + stage |
| | Cognito | User pool, **real login returns a JWT** |
| | Route 53, ACM, SES | Hosted zone + record; certificate; email sent |
| Observability | CloudWatch Logs, Metrics | Log events + filter; metric + alarm |
| Heavy (`--heavy`) | RDS, ElastiCache, OpenSearch, EKS, ECS run-task, EC2 instance | Real Postgres / Redis / OpenSearch / Kubernetes / containers |

### Verified result (Ubuntu VM, AWS CLI 2.41)

```
PASS 29   FAIL 0   SKIP 6   (SKIP = heavy services, run with --heavy)
```
The first Lambda invocation takes about 2.5 minutes because it pulls the Python runtime image. Later invocations take seconds.

---

## 7. Web console (GUI)

Open from Windows: **http://\<vm-ip\>:4500**

You can browse and manage resources (S3 buckets and objects, queues, tables, Lambda functions, state machines, stacks, Cognito pools, logs and more) much like the AWS console.

If port 4500 isn't up, open **http://\<vm-ip\>:4566** and click **Open Floci UI**, which starts the `floci-aws-ui` container.

---

## 8. Using it day to day

### AWS CLI
```bash
export AWS_ENDPOINT_URL=http://localhost:4566     # or http://<vm-ip>:4566 from Windows
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
aws s3 ls
aws --endpoint-url $AWS_ENDPOINT_URL sqs list-queues   # SQS: pass --endpoint-url explicitly
```
PowerShell:
```powershell
$env:AWS_ENDPOINT_URL="http://<vm-ip>:4566"; $env:AWS_ACCESS_KEY_ID="test"; $env:AWS_SECRET_ACCESS_KEY="test"; $env:AWS_DEFAULT_REGION="us-east-1"
```

### SDKs (Python, .NET, Java, Node)
Set `AWS_ENDPOINT_URL=http://<host>:4566` with any dummy credentials. No code changes are needed.

### Terraform
```hcl
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true
  endpoints {
    s3 = "http://<host>:4566"   # repeat for each service you use: sqs, dynamodb, lambda, iam, ...
  }
}
```

### CI/CD (GitLab example)
```yaml
integration-test:
  services:
    - name: floci/floci:latest
      alias: floci
  variables:
    AWS_ENDPOINT_URL: http://floci:4566
    AWS_ACCESS_KEY_ID: test
    AWS_SECRET_ACCESS_KEY: test
    AWS_DEFAULT_REGION: us-east-1
  script:
    - ./test-all.sh --endpoint http://floci:4566
```

### Air-gapped / offline environments
Pull the images on a connected machine, `docker save` them, and `docker load` them on the target:
`floci/floci`, `floci/floci-ui`, plus any runtimes you use (for example the Lambda Python image, `postgres`, `redis`, `nginx:alpine`, `busybox`).

---

## 9. Operations

| Task | Command |
|---|---|
| Start / stop | `docker compose up -d` / `docker compose down` |
| Reset all resources | `docker compose down && docker compose up -d` (state is wiped on restart) |
| Logs | `docker logs -f floci` |
| Verbose logs | uncomment `QUARKUS_LOG_LEVEL: DEBUG` in `docker-compose.yml` |
| Update Floci | `docker compose pull && docker compose up -d` |

---

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| Can't reach `http://<vm-ip>:4566` from Windows | `curl -I http://localhost:4566` inside the VM; check `sudo ufw status` (`sudo ufw allow 4566,4500/tcp`) |
| VM IP changed after reboot | Give the VM a static IP (netplan) or a DHCP reservation in VMware's NAT settings |
| Lambda test slow or timing out | First run pulls the runtime image; check `docker images` and VM internet access |
| `permission denied` on docker.sock | `sudo usermod -aG docker $USER` and log in again |
| Heavy tests fail | Give the VM more RAM/CPU (8 GB / 4 vCPU or more) and free disk space |
| `aws` tries real AWS | Make sure `AWS_ENDPOINT_URL` is set, or pass `--endpoint-url` |

---

## 11. Limitations

- It's an **emulator**, so behavior is close to AWS but not identical. IAM permissions are not enforced by default, and there are no real latency, quotas or billing. Always run a final validation on real AWS before production.
- Floci is a young project (2026). Check its release notes when you update.
- Never put real AWS credentials in this lab. The dummy `test`/`test` credentials are all you need.
