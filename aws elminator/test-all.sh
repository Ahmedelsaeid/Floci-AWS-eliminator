#!/usr/bin/env bash
# Smoke-tests AWS services against a local Floci emulator.
#   ./test-all.sh                  # light services
#   ./test-all.sh --heavy          # + RDS, ElastiCache, OpenSearch, EKS, ECS run-task, EC2 instance
#   ./test-all.sh --only s3,lambda
#   ./test-all.sh --endpoint http://192.168.184.129:4566
set -u

ENDPOINT="http://localhost:4566"; HEAVY=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --heavy) HEAVY=1 ;;
    --only) ONLY=",$2,"; shift ;;
    --endpoint) ENDPOINT="$2"; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown arg $1"; exit 2 ;;
  esac; shift
done

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work"; mkdir -p "$WORK"

# Isolated AWS CLI settings: never touches your real ~/.aws
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
export AWS_CONFIG_FILE="$HERE/aws-config" AWS_SHARED_CREDENTIALS_FILE="$WORK/no-credentials" AWS_PAGER=""
unset AWS_PROFILE
export NO_PROXY="localhost,127.0.0.1,${NO_PROXY:-}" no_proxy="localhost,127.0.0.1,${no_proxy:-}"

SFX=$(date +%H%M%S)
RESULTS="$HERE/results.csv"; echo "service,status,seconds,detail" > "$RESULTS"
PASS=0; FAIL=0; SKIP=0
G='\033[32m'; R='\033[31m'; Y='\033[90m'; C='\033[36m'; N='\033[0m'

# aws wrapper: explicit endpoint (SQS ignores AWS_ENDPOINT_URL in some CLI versions), errors -> stderr + nonzero
aws_() {
  local out
  if ! out=$(aws --endpoint-url "$ENDPOINT" "$@" 2>&1); then
    echo "aws $* => $out" >&2; return 1
  fi
  printf '%s' "$out"
}
q() { aws_ "$@" --output text; }   # convenience: text output

wait_until() {  # wait_until <seconds> <what> <command...>  -> prints command output when it succeeds and is non-empty
  local secs=$1 what=$2; shift 2
  local end=$((SECONDS + secs)) out
  while [ $SECONDS -lt $end ]; do
    if out=$("$@" 2>/dev/null) && [ -n "$out" ] && [ "$out" != "None" ]; then printf '%s' "$out"; return 0; fi
    sleep 2
  done
  echo "timed out after ${secs}s waiting for $what" >&2; return 1
}

run() {  # run <name> <function> [heavy]
  local name=$1 fn=$2 heavy=${3:-0}
  if [ -n "$ONLY" ] && [[ "$ONLY" != *",$name,"* ]]; then return; fi
  if [ "$heavy" = 1 ] && [ $HEAVY = 0 ]; then
    printf "${Y}  SKIP  %-16s heavy - rerun with --heavy${N}\n" "$name"
    echo "$name,SKIP,0,heavy" >> "$RESULTS"; SKIP=$((SKIP+1)); return
  fi
  local t0=$SECONDS out err status
  err="$WORK/err.txt"; : > "$err"
  out=$( set -e; $fn 2>"$err" ); local rc=$?
  if [ $rc -eq 0 ]; then
    status=PASS; PASS=$((PASS+1)); printf "${G}"
  else
    status=FAIL; FAIL=$((FAIL+1)); out=$(tail -c 300 "$err" | tr '\n' ' '); printf "${R}"
  fi
  out=$(printf '%s' "$out" | tail -n1)
  printf "  %-5s %-16s %4ss  %s${N}\n" "$status" "$name" "$((SECONDS-t0))" "$out"
  echo "$name,$status,$((SECONDS-t0)),\"${out//\"/\'}\"" >> "$RESULTS"
}

