<#
.SYNOPSIS
  Smoke-tests AWS services against a local Floci emulator (http://localhost:4566).

.EXAMPLE
  .\test-all.ps1                    # all light services
.EXAMPLE
  .\test-all.ps1 -Heavy             # also RDS, ElastiCache, EKS, ECS run-task, EC2 instance, OpenSearch (pull big images)
.EXAMPLE
  .\test-all.ps1 -Only s3,lambda    # just these
#>
param(
    [switch]$Heavy,
    [string[]]$Only,
    [string]$Endpoint = "http://localhost:4566"
)

$ErrorActionPreference = "Stop"
if ($Only) { $Only = @($Only -split "," | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }) }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$work = Join-Path $here "work"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# --- Isolated AWS CLI settings: never touches your real ~/.aws config ---------
$env:AWS_ENDPOINT_URL            = $Endpoint
$env:AWS_ACCESS_KEY_ID           = "test"
$env:AWS_SECRET_ACCESS_KEY       = "test"
$env:AWS_DEFAULT_REGION          = "us-east-1"
$env:AWS_CONFIG_FILE             = Join-Path $here "aws-config"
$env:AWS_SHARED_CREDENTIALS_FILE = Join-Path $work "no-credentials"
Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue

$sfx = Get-Date -Format "HHmmss"

# --- Helpers -------------------------------------------------------------------
function Invoke-Aws {
    $ErrorActionPreference = "Continue"
    # Pass --endpoint-url explicitly: some CLI customizations (e.g. SQS) ignore AWS_ENDPOINT_URL
    $out = & aws --endpoint-url $script:Endpoint @args 2>&1 | ForEach-Object { "$_" } | Out-String
    if ($LASTEXITCODE -ne 0) { throw ("aws " + ($args -join " ") + " => " + $out.Trim()) }
    return $out.Trim()
}

function Write-JsonFile([string]$name, [string]$content) {
    $p = Join-Path $work $name
    [IO.File]::WriteAllText($p, $content, (New-Object Text.UTF8Encoding $false))
    return "file://" + ($p -replace '\\', '/')
}

function Wait-Until([scriptblock]$cond, [int]$seconds = 60, [string]$what = "condition") {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try { $v = & $cond; if ($v) { return $v } } catch { }
        Start-Sleep -Seconds 2
    }
    throw "timed out after ${seconds}s waiting for $what"
}

$results = New-Object System.Collections.Generic.List[object]

function Test-Service([string]$name, [scriptblock]$body, [switch]$IsHeavy) {
    if ($Only -and ($Only -notcontains $name)) { return }
    if ($IsHeavy -and -not $Heavy) {
        $results.Add([pscustomobject]@{ Service = $name; Status = "SKIP"; Seconds = 0; Detail = "heavy - rerun with -Heavy" })
        Write-Host ("  SKIP  {0,-16} heavy - rerun with -Heavy" -f $name) -ForegroundColor DarkGray
        return
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = "" + (& $body | Select-Object -Last 1)
        $status = "PASS"; $color = "Green"
    } catch {
        $msg = $_.Exception.Message -replace "\s+", " "
        if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) + "..." }
        $detail = $msg; $status = "FAIL"; $color = "Red"
    }
    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $results.Add([pscustomobject]@{ Service = $name; Status = $status; Seconds = $secs; Detail = $detail })
    Write-Host ("  {0,-5} {1,-16} {2,6}s  {3}" -f $status, $name, $secs, $detail) -ForegroundColor $color
}

# --- Pre-flight ---------------------------------------------------------------
foreach ($cmd in "aws", "docker") {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "$cmd not found on PATH - install it first (see README.md)" }
}
Write-Host "Waiting for Floci at $Endpoint ..." -ForegroundColor Cyan
$null = Wait-Until { Invoke-Aws sts get-caller-identity } 60 "Floci (is 'docker compose up -d' running?)"
$acct = Invoke-Aws sts get-caller-identity --query Account --output text
Write-Host "Floci is up. Account $acct, run suffix $sfx`n" -ForegroundColor Cyan

# Shared resources (tests fill these in; defaults let tests run independently)
$script:roleArn = "arn:aws:iam::${acct}:role/lab-role"
$script:bucket  = $null

