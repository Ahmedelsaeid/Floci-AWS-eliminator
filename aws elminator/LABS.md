# Floci GUI Labs: hands-on AWS practice

Console: `http://<vm-ip>:4500` · Clean slate anytime: `./reset.sh`

Each lab lists a **goal**, the **steps**, a **checkpoint** (what you should see when it works) and an optional **challenge**.
Labs build on each other, so keep what you create. In the CLI phase you'll find and change the same resources from the terminal.

> If a button is missing or an action fails in the console, note it down. The console is newer than the emulator, so some actions only work from the CLI. That's fine, and we'll do them there.

Naming convention for everything you create: `prac-<thing>` (e.g. `prac-bucket`), so it's easy to tell your resources from the defaults.

---

## Level 1: Foundations

### Lab 1: S3 basics
**Goal:** understand buckets, objects, keys and "folders".
1. **Storage** → create bucket `prac-bucket`.
2. Upload 3 files: a `.txt`, an image and a `.pdf`.
3. Create folder `reports/` and upload a file into it.
4. Open an object and note its **size, content type, ETag and last modified**.
5. Download one object and open it on Windows.

**Checkpoint:** Storage = 1 bucket. The object list shows `reports/` as a prefix.
**Challenge:** try to delete the bucket while it still has files in it. What happens? Why does AWS behave this way?
**Concept:** S3 has no real folders. `reports/file.txt` is a single key, and the console just groups by `/`.

### Lab 2: S3 versioning and protection
**Goal:** recover from an accidental overwrite or delete.
1. In `prac-bucket` → bucket properties → **enable Versioning**.
2. Upload `notes.txt` (content: `v1`), then upload a new `notes.txt` (content: `v2`) with the same name.
3. Show object versions and confirm both exist.
4. Delete `notes.txt` and look at the versions again. Notice the **delete marker**.
5. Restore `v1`, either by downloading that version or by deleting the delete marker.

**Checkpoint:** you can get back a file you "deleted".
**Challenge:** add tags `env=dev` and `owner=ahmed` to an object.

### Lab 3: Explore the default network
**Goal:** read an AWS network before building one.
1. **Networking** (and **Compute**) → find the **default VPC**.
2. Write down its CIDR, its subnets (one per availability zone), the route table, the internet gateway and the default security group.
3. Open the route table: which route sends traffic to the internet?

**Checkpoint:** you can explain why the 31 Compute resources existed after the reset.
**Concept:** every AWS region starts with this default VPC.

---

## Level 2: Data and identity

### Lab 4: DynamoDB table design
**Goal:** NoSQL keys and a flexible schema.
1. **DynamoDB** → create table `prac-employees`, partition key `id` (String).
2. Add 4 items, each with `name`, `team` and `role`, e.g. `team = MISOPS`.
3. Give **one** item an extra attribute (`skills`, a list) and notice that the others don't need it.
4. Edit an item, then delete one.
5. Run a **scan**, then a **query** by `id`.

**Checkpoint:** 3 items left. Query returns exactly one.
**Challenge:** create `prac-orders` with partition key `customerId` and sort key `orderDate`. Add several orders for the same customer and query them in date order.

### Lab 5: IAM users, roles and policies
**Goal:** the identity model.
1. **IAM** (Security section of the sidebar) → create user `prac-dev`.
2. Create policy `prac-s3-readonly` that allows `s3:GetObject` and `s3:ListBucket` on `prac-bucket`.
3. Attach the policy to the user and create an access key for them.
4. Create role `prac-lambda-role` that trusts `lambda.amazonaws.com`.

**Checkpoint:** user has 1 policy attached. Role shows its trust relationship.
**Note:** Floci doesn't enforce IAM by default, so you're practising the **structure**, not real access denial.

### Lab 6: Secrets and configuration
**Goal:** keep config and passwords out of code.
1. **Secrets Manager** → secret `prac/db-password` = `MyP@ss123`.
2. Change the value and look at the versions (AWSCURRENT / AWSPREVIOUS).
3. **SSM Parameter Store** → `/prac/app/db-host` = `db.local` (String) and `/prac/app/api-key` (SecureString).
4. **KMS** → create key with alias `alias/prac-key`.

**Checkpoint:** 1 secret with 2 versions, 2 parameters, 1 key.
**Concept:** when should you use Secrets Manager rather than Parameter Store?

---

## Level 3: Messaging and events

### Lab 7: SQS queues
1. Create standard queue `prac-orders-queue`.
2. **Send** 3 messages with different bodies, then **poll/receive** them.
3. Create `prac-orders-dlq` and set it as the **dead-letter queue** of `prac-orders-queue` (max receives = 3).
4. Create a FIFO queue `prac-payments.fifo`.

**Checkpoint:** messages appear and disappear after they're received and deleted.
**Concept:** visibility timeout. Why does a received message come back if you don't delete it?

### Lab 8: SNS fan-out
1. Create topic `prac-alerts`.
2. Subscribe **two** SQS queues to it: `prac-email-queue` and `prac-sms-queue`.
3. Publish one message to the topic.
4. Check both queues. The same message should be in each.