# ---------------- pre-flight ----------------
command -v aws >/dev/null || { echo "aws CLI not found - run setup-vm.sh or install AWS CLI v2"; exit 1; }
echo -e "${C}Waiting for Floci at $ENDPOINT ...${N}"
wait_until 60 "Floci (docker compose up -d?)" q sts get-caller-identity --query Account >/dev/null || exit 1
ACCT=$(q sts get-caller-identity --query Account)
echo -e "${C}Floci is up. Account $ACCT, run suffix $SFX${N}\n"
ROLE_ARN="arn:aws:iam::${ACCT}:role/lab-role"; BUCKET=""; SUBNET=""

sqs_url_arn() {  # creates queue, sets QURL / QARN
  QURL=$(q sqs create-queue --queue-name "$1" --query QueueUrl)
  QARN=$(q sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn --query Attributes.QueueArn)
}
recv() { q sqs receive-message --queue-url "$1" --wait-time-seconds 2 --query 'Messages[0].Body'; }

# ================= CORE =================
t_sts() { echo "caller = $(q sts get-caller-identity --query Arn)"; }

t_iam() {
  cat > "$WORK/trust.json" <<'J'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["lambda.amazonaws.com","states.amazonaws.com","scheduler.amazonaws.com","firehose.amazonaws.com","eks.amazonaws.com"]},"Action":"sts:AssumeRole"}]}
J
  echo '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}' > "$WORK/policy.json"
  local role pol key n
  role=$(q iam create-role --role-name "lab-role-$SFX" --assume-role-policy-document "file://$WORK/trust.json" --query Role.Arn)
  pol=$(q iam create-policy --policy-name "lab-all-$SFX" --policy-document "file://$WORK/policy.json" --query Policy.Arn)
  aws_ iam attach-role-policy --role-name "lab-role-$SFX" --policy-arn "$pol" >/dev/null
  aws_ iam create-user --user-name "lab-user-$SFX" >/dev/null
  key=$(q iam create-access-key --user-name "lab-user-$SFX" --query AccessKey.AccessKeyId)
  n=$(q iam list-attached-role-policies --role-name "lab-role-$SFX" --query 'length(AttachedPolicies)')
  echo "$role" > "$WORK/role_arn"
  echo "role+policy ($n attached), user+access key $key"
}

# ================= STORAGE & DATA =================
t_s3() {
  local b="lab-bucket-$SFX" url code
  aws_ s3 mb "s3://$b" >/dev/null
  echo "hello from floci" > "$WORK/hello.txt"
  aws_ s3 cp "$WORK/hello.txt" "s3://$b/folder/hello.txt" >/dev/null
  aws_ s3api put-bucket-versioning --bucket "$b" --versioning-configuration Status=Enabled >/dev/null
  aws_ s3api put-object-tagging --bucket "$b" --key folder/hello.txt --tagging 'TagSet=[{Key=env,Value=lab}]' >/dev/null
  aws_ s3 cp "s3://$b/folder/hello.txt" "$WORK/hello-back.txt" >/dev/null
  [ "$(cat "$WORK/hello-back.txt")" = "hello from floci" ] || { echo "content mismatch" >&2; return 1; }
  url=$(aws_ s3 presign "s3://$b/folder/hello.txt" --expires-in 300)
  code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' "$url")
  echo "$b" > "$WORK/bucket"
  echo "upload/download/versioning/tagging ok, presigned GET -> HTTP $code"
}

t_dynamodb() {
  local t="lab-table-$SFX" v
  aws_ dynamodb create-table --table-name "$t" --attribute-definitions AttributeName=pk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null
  wait_until 30 "table ACTIVE" bash -c "[ \"\$(aws --endpoint-url $ENDPOINT dynamodb describe-table --table-name $t --query Table.TableStatus --output text)\" = ACTIVE ] && echo ok" >/dev/null
  aws_ dynamodb put-item --table-name "$t" --item '{"pk":{"S":"user#1"},"name":{"S":"floci"},"visits":{"N":"1"}}' >/dev/null
  aws_ dynamodb update-item --table-name "$t" --key '{"pk":{"S":"user#1"}}' \
    --update-expression "SET visits = visits + :one" --expression-attribute-values '{":one":{"N":"1"}}' >/dev/null
  v=$(q dynamodb get-item --table-name "$t" --key '{"pk":{"S":"user#1"}}' --query Item.visits.N)
  [ "$v" = 2 ] || { echo "expected visits=2, got $v" >&2; return 1; }
  echo "create/put/update/get ok (visits=$v)"
}