# =============================================================================
#  CORE
# =============================================================================
Test-Service "sts" {
    $arn = Invoke-Aws sts get-caller-identity --query Arn --output text
    "caller = $arn"
}

Test-Service "iam" {
    $trust = Write-JsonFile "trust.json" '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["lambda.amazonaws.com","states.amazonaws.com","scheduler.amazonaws.com","firehose.amazonaws.com","eks.amazonaws.com"]},"Action":"sts:AssumeRole"}]}'
    $script:roleArn = Invoke-Aws iam create-role --role-name "lab-role-$sfx" --assume-role-policy-document $trust --query Role.Arn --output text
    $pol = Write-JsonFile "policy.json" '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}'
    $polArn = Invoke-Aws iam create-policy --policy-name "lab-all-$sfx" --policy-document $pol --query Policy.Arn --output text
    Invoke-Aws iam attach-role-policy --role-name "lab-role-$sfx" --policy-arn $polArn | Out-Null
    Invoke-Aws iam create-user --user-name "lab-user-$sfx" | Out-Null
    $key = Invoke-Aws iam create-access-key --user-name "lab-user-$sfx" --query AccessKey.AccessKeyId --output text
    $n = Invoke-Aws iam list-attached-role-policies --role-name "lab-role-$sfx" --query "length(AttachedPolicies)" --output text
    "role+policy ($n attached), user+access key $key"
}

# =============================================================================
#  STORAGE & DATA
# =============================================================================
Test-Service "s3" {
    $b = "lab-bucket-$sfx"
    Invoke-Aws s3 mb "s3://$b" | Out-Null
    $f = Join-Path $work "hello.txt"; Set-Content -Path $f -Value "hello from floci" -Encoding ascii
    Invoke-Aws s3 cp $f "s3://$b/folder/hello.txt" | Out-Null
    Invoke-Aws s3api put-bucket-versioning --bucket $b --versioning-configuration Status=Enabled | Out-Null
    Invoke-Aws s3api put-object-tagging --bucket $b --key folder/hello.txt --tagging 'TagSet=[{Key=env,Value=lab}]' | Out-Null
    $back = Join-Path $work "hello-back.txt"
    Invoke-Aws s3 cp "s3://$b/folder/hello.txt" $back | Out-Null
    $txt = (Get-Content $back -Raw).Trim()
    if ($txt -ne "hello from floci") { throw "downloaded content mismatch: '$txt'" }
    $url = Invoke-Aws s3 presign "s3://$b/folder/hello.txt" --expires-in 300
    $code = (Invoke-WebRequest -UseBasicParsing -Uri $url).StatusCode
    $script:bucket = $b
    "upload/download/versioning/tagging ok, presigned GET -> HTTP $code"
}

