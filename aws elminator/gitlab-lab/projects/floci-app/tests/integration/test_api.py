"""Integration tests: call the deployed API on Floci, then check every side effect
(DynamoDB item, SNS -> both SQS queues, S3 invoice).

Needs: API_URL (from the deploy job), AWS_ENDPOINT_URL, PREFIX.
"""
import json
import os
import time
import urllib.error
import urllib.request

import boto3
import pytest

API_URL = os.environ["API_URL"].rstrip("/")
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://floci:4566")
PREFIX = os.environ.get("PREFIX", "lab")


def aws(name):
    return boto3.client(name, endpoint_url=ENDPOINT)


def ssm(key):
    return aws("ssm").get_parameter(Name=f"/{PREFIX}/infra/{key}")["Parameter"]["Value"]


def http(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{API_URL}{path}", data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


@pytest.fixture(scope="module")
def order():
    status, body = http("POST", "/orders", {"customer": "CI Pipeline", "item": "Fiber Router", "amount": 1499.5})
    assert status == 201, body
    return body


def test_create_returns_order(order):
    assert order["status"] == "CREATED"
    assert order["amount"] == 1499.5


def test_get_returns_same_order(order):
    status, body = http("GET", f"/orders/{order['orderId']}")
    assert status == 200
    assert body["customer"] == "CI Pipeline"


def test_validation_error_is_400():
    status, body = http("POST", "/orders", {"customer": "x"})
    assert status == 400 and body["errors"]


def test_unknown_order_is_404():
    status, _ = http("GET", "/orders/does-not-exist")
    assert status == 404


def test_order_stored_in_dynamodb(order):
    item = aws("dynamodb").get_item(TableName=ssm("orders_table"), Key={"orderId": {"S": order["orderId"]}})
    assert "Item" in item


def test_invoice_written_to_s3(order):
    obj = aws("s3").get_object(Bucket=ssm("invoices_bucket"), Key=f"invoices/{order['orderId']}.txt")
    assert order["orderId"] in obj["Body"].read().decode()


@pytest.mark.parametrize("consumer", ["billing", "shipping"])
def test_event_fanned_out_to_queue(order, consumer):
    sqs = aws("sqs")
    url = sqs.get_queue_url(QueueName=ssm(f"{consumer}_queue_name"))["QueueUrl"]
    deadline = time.time() + 30
    while time.time() < deadline:
        for m in sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=10, WaitTimeSeconds=2).get("Messages", []):
            if order["orderId"] in m["Body"]:
                sqs.delete_message(QueueUrl=url, ReceiptHandle=m["ReceiptHandle"])
                return
    pytest.fail(f"OrderCreated event for {order['orderId']} never reached {consumer} queue")