t_kms() {
  local id ct pt
  id=$(q kms create-key --description "lab key" --query KeyMetadata.KeyId)
  aws_ kms create-alias --alias-name "alias/lab-$SFX" --target-key-id "$id" >/dev/null
  printf 'top-secret' > "$WORK/plain.txt"
  ct=$(q kms encrypt --key-id "alias/lab-$SFX" --plaintext "fileb://$WORK/plain.txt" --query CiphertextBlob)
  echo "$ct" | base64 -d > "$WORK/cipher.bin"
  pt=$(q kms decrypt --ciphertext-blob "fileb://$WORK/cipher.bin" --query Plaintext | base64 -d)
  [ "$pt" = top-secret ] || { echo "decrypt mismatch: $pt" >&2; return 1; }
  echo "key+alias, encrypt/decrypt round-trip ok"
}

t_secretsmanager() {
  local n="lab/db-password-$SFX" v
  aws_ secretsmanager create-secret --name "$n" --secret-string s3cr3t >/dev/null
  aws_ secretsmanager put-secret-value --secret-id "$n" --secret-string s3cr3t-v2 >/dev/null
  v=$(q secretsmanager get-secret-value --secret-id "$n" --query SecretString)
  [ "$v" = s3cr3t-v2 ] || { echo "got $v" >&2; return 1; }
  echo "create/new version/get ok"
}

t_ssm() {
  aws_ ssm put-parameter --name "/lab/$SFX/db-host" --value db.local --type String >/dev/null
  aws_ ssm put-parameter --name "/lab/$SFX/db-pass" --value 'p@ss' --type SecureString >/dev/null
  echo "String + SecureString, get-by-path returned $(q ssm get-parameters-by-path --path "/lab/$SFX" --with-decryption --query 'length(Parameters)')"
}

t_glue()   { aws_ glue create-database --database-input "Name=labdb_$SFX" >/dev/null; echo "database created ($(q glue get-databases --query 'length(DatabaseList)') total)"; }
t_athena() { echo "list-work-groups ok ($(q athena list-work-groups --query 'length(WorkGroups)'))"; }

# ================= MESSAGING & EVENTS =================
t_sqs() {
  local url m
  url=$(q sqs create-queue --queue-name "lab-q-$SFX" --query QueueUrl)
  aws_ sqs send-message --queue-url "$url" --message-body hello-sqs >/dev/null
  m=$(q sqs receive-message --queue-url "$url" --wait-time-seconds 3 --query 'Messages[0].Body')
  [ "$m" = hello-sqs ] || { echo "expected hello-sqs, got '$m'" >&2; return 1; }
  aws_ sqs create-queue --queue-name "lab-q-$SFX.fifo" --attributes FifoQueue=true,ContentBasedDeduplication=true >/dev/null
  echo "standard send/receive ok, FIFO queue created"
}

t_sns() {
  local topic body
  topic=$(q sns create-topic --name "lab-topic-$SFX" --query TopicArn)
  sqs_url_arn "lab-sns-sub-$SFX"
  aws_ sns subscribe --topic-arn "$topic" --protocol sqs --notification-endpoint "$QARN" >/dev/null
  aws_ sns publish --topic-arn "$topic" --message fan-out-test >/dev/null
  body=$(wait_until 20 "SNS->SQS delivery" recv "$QURL")
  [[ "$body" == *fan-out-test* ]] || { echo "unexpected body: $body" >&2; return 1; }
  echo "topic -> SQS fan-out delivered"
}