Test-Service "dynamodb" {
    $t = "lab-table-$sfx"
    Invoke-Aws dynamodb create-table --table-name $t --attribute-definitions "AttributeName=pk,AttributeType=S" `
        --key-schema "AttributeName=pk,KeyType=HASH" --billing-mode PAY_PER_REQUEST | Out-Null
    $null = Wait-Until { (Invoke-Aws dynamodb describe-table --table-name $t --query Table.TableStatus --output text) -eq "ACTIVE" } 30 "table ACTIVE"
    $item = Write-JsonFile "item.json" '{"pk":{"S":"user#1"},"name":{"S":"floci"},"visits":{"N":"1"}}'
    Invoke-Aws dynamodb put-item --table-name $t --item $item | Out-Null
    $key = Write-JsonFile "key.json" '{"pk":{"S":"user#1"}}'
    $vals = Write-JsonFile "vals.json" '{":one":{"N":"1"}}'
    Invoke-Aws dynamodb update-item --table-name $t --key $key --update-expression "SET visits = visits + :one" --expression-attribute-values $vals | Out-Null
    $v = Invoke-Aws dynamodb get-item --table-name $t --key $key --query Item.visits.N --output text
    if ($v -ne "2") { throw "expected visits=2, got $v" }
    "create/put/update/get ok (visits=$v)"
}

Test-Service "kms" {
    $keyId = Invoke-Aws kms create-key --description "lab key" --query KeyMetadata.KeyId --output text
    Invoke-Aws kms create-alias --alias-name "alias/lab-$sfx" --target-key-id $keyId | Out-Null
    $ct = Invoke-Aws kms encrypt --key-id "alias/lab-$sfx" --plaintext "top-secret" --cli-binary-format raw-in-base64-out --query CiphertextBlob --output text
    $ctFile = Join-Path $work "cipher.bin"
    [IO.File]::WriteAllBytes($ctFile, [Convert]::FromBase64String($ct))
    $pt64 = Invoke-Aws kms decrypt --ciphertext-blob ("fileb://" + ($ctFile -replace '\\', '/')) --query Plaintext --output text
    $pt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pt64))
    if ($pt -ne "top-secret") { throw "decrypt mismatch: $pt" }
    "key+alias, encrypt/decrypt round-trip ok"
}

Test-Service "secretsmanager" {
    $n = "lab/db-password-$sfx"
    Invoke-Aws secretsmanager create-secret --name $n --secret-string "s3cr3t" | Out-Null
    Invoke-Aws secretsmanager put-secret-value --secret-id $n --secret-string "s3cr3t-v2" | Out-Null
    $v = Invoke-Aws secretsmanager get-secret-value --secret-id $n --query SecretString --output text
    if ($v -ne "s3cr3t-v2") { throw "got $v" }
    "create/rotate value/get ok"
}

Test-Service "ssm" {
    $n = "/lab/$sfx/db-host"
    Invoke-Aws ssm put-parameter --name $n --value "db.local" --type String | Out-Null
    Invoke-Aws ssm put-parameter --name "/lab/$sfx/db-pass" --value "p@ss" --type SecureString | Out-Null
    $c = Invoke-Aws ssm get-parameters-by-path --path "/lab/$sfx" --with-decryption --query "length(Parameters)" --output text
    "String + SecureString, get-by-path returned $c"
}

Test-Service "glue" {
    Invoke-Aws glue create-database --database-input "Name=labdb_$sfx" | Out-Null
    $c = Invoke-Aws glue get-databases --query "length(DatabaseList)" --output text
    "database created ($c total)"
}

Test-Service "athena" {
    $c = Invoke-Aws athena list-work-groups --query "length(WorkGroups)" --output text
    "list-work-groups ok ($c)"
}

# =============================================================================
#  MESSAGING & EVENTS
# =============================================================================
Test-Service "sqs" {
    $url = Invoke-Aws sqs create-queue --queue-name "lab-q-$sfx" --query QueueUrl --output text
    Invoke-Aws sqs send-message --queue-url $url --message-body "hello-sqs" | Out-Null
    $m = Invoke-Aws sqs receive-message --queue-url $url --wait-time-seconds 3 --query "Messages[0].Body" --output text
    if ($m -ne "hello-sqs") { throw "expected hello-sqs, got '$m'" }
    Invoke-Aws sqs create-queue --queue-name "lab-q-$sfx.fifo" --attributes "FifoQueue=true,ContentBasedDeduplication=true" --query QueueUrl --output text | Out-Null
    "standard send/receive ok, FIFO queue created"
}

Test-Service "sns" {
    $topic = Invoke-Aws sns create-topic --name "lab-topic-$sfx" --query TopicArn --output text
    $qUrl = Invoke-Aws sqs create-queue --queue-name "lab-sns-sub-$sfx" --query QueueUrl --output text
    $qArn = Invoke-Aws sqs get-queue-attributes --queue-url $qUrl --attribute-names QueueArn --query Attributes.QueueArn --output text
    Invoke-Aws sns subscribe --topic-arn $topic --protocol sqs --notification-endpoint $qArn | Out-Null
    Invoke-Aws sns publish --topic-arn $topic --message "fan-out-test" | Out-Null
    $body = Wait-Until { $b = Invoke-Aws sqs receive-message --queue-url $qUrl --wait-time-seconds 2 --query "Messages[0].Body" --output text; if ($b -and $b -ne "None") { $b } } 20 "SNS->SQS delivery"
    if ($body -notmatch "fan-out-test") { throw "unexpected body: $body" }
    "topic -> SQS fan-out delivered"
}

Test-Service "eventbridge" {
    $qUrl = Invoke-Aws sqs create-queue --queue-name "lab-eb-$sfx" --query QueueUrl --output text
    $qArn = Invoke-Aws sqs get-queue-attributes --queue-url $qUrl --attribute-names QueueArn --query Attributes.QueueArn --output text
    $bus = "lab-bus-$sfx"
    Invoke-Aws events create-event-bus --name $bus | Out-Null
    $pattern = Write-JsonFile "pattern.json" '{"source":["lab.app"]}'
    Invoke-Aws events put-rule --name "lab-rule-$sfx" --event-bus-name $bus --event-pattern $pattern | Out-Null
    Invoke-Aws events put-targets --rule "lab-rule-$sfx" --event-bus-name $bus --targets "Id=1,Arn=$qArn" | Out-Null
    $entries = Write-JsonFile "events.json" ('[{"Source":"lab.app","DetailType":"order.created","Detail":"{\"orderId\":42}","EventBusName":"' + $bus + '"}]')
    Invoke-Aws events put-events --entries $entries | Out-Null
    $body = Wait-Until { $b = Invoke-Aws sqs receive-message --queue-url $qUrl --wait-time-seconds 2 --query "Messages[0].Body" --output text; if ($b -and $b -ne "None") { $b } } 20 "EventBridge->SQS delivery"
    "custom bus + rule routed event to SQS"
}

Test-Service "scheduler" {
    $qUrl = Invoke-Aws sqs create-queue --queue-name "lab-sched-$sfx" --query QueueUrl --output text
    $qArn = Invoke-Aws sqs get-queue-attributes --queue-url $qUrl --attribute-names QueueArn --query Attributes.QueueArn --output text
    Invoke-Aws scheduler create-schedule --name "lab-sched-$sfx" --schedule-expression "rate(5 minutes)" `
        --flexible-time-window Mode=OFF --target "Arn=$qArn,RoleArn=$($script:roleArn)" | Out-Null
    $s = Invoke-Aws scheduler get-schedule --name "lab-sched-$sfx" --query State --output text
    "schedule created (state $s)"
}