**Checkpoint:** 1 publish leads to 2 deliveries.
**Concept:** fan-out pattern = SNS → many SQS.

### Lab 9: EventBridge routing
1. Create event bus `prac-bus`.
2. Create rule `prac-new-order` with pattern `{"source": ["prac.shop"], "detail-type": ["OrderCreated"]}` and target `prac-orders-queue`.
3. Send a test event that matches, and one with a different `source`.
4. Check the queue: only the matching event should be there.

**Checkpoint:** the rule filters correctly.

---

## Level 4: Compute

### Lab 10: Lambda
1. **Serverless** → create function `prac-hello`, Python 3.12, role `prac-lambda-role`.
2. Code:
   ```python
   import os
   def handler(event, context):
       return {"msg": f"Hello {event.get('name','world')} from {os.environ.get('STAGE','?')}"}
   ```
3. Environment variable `STAGE=dev`. Test event `{"name": "Ahmed"}`. The first run is slow because it starts a container.
4. Change `STAGE` to `prod` and test again.
5. Look at the logs in **CloudWatch Logs** → `/aws/lambda/prac-hello`.

**Checkpoint:** response `Hello Ahmed from prod`. The log group exists.
**Challenge:** add an **SQS trigger** from `prac-orders-queue`, send a message and watch the Lambda logs.

### Lab 11: Build your own VPC
1. VPC `prac-vpc` `10.0.0.0/16`.
2. Subnets: `prac-public-a` `10.0.1.0/24` and `prac-private-a` `10.0.2.0/24`.
3. Create an internet gateway and attach it to `prac-vpc`.
4. Route table `prac-public-rt` with `0.0.0.0/0 → IGW`, associated with the **public** subnet only.
5. Security groups: `prac-web-sg` (allow 80/443 from anywhere) and `prac-ssh-sg` (allow 22 from `192.168.184.0/24` only).

**Checkpoint:** you can explain what makes the public subnet public.

### Lab 12: EC2 instances
1. Create key pair `prac-key`.
2. Launch instance `prac-web-1` in `prac-public-a` with `prac-web-sg` and `prac-ssh-sg`.
3. Watch its state: pending → running. Then **stop**, **start**, add tag `Name=prac-web-1`, and **terminate** it.

**Checkpoint:** you've gone through the whole instance lifecycle. (This starts a real container, so it's slower.)

### Lab 13: ECS containers
1. **ECS** → cluster `prac-cluster`.
2. Task definition `prac-nginx`: image `nginx:alpine`, memory 128, port 80.
3. **Run task** and watch it reach RUNNING.
4. Create a **service** with desired count 2 and watch two tasks start.

**Checkpoint:** 2 running tasks. Inside the VM, `docker ps` shows the nginx containers.

---

## Level 5: Databases and the edge (heavier: give the VM 8 GB RAM)

### Lab 14: RDS Postgres
1. **Database** → create `prac-db`, engine postgres, user `pracadmin`, password `PracPassw0rd`.
2. Wait until it's **available** (it starts a real Postgres container).
3. Note the endpoint and port, then connect from **DBeaver** on Windows using `<vm-ip>` and that port.
4. `CREATE TABLE test(id int); INSERT INTO test VALUES (1);`

**Checkpoint:** a real SQL connection works.

### Lab 15: API Gateway in front of Lambda
1. **API Gateway** → HTTP API `prac-api`.
2. Route `GET /hello` → integration: Lambda `prac-hello`.
3. Stage `$default` with auto-deploy.
4. Open the invoke URL in the browser.

**Checkpoint:** the browser shows the Lambda response.

---

## Capstone: "Order system" (no step-by-step)

Build this yourself using only the console:

```
 Browser ─► API Gateway (POST /orders) ─► Lambda prac-create-order
                                              ├─► DynamoDB prac-orders (save order)
                                              └─► SNS prac-order-events
                                                     ├─► SQS prac-billing-queue
                                                     └─► SQS prac-shipping-queue
 S3 prac-invoices  ◄── (bonus) Lambda writes an invoice .txt per order
 CloudWatch Logs  ◄── all Lambda logs
```

**Done when:** one request to the API gives you an item in DynamoDB, a message in **both** queues and (bonus) a file in S3.
Then draw it on paper. This is the same design you'd present for a real AWS project.

---

## Progress checklist
- [ ] 1 S3 basics  - [ ] 2 Versioning  - [ ] 3 Default network
- [ ] 4 DynamoDB  - [ ] 5 IAM  - [ ] 6 Secrets/Config
- [ ] 7 SQS  - [ ] 8 SNS fan-out  - [ ] 9 EventBridge
- [ ] 10 Lambda  - [ ] 11 VPC  - [ ] 12 EC2  - [ ] 13 ECS
- [ ] 14 RDS  - [ ] 15 API Gateway
- [ ] Capstone

**Next phase: CLI.** Every lab above will be redone with `aws` commands, starting from the resources you built here.