t_eventbridge() {
  local bus="lab-bus-$SFX"
  sqs_url_arn "lab-eb-$SFX"
  aws_ events create-event-bus --name "$bus" >/dev/null
  aws_ events put-rule --name "lab-rule-$SFX" --event-bus-name "$bus" --event-pattern '{"source":["lab.app"]}' >/dev/null
  aws_ events put-targets --rule "lab-rule-$SFX" --event-bus-name "$bus" --targets "Id=1,Arn=$QARN" >/dev/null
  aws_ events put-events --entries "[{\"Source\":\"lab.app\",\"DetailType\":\"order.created\",\"Detail\":\"{\\\"orderId\\\":42}\",\"EventBusName\":\"$bus\"}]" >/dev/null
  wait_until 20 "EventBridge->SQS delivery" recv "$QURL" >/dev/null
  echo "custom bus + rule routed event to SQS"
}

t_scheduler() {
  sqs_url_arn "lab-sched-$SFX"
  aws_ scheduler create-schedule --name "lab-sched-$SFX" --schedule-expression "rate(5 minutes)" \
    --flexible-time-window Mode=OFF --target "Arn=$QARN,RoleArn=$ROLE_ARN" >/dev/null
  echo "schedule created (state $(q scheduler get-schedule --name "lab-sched-$SFX" --query State))"
}

t_kinesis() {
  local s="lab-stream-$SFX" shard it n
  aws_ kinesis create-stream --stream-name "$s" --shard-count 1 >/dev/null
  wait_until 30 "stream ACTIVE" bash -c "[ \"\$(aws --endpoint-url $ENDPOINT kinesis describe-stream-summary --stream-name $s --query StreamDescriptionSummary.StreamStatus --output text)\" = ACTIVE ] && echo ok" >/dev/null
  aws_ kinesis put-record --stream-name "$s" --partition-key k1 --data "$(printf click-event | base64)" >/dev/null
  shard=$(q kinesis list-shards --stream-name "$s" --query 'Shards[0].ShardId')
  it=$(q kinesis get-shard-iterator --stream-name "$s" --shard-id "$shard" --shard-iterator-type TRIM_HORIZON --query ShardIterator)
  n=$(q kinesis get-records --shard-iterator "$it" --query 'length(Records)')
  [ "$n" -ge 1 ] || { echo "no records read back" >&2; return 1; }
  echo "put/get records ok ($n read)"
}

t_firehose() {
  local b; b=$(cat "$WORK/bucket" 2>/dev/null || true)
  [ -n "$b" ] || { b="lab-fh-$SFX"; aws_ s3 mb "s3://$b" >/dev/null; }
  aws_ firehose create-delivery-stream --delivery-stream-name "lab-fh-$SFX" --delivery-stream-type DirectPut \
    --extended-s3-destination-configuration "{\"RoleARN\":\"$ROLE_ARN\",\"BucketARN\":\"arn:aws:s3:::$b\",\"Prefix\":\"firehose/\",\"BufferingHints\":{\"SizeInMBs\":1,\"IntervalInSeconds\":60}}" >/dev/null
  aws_ firehose put-record --delivery-stream-name "lab-fh-$SFX" --record "{\"Data\":\"$(printf 'hello firehose\n' | base64)\"}" >/dev/null
  echo "delivery stream -> s3://$b/firehose/ created, record accepted"
}

# ================= COMPUTE & ORCHESTRATION =================
t_lambda() {
  local fn="lab-fn-$SFX" resp url
  python3 - "$HERE/lambda/handler.py" "$WORK/fn.zip" <<'P'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], "w") as z: z.write(sys.argv[1], "handler.py")