Test-Service "kinesis" {
    $s = "lab-stream-$sfx"
    Invoke-Aws kinesis create-stream --stream-name $s --shard-count 1 | Out-Null
    $null = Wait-Until { (Invoke-Aws kinesis describe-stream-summary --stream-name $s --query StreamDescriptionSummary.StreamStatus --output text) -eq "ACTIVE" } 30 "stream ACTIVE"
    Invoke-Aws kinesis put-record --stream-name $s --partition-key k1 --data "click-event" --cli-binary-format raw-in-base64-out | Out-Null
    $shard = Invoke-Aws kinesis list-shards --stream-name $s --query "Shards[0].ShardId" --output text
    $it = Invoke-Aws kinesis get-shard-iterator --stream-name $s --shard-id $shard --shard-iterator-type TRIM_HORIZON --query ShardIterator --output text
    $n = Invoke-Aws kinesis get-records --shard-iterator $it --query "length(Records)" --output text
    if ([int]$n -lt 1) { throw "no records read back" }
    "put/get records ok ($n read)"
}

Test-Service "firehose" {
    $b = $script:bucket
    if (-not $b) { $b = "lab-fh-$sfx"; Invoke-Aws s3 mb "s3://$b" | Out-Null }
    $cfg = Write-JsonFile "firehose.json" ('{"RoleARN":"' + $script:roleArn + '","BucketARN":"arn:aws:s3:::' + $b + '","Prefix":"firehose/","BufferingHints":{"SizeInMBs":1,"IntervalInSeconds":60}}')
    Invoke-Aws firehose create-delivery-stream --delivery-stream-name "lab-fh-$sfx" --delivery-stream-type DirectPut --extended-s3-destination-configuration $cfg | Out-Null
    $rec = Write-JsonFile "fh-record.json" '{"Data":"hello firehose\n"}'
    Invoke-Aws firehose put-record --delivery-stream-name "lab-fh-$sfx" --record $rec --cli-binary-format raw-in-base64-out | Out-Null
    "delivery stream -> s3://$b/firehose/ created, record accepted"
}

