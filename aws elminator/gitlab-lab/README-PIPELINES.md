# GitLab CI/CD + Terraform on Floci

A real two-team setup running entirely inside the lab VM:
**platform team** owns the infrastructure, **app team** owns the service, and pipelines deploy both to Floci (local AWS) with Terraform.

```
               ┌──────────────── Ubuntu VM (Docker, network: floci-net) ────────────────┐
 Windows       │                                                                          │
 browser ──────┼─► GitLab CE :8929 ──► GitLab Runner ──► job containers ──► Floci :4566  │
               │     (repos, pipelines,     (docker executor)   terraform / aws-cli /     │
               │      Terraform state)                          python                    │
               └──────────────────────────────────────────────────────────────────────────┘

 floci-infra pipeline                                floci-app pipeline
 fmt+validate → plan → ▶apply → verify → trigger ──► unit tests → package → deploy → integration tests
                         (manual gate)                                       (auto)   (real HTTP calls)
```

**What gets deployed** (an order service):

```
 POST /orders ─► API Gateway ─► Lambda ─┬─► DynamoDB  lab-orders
 GET /orders/{id}                       ├─► SNS lab-order-events ─┬─► SQS lab-billing  (+DLQ)
                                        │                         └─► SQS lab-shipping (+DLQ)
                                        └─► S3 lab-invoices/invoices/<id>.txt
      └── floci-app owns this ──┘  └──────────── floci-infra owns this (+ IAM role, SSM exports) ───┘
```

The app finds the infra through **SSM Parameter Store** (`/lab/infra/*`), not through shared Terraform state. This is a common pattern for decoupling teams.

---

## 1. Requirements
- Floci lab already running (`docker ps` shows `floci`)
- VM with **12 GB RAM** and 4 vCPU (GitLab alone needs about 4 GB)
- About 10 GB free disk space for the GitLab, Terraform, Python and Lambda images
- Internet access in the VM (to pull images and Terraform providers)

## 2. Set up (one command)
```bash
cd ~/"aws elminator"/gitlab-lab
chmod +x setup-gitlab.sh
./setup-gitlab.sh
```
It starts GitLab and the runner, creates an API token, registers the runner (docker executor on `floci-net`), creates the group **floci-lab** with two projects and pushes the code. The **first start takes 3–6 minutes**.

At the end it prints the URL and the root password (also saved in `gitlab-lab/.env`).

## 3. Run the pipelines
1. Open `http://<vm-ip>:8929` → log in as `root` → **floci-lab / floci-infra → Build → Pipelines**.
2. `fmt`, `validate` and `plan` run automatically. Open the **plan** job and read the plan (or download `plan.txt`).
3. Press **▶ apply**. This is the approval gate, the same as a production change.
4. `verify` checks that the resources exist and that an SNS event reaches both queues.
5. `trigger-app` starts **floci-app**'s pipeline: unit tests → package → **deploy** → **integration tests**.
6. Check the result:
   - GitLab: **Operate → Terraform states** (`infra`, `app`), **Operate → Environments**, test reports on the pipeline page.
   - Floci console `http://<vm-ip>:4500`: the table, bucket, topic, queues, Lambda and API.
   - Call the API yourself from the VM (the deploy job prints the URL):
     ```bash
     URL=http://localhost:4566/restapis/<api-id>/dev/_user_request_
     curl -s -X POST $URL/orders -d '{"customer":"Ahmed","item":"Router","amount":1500}'
     curl -s $URL/orders/<orderId>
     ```

## 4. Day-to-day workflow to practise
| Try this | What you learn |
|---|---|
| Edit `variables.tf` in floci-infra: add `"analytics"` to `consumer_queues`, commit to a **branch**, open an MR | Pipelines on branches run validate + plan only. Apply happens only on `main` |
| Merge the MR → apply | A third queue + DLQ + subscription appears, without touching the app |
| Break formatting in a `.tf` file | The `fmt` job fails before anything is deployed |
| Change the Lambda (e.g. add a `discount` field), push to floci-app | Unit tests → new zip → Terraform redeploys only the Lambda and the API deployment |
| Make a unit test fail | Deploy never runs |
| Run **destroy** in floci-app, then in floci-infra | Teardown order matters: the app depends on infra |
| `./reset.sh` (wipes Floci), then rerun pipelines | Terraform detects the drift and recreates everything |

## 5. Key files
| Path | Purpose |
|---|---|
| `docker-compose.yml` | GitLab CE (lab-tuned memory) + GitLab Runner on `floci-net` |
| `setup-gitlab.sh` | One-shot bootstrap (re-runnable) |
| `projects/floci-infra/*.tf` | S3, DynamoDB, SNS → SQS (+DLQ), IAM role, SSM exports |
| `projects/floci-infra/.gitlab-ci.yml` | validate → plan → manual apply → verify → trigger → destroy |
| `projects/floci-app/src/handler.py` | Order Lambda (create/get, DynamoDB + SNS + S3) |
| `projects/floci-app/tests/unit` | Fast tests with fake AWS clients |
| `projects/floci-app/tests/integration` | Real HTTP calls against the deployed API, checks every side effect |
| `projects/floci-app/terraform/*.tf` | Lambda + API Gateway REST + permissions |
| `projects/floci-app/.gitlab-ci.yml` | test → package → deploy → integration → destroy |

## 6. How it connects (important details)
- **Jobs reach Floci at `http://floci:4566`** because the runner starts job containers on `floci-net`.
- **The Terraform AWS provider** is the real `hashicorp/aws` with `endpoints { … = var.floci_endpoint }`. To target real AWS, remove the endpoints block and the dummy keys.
- **Terraform state** is stored in GitLab's HTTP backend with locking, using the job token. Nothing is stored in the repo.
- **The Lambda calls Floci** through `APP_AWS_ENDPOINT` (set by Terraform). On real AWS, leave it unset.
- **The Floci API Gateway URL format** is `http://floci:4566/restapis/<api-id>/<stage>/_user_request_/<path>`.

## 7. Troubleshooting
| Symptom | Fix |
|---|---|
| Jobs stuck in *pending* | `docker logs gitlab-runner`; check *Admin → CI/CD → Runners* shows it online |
| `terraform init` fails on state | GitLab URL must be reachable from jobs: VM IP in `gitlab-lab/.env` must be current. If the IP changed, edit `.env` and run `docker compose up -d` |
| `couldn't find resource` for SSM in app deploy | Infra not applied yet: run floci-infra's apply first |
| Lambda invoke times out | First run pulls the Python runtime image. Rerun the job |
| Lambda can't reach DynamoDB/SNS | Floci compose must have `FLOCI_SERVICES_DOCKER_NETWORK: floci-net` |
| VM slows down | Give it 12 GB+, or `docker compose stop` in `gitlab-lab` when not practising |

## 8. Stop / remove
```bash
cd ~/"aws elminator"/gitlab-lab
docker compose stop          # pause GitLab (keeps repos, pipelines, state)
docker compose down -v       # remove GitLab completely (deletes all GitLab data)
```