P
  aws_ lambda create-function --function-name "$fn" --runtime python3.12 --handler handler.handler \
    --role "$ROLE_ARN" --zip-file "fileb://$WORK/fn.zip" --timeout 30 --environment "Variables={STAGE=lab}" >/dev/null
  printf '{"name":"floci"}' > "$WORK/payload.json"
  # first invoke pulls the python runtime image - can take a minute
  wait_until 180 "Lambda invoke" aws_ lambda invoke --function-name "$fn" --payload "fileb://$WORK/payload.json" "$WORK/lambda-out.json" >/dev/null
  resp=$(cat "$WORK/lambda-out.json")
  [[ "$resp" == *floci* ]] || { echo "unexpected response: $resp" >&2; return 1; }
  url=$(q lambda create-function-url-config --function-name "$fn" --auth-type NONE --query FunctionUrl)
  echo "invoke ok -> $resp | function URL $url"
}

t_stepfunctions() {
  local sm ex st
  sm=$(q stepfunctions create-state-machine --name "lab-sm-$SFX" --role-arn "$ROLE_ARN" \
    --definition '{"StartAt":"Hello","States":{"Hello":{"Type":"Pass","Result":{"msg":"hi"},"Next":"Wait"},"Wait":{"Type":"Wait","Seconds":1,"Next":"Done"},"Done":{"Type":"Succeed"}}}' --query stateMachineArn)
  ex=$(q stepfunctions start-execution --state-machine-arn "$sm" --query executionArn)
  st=$(wait_until 30 "execution finished" bash -c "s=\$(aws --endpoint-url $ENDPOINT stepfunctions describe-execution --execution-arn $ex --query status --output text); [ \"\$s\" != RUNNING ] && echo \$s")
  [ "$st" = SUCCEEDED ] || { echo "execution status $st" >&2; return 1; }
  echo "Pass -> Wait -> Succeed execution SUCCEEDED"
}

t_ecr() { echo "repository $(q ecr create-repository --repository-name "lab/app-$SFX" --query repository.repositoryUri)"; }

t_ecs() {
  aws_ ecs create-cluster --cluster-name "lab-cluster-$SFX" >/dev/null
  local td; td=$(q ecs register-task-definition --cli-input-json '{"family":"lab-nginx","networkMode":"bridge","containerDefinitions":[{"name":"web","image":"nginx:alpine","memory":128,"essential":true,"portMappings":[{"containerPort":80}]}]}' --query taskDefinition.taskDefinitionArn)
  echo "cluster + task definition ${td##*/}"
}

t_ecs_run_task() {
  local c="lab-run-$SFX" td task st
  aws_ ecs create-cluster --cluster-name "$c" >/dev/null
  td=$(q ecs register-task-definition --cli-input-json '{"family":"lab-busybox","containerDefinitions":[{"name":"bb","image":"busybox","memory":64,"essential":true,"command":["echo","hello from ecs"]}]}' --query taskDefinition.taskDefinitionArn)
  task=$(q ecs run-task --cluster "$c" --task-definition "$td" --query 'tasks[0].taskArn')
  st=$(wait_until 180 "task start" bash -c "s=\$(aws --endpoint-url $ENDPOINT ecs describe-tasks --cluster $c --tasks $task --query 'tasks[0].lastStatus' --output text); case \$s in RUNNING|STOPPED) echo \$s;; esac")
  echo "run-task -> $st"
}

t_ec2() {
  local vpc sub sg igw
  vpc=$(q ec2 create-vpc --cidr-block 10.10.0.0/16 --query Vpc.VpcId)
  sub=$(q ec2 create-subnet --vpc-id "$vpc" --cidr-block 10.10.1.0/24 --query Subnet.SubnetId)
  sg=$(q ec2 create-security-group --group-name "lab-sg-$SFX" --description lab --vpc-id "$vpc" --query GroupId)
  aws_ ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
  igw=$(q ec2 create-internet-gateway --query InternetGateway.InternetGatewayId)
  aws_ ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" >/dev/null
  aws_ ec2 create-key-pair --key-name "lab-key-$SFX" >/dev/null
  echo "$sub" > "$WORK/subnet"
  echo "VPC $vpc, subnet, SG(22), IGW, key pair"
}