# =============================================================================
#  COMPUTE & ORCHESTRATION
# =============================================================================
Test-Service "lambda" {
    $zip = Join-Path $work "fn.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path (Join-Path $here "lambda") "handler.py") -DestinationPath $zip
    $fn = "lab-fn-$sfx"
    Invoke-Aws lambda create-function --function-name $fn --runtime python3.12 --handler handler.handler `
        --role $script:roleArn --zip-file ("fileb://" + ($zip -replace '\\', '/')) --timeout 30 `
        --environment "Variables={STAGE=lab}" | Out-Null
    $payload = Write-JsonFile "payload.json" '{"name":"floci"}'
    $outF = Join-Path $work "lambda-out.json"
    # First invoke pulls the python runtime image - can take a minute
    $null = Wait-Until { Invoke-Aws lambda invoke --function-name $fn --cli-binary-format raw-in-base64-out --payload $payload $outF; $true } 180 "Lambda invoke"
    $resp = Get-Content $outF -Raw
    if ($resp -notmatch "floci") { throw "unexpected response: $resp" }
    $url = Invoke-Aws lambda create-function-url-config --function-name $fn --auth-type NONE --query FunctionUrl --output text
    "invoke ok -> $($resp.Trim()) | function URL $url"
}

Test-Service "stepfunctions" {
    $def = Write-JsonFile "sfn.json" '{"StartAt":"Hello","States":{"Hello":{"Type":"Pass","Result":{"msg":"hi from step functions"},"Next":"Wait"},"Wait":{"Type":"Wait","Seconds":1,"Next":"Done"},"Done":{"Type":"Succeed"}}}'
    $sm = Invoke-Aws stepfunctions create-state-machine --name "lab-sm-$sfx" --definition $def --role-arn $script:roleArn --query stateMachineArn --output text
    $ex = Invoke-Aws stepfunctions start-execution --state-machine-arn $sm --query executionArn --output text
    $st = Wait-Until { $s = Invoke-Aws stepfunctions describe-execution --execution-arn $ex --query status --output text; if ($s -ne "RUNNING") { $s } } 30 "execution finished"
    if ($st -ne "SUCCEEDED") { throw "execution status $st" }
    "Pass -> Wait -> Succeed execution SUCCEEDED"
}

Test-Service "ecr" {
    $uri = Invoke-Aws ecr create-repository --repository-name "lab/app-$sfx" --query repository.repositoryUri --output text
    "repository $uri"
}

Test-Service "ecs" {
    $c = Invoke-Aws ecs create-cluster --cluster-name "lab-cluster-$sfx" --query cluster.clusterArn --output text
    $td = Write-JsonFile "taskdef.json" '{"family":"lab-nginx","networkMode":"bridge","containerDefinitions":[{"name":"web","image":"nginx:alpine","memory":128,"essential":true,"portMappings":[{"containerPort":80}]}]}'
    $tdArn = Invoke-Aws ecs register-task-definition --cli-input-json $td --query taskDefinition.taskDefinitionArn --output text
    "cluster + task definition $($tdArn.Split('/')[-1])"
}

Test-Service "ecs-run-task" -IsHeavy {
    $c = "lab-run-$sfx"
    Invoke-Aws ecs create-cluster --cluster-name $c | Out-Null
    $td = Write-JsonFile "taskdef2.json" '{"family":"lab-busybox","containerDefinitions":[{"name":"bb","image":"busybox","memory":64,"essential":true,"command":["echo","hello from ecs"]}]}'
    $tdArn = Invoke-Aws ecs register-task-definition --cli-input-json $td --query taskDefinition.taskDefinitionArn --output text
    $task = Invoke-Aws ecs run-task --cluster $c --task-definition $tdArn --query "tasks[0].taskArn" --output text
    $st = Wait-Until { $s = Invoke-Aws ecs describe-tasks --cluster $c --tasks $task --query "tasks[0].lastStatus" --output text; if ($s -in "RUNNING", "STOPPED") { $s } } 180 "task start"
    "run-task -> $st"
}

Test-Service "ec2" {
    $vpc = Invoke-Aws ec2 create-vpc --cidr-block 10.10.0.0/16 --query Vpc.VpcId --output text
    $sub = Invoke-Aws ec2 create-subnet --vpc-id $vpc --cidr-block 10.10.1.0/24 --query Subnet.SubnetId --output text
    $sg = Invoke-Aws ec2 create-security-group --group-name "lab-sg-$sfx" --description lab --vpc-id $vpc --query GroupId --output text
    Invoke-Aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 22 --cidr 0.0.0.0/0 | Out-Null
    $igw = Invoke-Aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text
    Invoke-Aws ec2 attach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc | Out-Null
    Invoke-Aws ec2 create-key-pair --key-name "lab-key-$sfx" --query KeyName --output text | Out-Null
    $script:subnetId = $sub; $script:sgId = $sg
    "VPC $vpc, subnet, SG(22), IGW, key pair"
}

Test-Service "ec2-instance" -IsHeavy {
    $ami = Invoke-Aws ec2 describe-images --query "Images[0].ImageId" --output text
    if (-not $ami -or $ami -eq "None") { $ami = "ami-12345678" }
    $args2 = @("ec2", "run-instances", "--image-id", $ami, "--instance-type", "t3.micro", "--count", "1", "--query", "Instances[0].InstanceId", "--output", "text")
    if ($script:subnetId) { $args2 += @("--subnet-id", $script:subnetId) }
    $id = Invoke-Aws @args2
    $st = Wait-Until { $s = Invoke-Aws ec2 describe-instances --instance-ids $id --query "Reservations[0].Instances[0].State.Name" --output text; if ($s -eq "running") { $s } } 180 "instance running"
    "instance $id ($ami) $st"
}

Test-Service "cloudformation" {
    $tpl = Join-Path $work "stack.yaml"
    @"
AWSTemplateFormatVersion: '2010-09-09'
Description: Floci lab stack
Resources:
  LabBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: lab-cfn-bucket-$sfx
  LabQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: lab-cfn-queue-$sfx
  LabParam:
    Type: AWS::SSM::Parameter
    Properties:
      Name: /lab/cfn/$sfx
      Type: String
      Value: from-cloudformation
Outputs:
  QueueUrl:
    Value: !Ref LabQueue
"@ | Set-Content -Path $tpl -Encoding ascii
    $name = "lab-stack-$sfx"
    Invoke-Aws cloudformation create-stack --stack-name $name --template-body ("file://" + ($tpl -replace '\\', '/')) | Out-Null
    $st = Wait-Until { $s = Invoke-Aws cloudformation describe-stacks --stack-name $name --query "Stacks[0].StackStatus" --output text; if ($s -notlike "*IN_PROGRESS") { $s } } 60 "stack create"
    if ($st -ne "CREATE_COMPLETE") { throw "stack status $st" }
    $n = Invoke-Aws cloudformation list-stack-resources --stack-name $name --query "length(StackResourceSummaries)" --output text
    "stack CREATE_COMPLETE with $n resources (S3, SQS, SSM)"
}

# =============================================================================
#  API, AUTH, NETWORKING
# =============================================================================
Test-Service "apigateway" {
    $api = Invoke-Aws apigateway create-rest-api --name "lab-rest-$sfx" --query id --output text
    $root = Invoke-Aws apigateway get-resources --rest-api-id $api --query "items[?path=='/'].id | [0]" --output text
    $res = Invoke-Aws apigateway create-resource --rest-api-id $api --parent-id $root --path-part health --query id --output text
    Invoke-Aws apigateway put-method --rest-api-id $api --resource-id $res --http-method GET --authorization-type NONE | Out-Null
    $tpl = Write-JsonFile "mock-req.json" '{"application/json":"{\"statusCode\": 200}"}'
    Invoke-Aws apigateway put-integration --rest-api-id $api --resource-id $res --http-method GET --type MOCK --request-templates $tpl | Out-Null
    Invoke-Aws apigateway put-method-response --rest-api-id $api --resource-id $res --http-method GET --status-code 200 | Out-Null
    Invoke-Aws apigateway put-integration-response --rest-api-id $api --resource-id $res --http-method GET --status-code 200 | Out-Null
    Invoke-Aws apigateway create-deployment --rest-api-id $api --stage-name dev | Out-Null
    "REST API $api with /health (MOCK) deployed to stage dev"
}