t_ec2_instance() {
  local ami id st sub; ami=$(q ec2 describe-images --query 'Images[0].ImageId'); [ "$ami" != None ] || ami=ami-12345678
  sub=$(cat "$WORK/subnet" 2>/dev/null || true)
  id=$(q ec2 run-instances --image-id "$ami" --instance-type t3.micro --count 1 ${sub:+--subnet-id "$sub"} --query 'Instances[0].InstanceId')
  st=$(wait_until 180 "instance running" bash -c "s=\$(aws --endpoint-url $ENDPOINT ec2 describe-instances --instance-ids $id --query 'Reservations[0].Instances[0].State.Name' --output text); [ \"\$s\" = running ] && echo \$s")
  echo "instance $id ($ami) $st"
}

t_cloudformation() {
  local name="lab-stack-$SFX" st n
  cat > "$WORK/stack.yaml" <<Y
AWSTemplateFormatVersion: '2010-09-09'
Description: Floci lab stack
Resources:
  LabBucket:
    Type: AWS::S3::Bucket
    Properties: { BucketName: lab-cfn-bucket-$SFX }
  LabQueue:
    Type: AWS::SQS::Queue
    Properties: { QueueName: lab-cfn-queue-$SFX }
  LabParam:
    Type: AWS::SSM::Parameter
    Properties: { Name: /lab/cfn/$SFX, Type: String, Value: from-cloudformation }
Outputs:
  QueueUrl: { Value: !Ref LabQueue }
Y
  aws_ cloudformation create-stack --stack-name "$name" --template-body "file://$WORK/stack.yaml" >/dev/null
  st=$(wait_until 60 "stack create" bash -c "s=\$(aws --endpoint-url $ENDPOINT cloudformation describe-stacks --stack-name $name --query 'Stacks[0].StackStatus' --output text); [[ \$s != *IN_PROGRESS ]] && echo \$s")
  [ "$st" = CREATE_COMPLETE ] || { echo "stack status $st" >&2; return 1; }
  n=$(q cloudformation list-stack-resources --stack-name "$name" --query 'length(StackResourceSummaries)')
  echo "stack CREATE_COMPLETE with $n resources (S3, SQS, SSM)"
}

# ================= API, AUTH, NETWORKING =================
t_apigateway() {
  local api root res
  api=$(q apigateway create-rest-api --name "lab-rest-$SFX" --query id)
  root=$(q apigateway get-resources --rest-api-id "$api" --query "items[?path=='/'].id | [0]")
  res=$(q apigateway create-resource --rest-api-id "$api" --parent-id "$root" --path-part health --query id)
  aws_ apigateway put-method --rest-api-id "$api" --resource-id "$res" --http-method GET --authorization-type NONE >/dev/null
  aws_ apigateway put-integration --rest-api-id "$api" --resource-id "$res" --http-method GET --type MOCK \
    --request-templates '{"application/json":"{\"statusCode\": 200}"}' >/dev/null
  aws_ apigateway put-method-response --rest-api-id "$api" --resource-id "$res" --http-method GET --status-code 200 >/dev/null
  aws_ apigateway put-integration-response --rest-api-id "$api" --resource-id "$res" --http-method GET --status-code 200 >/dev/null
  aws_ apigateway create-deployment --rest-api-id "$api" --stage-name dev >/dev/null
  echo "REST API $api with /health (MOCK) deployed to stage dev"
}

t_apigatewayv2() {
  local api; api=$(q apigatewayv2 create-api --name "lab-http-$SFX" --protocol-type HTTP --query ApiId)
  aws_ apigatewayv2 create-stage --api-id "$api" --stage-name '$default' --auto-deploy >/dev/null
  echo "HTTP API $api + \$default stage"
}

t_cognito() {
  local pool client tok
  pool=$(q cognito-idp create-user-pool --pool-name "lab-pool-$SFX" --query UserPool.Id)
  client=$(q cognito-idp create-user-pool-client --user-pool-id "$pool" --client-name lab-app \
    --explicit-auth-flows ALLOW_ADMIN_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH --query UserPoolClient.ClientId)
  aws_ cognito-idp admin-create-user --user-pool-id "$pool" --username labuser --message-action SUPPRESS >/dev/null
  aws_ cognito-idp admin-set-user-password --user-pool-id "$pool" --username labuser --password 'Lab-Passw0rd!' --permanent >/dev/null
  tok=$(q cognito-idp admin-initiate-auth --user-pool-id "$pool" --client-id "$client" --auth-flow ADMIN_USER_PASSWORD_AUTH \
    --auth-parameters 'USERNAME=labuser,PASSWORD=Lab-Passw0rd!' --query AuthenticationResult.IdToken)
  [ -n "$tok" ] && [ "$tok" != None ] || { echo "no IdToken returned" >&2; return 1; }
  echo "user pool + client, login returned JWT (${#tok} chars)"
}

t_route53() {
  local zone
  zone=$(q route53 create-hosted-zone --name "lab-$SFX.local" --caller-reference "lab-$SFX" --query HostedZone.Id)
  aws_ route53 change-resource-record-sets --hosted-zone-id "$zone" --change-batch \
    "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"api.lab-$SFX.local\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"10.0.0.10\"}]}}]}" >/dev/null
  echo "zone $zone with $(q route53 list-resource-record-sets --hosted-zone-id "$zone" --query 'length(ResourceRecordSets)') record sets"
}

t_acm() {
  local arn; arn=$(q acm request-certificate --domain-name "lab-$SFX.local" --validation-method DNS --query CertificateArn)
  echo "certificate requested (status $(q acm describe-certificate --certificate-arn "$arn" --query Certificate.Status))"
}

t_ses() {
  aws_ ses verify-email-identity --email-address sender@lab.local >/dev/null
  echo "email sent, MessageId $(q ses send-email --from sender@lab.local --destination ToAddresses=dev@lab.local \
    --message 'Subject={Data=Floci test},Body={Text={Data=Hello from the local SES}}' --query MessageId)"
}

# ================= OBSERVABILITY =================
t_logs() {
  local g="/lab/app-$SFX" ts; ts=$(($(date +%s)*1000))
  aws_ logs create-log-group --log-group-name "$g" >/dev/null
  aws_ logs create-log-stream --log-group-name "$g" --log-stream-name s1 >/dev/null
  aws_ logs put-log-events --log-group-name "$g" --log-stream-name s1 \
    --log-events "timestamp=$ts,message=ERROR something broke" "timestamp=$ts,message=INFO all good" >/dev/null
  echo "log group/stream, 2 events written, filter ERROR -> $(q logs filter-log-events --log-group-name "$g" --filter-pattern ERROR --query 'length(events)')"
}

t_cloudwatch() {
  aws_ cloudwatch put-metric-data --namespace "Lab/$SFX" --metric-name Requests --value 5 --unit Count >/dev/null
  aws_ cloudwatch put-metric-alarm --alarm-name "lab-alarm-$SFX" --namespace "Lab/$SFX" --metric-name Requests \
    --statistic Sum --period 60 --evaluation-periods 1 --threshold 100 --comparison-operator GreaterThanThreshold >/dev/null
  echo "metric data ($(q cloudwatch list-metrics --namespace "Lab/$SFX" --query 'length(Metrics)') metric) + alarm"
}

# ================= HEAVY (real containers) =================
t_rds() {
  local id="lab-pg-$SFX"
  aws_ rds create-db-instance --db-instance-identifier "$id" --engine postgres --db-instance-class db.t3.micro \
    --master-username labadmin --master-user-password LabPassw0rd --allocated-storage 20 >/dev/null
  wait_until 300 "RDS available" bash -c "[ \"\$(aws --endpoint-url $ENDPOINT rds describe-db-instances --db-instance-identifier $id --query 'DBInstances[0].DBInstanceStatus' --output text)\" = available ] && echo ok" >/dev/null
  echo "postgres available at $(q rds describe-db-instances --db-instance-identifier "$id" --query 'DBInstances[0].Endpoint.[Address,Port]' | tr '\t' ':') (labadmin / LabPassw0rd)"
}