Test-Service "apigatewayv2" {
    $api = Invoke-Aws apigatewayv2 create-api --name "lab-http-$sfx" --protocol-type HTTP --query ApiId --output text
    Invoke-Aws apigatewayv2 create-stage --api-id $api --stage-name '$default' --auto-deploy | Out-Null
    "HTTP API $api + `$default stage"
}

Test-Service "cognito" {
    $pool = Invoke-Aws cognito-idp create-user-pool --pool-name "lab-pool-$sfx" --query UserPool.Id --output text
    $client = Invoke-Aws cognito-idp create-user-pool-client --user-pool-id $pool --client-name lab-app `
        --explicit-auth-flows ALLOW_ADMIN_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH --query UserPoolClient.ClientId --output text
    Invoke-Aws cognito-idp admin-create-user --user-pool-id $pool --username labuser --message-action SUPPRESS | Out-Null
    Invoke-Aws cognito-idp admin-set-user-password --user-pool-id $pool --username labuser --password "Lab-Passw0rd!" --permanent | Out-Null
    $tok = Invoke-Aws cognito-idp admin-initiate-auth --user-pool-id $pool --client-id $client --auth-flow ADMIN_USER_PASSWORD_AUTH `
        --auth-parameters "USERNAME=labuser,PASSWORD=Lab-Passw0rd!" --query AuthenticationResult.IdToken --output text
    if (-not $tok -or $tok -eq "None") { throw "no IdToken returned" }
    "user pool + client, login returned JWT ($($tok.Length) chars)"
}

Test-Service "route53" {
    $zone = Invoke-Aws route53 create-hosted-zone --name "lab-$sfx.local" --caller-reference "lab-$sfx" --query HostedZone.Id --output text
    $batch = Write-JsonFile "rr.json" ('{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"api.lab-' + $sfx + '.local","Type":"A","TTL":60,"ResourceRecords":[{"Value":"10.0.0.10"}]}}]}')
    Invoke-Aws route53 change-resource-record-sets --hosted-zone-id $zone --change-batch $batch | Out-Null
    $n = Invoke-Aws route53 list-resource-record-sets --hosted-zone-id $zone --query "length(ResourceRecordSets)" --output text
    "zone $zone with $n record sets"
}

Test-Service "acm" {
    $arn = Invoke-Aws acm request-certificate --domain-name "lab-$sfx.local" --validation-method DNS --query CertificateArn --output text
    $st = Invoke-Aws acm describe-certificate --certificate-arn $arn --query Certificate.Status --output text
    "certificate requested (status $st)"
}

Test-Service "ses" {
    Invoke-Aws ses verify-email-identity --email-address "sender@lab.local" | Out-Null
    $id = Invoke-Aws ses send-email --from "sender@lab.local" --destination "ToAddresses=dev@lab.local" `
        --message 'Subject={Data=Floci test},Body={Text={Data=Hello from the local SES}}' --query MessageId --output text
    "email sent, MessageId $id"
}

# =============================================================================
#  OBSERVABILITY
# =============================================================================
Test-Service "logs" {
    $g = "/lab/app-$sfx"
    Invoke-Aws logs create-log-group --log-group-name $g | Out-Null
    Invoke-Aws logs create-log-stream --log-group-name $g --log-stream-name s1 | Out-Null
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Invoke-Aws logs put-log-events --log-group-name $g --log-stream-name s1 --log-events "timestamp=$ts,message=ERROR something broke" "timestamp=$ts,message=INFO all good" | Out-Null
    $n = Invoke-Aws logs filter-log-events --log-group-name $g --filter-pattern ERROR --query "length(events)" --output text
    "log group/stream, 2 events written, filter ERROR -> $n"
}

Test-Service "cloudwatch" {
    Invoke-Aws cloudwatch put-metric-data --namespace "Lab/$sfx" --metric-name Requests --value 5 --unit Count | Out-Null
    Invoke-Aws cloudwatch put-metric-alarm --alarm-name "lab-alarm-$sfx" --namespace "Lab/$sfx" --metric-name Requests `
        --statistic Sum --period 60 --evaluation-periods 1 --threshold 100 --comparison-operator GreaterThanThreshold | Out-Null
    $n = Invoke-Aws cloudwatch list-metrics --namespace "Lab/$sfx" --query "length(Metrics)" --output text
    "metric data ($n metric) + alarm"
}