t_elasticache() {
  local id="lab-redis-$SFX"
  aws_ elasticache create-cache-cluster --cache-cluster-id "$id" --engine redis --cache-node-type cache.t3.micro --num-cache-nodes 1 >/dev/null
  wait_until 240 "Redis available" bash -c "[ \"\$(aws --endpoint-url $ENDPOINT elasticache describe-cache-clusters --cache-cluster-id $id --query 'CacheClusters[0].CacheClusterStatus' --output text)\" = available ] && echo ok" >/dev/null
  echo "redis available at $(q elasticache describe-cache-clusters --cache-cluster-id "$id" --show-cache-node-info --query 'CacheClusters[0].CacheNodes[0].Endpoint.[Address,Port]' | tr '\t' ':')"
}

t_opensearch() {
  local d="lab-os-$SFX"
  aws_ opensearch create-domain --domain-name "$d" >/dev/null
  wait_until 300 "OpenSearch ready" bash -c "[ \"\$(aws --endpoint-url $ENDPOINT opensearch describe-domain --domain-name $d --query DomainStatus.Processing --output text)\" = False ] && echo ok" >/dev/null
  echo "domain ready at $(q opensearch describe-domain --domain-name "$d" --query DomainStatus.Endpoint)"
}

t_eks() {
  local sub n="lab-eks-$SFX" st; sub=$(cat "$WORK/subnet" 2>/dev/null || true)
  if [ -z "$sub" ]; then
    local vpc; vpc=$(q ec2 create-vpc --cidr-block 10.20.0.0/16 --query Vpc.VpcId)
    sub=$(q ec2 create-subnet --vpc-id "$vpc" --cidr-block 10.20.1.0/24 --query Subnet.SubnetId)
  fi
  aws_ eks create-cluster --name "$n" --role-arn "$ROLE_ARN" --resources-vpc-config "subnetIds=$sub" >/dev/null
  st=$(wait_until 300 "EKS cluster" bash -c "s=\$(aws --endpoint-url $ENDPOINT eks describe-cluster --name $n --query cluster.status --output text); [ \"\$s\" != CREATING ] && echo \$s")
  echo "cluster $n -> $st"
}

# ================= RUN =================
rm -f "$WORK/role_arn" "$WORK/bucket" "$WORK/subnet"
run sts t_sts
run iam t_iam
[ -s "$WORK/role_arn" ] && ROLE_ARN=$(cat "$WORK/role_arn")
run s3 t_s3; run dynamodb t_dynamodb; run kms t_kms; run secretsmanager t_secretsmanager
run ssm t_ssm; run glue t_glue; run athena t_athena
run sqs t_sqs; run sns t_sns; run eventbridge t_eventbridge; run scheduler t_scheduler
run kinesis t_kinesis; run firehose t_firehose
run lambda t_lambda; run stepfunctions t_stepfunctions; run ecr t_ecr; run ecs t_ecs
run ecs-run-task t_ecs_run_task 1; run ec2 t_ec2; run ec2-instance t_ec2_instance 1; run cloudformation t_cloudformation
run apigateway t_apigateway; run apigatewayv2 t_apigatewayv2; run cognito t_cognito
run route53 t_route53; run acm t_acm; run ses t_ses
run logs t_logs; run cloudwatch t_cloudwatch
run rds t_rds 1; run elasticache t_elasticache 1; run opensearch t_opensearch 1; run eks t_eks 1

echo -e "\n${C}PASS $PASS   FAIL $FAIL   SKIP $SKIP   -> $RESULTS${N}"
echo -e "${Y}Reset everything:  docker compose down && docker compose up -d${N}"
[ $FAIL -eq 0 ]