# =============================================================================
#  HEAVY (real containers: pull images, take minutes)
# =============================================================================
Test-Service "rds" -IsHeavy {
    $id = "lab-pg-$sfx"
    Invoke-Aws rds create-db-instance --db-instance-identifier $id --engine postgres --db-instance-class db.t3.micro `
        --master-username labadmin --master-user-password "LabPassw0rd" --allocated-storage 20 | Out-Null
    $null = Wait-Until { (Invoke-Aws rds describe-db-instances --db-instance-identifier $id --query "DBInstances[0].DBInstanceStatus" --output text) -eq "available" } 300 "RDS available"
    $ep = Invoke-Aws rds describe-db-instances --db-instance-identifier $id --query "DBInstances[0].Endpoint.[Address,Port]" --output text
    "postgres available at $($ep -replace '\s+', ':')  (user labadmin / LabPassw0rd)"
}

Test-Service "elasticache" -IsHeavy {
    $id = "lab-redis-$sfx"
    Invoke-Aws elasticache create-cache-cluster --cache-cluster-id $id --engine redis --cache-node-type cache.t3.micro --num-cache-nodes 1 | Out-Null
    $null = Wait-Until { (Invoke-Aws elasticache describe-cache-clusters --cache-cluster-id $id --query "CacheClusters[0].CacheClusterStatus" --output text) -eq "available" } 240 "Redis available"
    $ep = Invoke-Aws elasticache describe-cache-clusters --cache-cluster-id $id --show-cache-node-info --query "CacheClusters[0].CacheNodes[0].Endpoint.[Address,Port]" --output text
    "redis available at $($ep -replace '\s+', ':')"
}

Test-Service "opensearch" -IsHeavy {
    $d = "lab-os-$sfx".Substring(0, [Math]::Min(28, "lab-os-$sfx".Length))
    Invoke-Aws opensearch create-domain --domain-name $d | Out-Null
    $null = Wait-Until { (Invoke-Aws opensearch describe-domain --domain-name $d --query "DomainStatus.Processing" --output text) -eq "False" } 300 "OpenSearch ready"
    $ep = Invoke-Aws opensearch describe-domain --domain-name $d --query DomainStatus.Endpoint --output text
    "domain ready at $ep"
}

Test-Service "eks" -IsHeavy {
    $sub = $script:subnetId
    if (-not $sub) {
        $vpc = Invoke-Aws ec2 create-vpc --cidr-block 10.20.0.0/16 --query Vpc.VpcId --output text
        $sub = Invoke-Aws ec2 create-subnet --vpc-id $vpc --cidr-block 10.20.1.0/24 --query Subnet.SubnetId --output text
    }
    $n = "lab-eks-$sfx"
    Invoke-Aws eks create-cluster --name $n --role-arn $script:roleArn --resources-vpc-config "subnetIds=$sub" | Out-Null
    $st = Wait-Until { $s = Invoke-Aws eks describe-cluster --name $n --query cluster.status --output text; if ($s -ne "CREATING") { $s } } 300 "EKS cluster"
    "cluster $n -> $st"
}

# =============================================================================
#  SUMMARY
# =============================================================================
$csv = Join-Path $here "results.csv"
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$pass = @($results | Where-Object Status -eq "PASS").Count
$fail = @($results | Where-Object Status -eq "FAIL").Count
$skip = @($results | Where-Object Status -eq "SKIP").Count
Write-Host ""
Write-Host ("PASS {0}   FAIL {1}   SKIP {2}   -> {3}" -f $pass, $fail, $skip, $csv) -ForegroundColor Cyan
if ($fail -gt 0) {
    Write-Host "Failed services:" -ForegroundColor Red
    $results | Where-Object Status -eq "FAIL" | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.Service, $_.Detail) -ForegroundColor Red }
}
Write-Host "Reset everything with:  docker compose down; docker compose up -d" -ForegroundColor DarkGray
