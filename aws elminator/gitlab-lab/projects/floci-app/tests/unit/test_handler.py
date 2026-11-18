"""Unit tests: no AWS, no Floci. AWS clients are replaced with in-memory fakes."""
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "src"))
import handler  # noqa: E402


class FakeAws:
    def __init__(self):
        self.items, self.published, self.objects = {}, [], {}

    # dynamodb
    def put_item(self, TableName, Item):
        self.items[Item["orderId"]["S"]] = Item

    def get_item(self, TableName, Key):
        item = self.items.get(Key["orderId"]["S"])
        return {"Item": item} if item else {}

    # sns
    def publish(self, TopicArn, Message, **kw):
        self.published.append(json.loads(Message))

    # s3
    def put_object(self, Bucket, Key, Body, **kw):
        self.objects[Key] = Body


@pytest.fixture
def aws(monkeypatch):
    fake = FakeAws()
    monkeypatch.setattr(handler, "_client", lambda name: fake)
    monkeypatch.setenv("ORDERS_TABLE", "t")
    monkeypatch.setenv("TOPIC_ARN", "arn:aws:sns:us-east-1:000000000000:t")
    monkeypatch.setenv("INVOICES_BUCKET", "b")
    return fake


def post(body):
    return handler.handler({"httpMethod": "POST", "path": "/orders", "body": json.dumps(body)}, None)


def test_create_order_saves_publishes_and_invoices(aws):
    res = post({"customer": "Ahmed", "item": "Router", "amount": 1500})
    assert res["statusCode"] == 201
    order = json.loads(res["body"])
    assert order["status"] == "CREATED" and order["amount"] == 1500.0
    assert order["orderId"] in aws.items
    assert aws.published[0]["eventType"] == "OrderCreated"
    assert f"invoices/{order['orderId']}.txt" in aws.objects


@pytest.mark.parametrize("body", [
    {"item": "x", "amount": 1},
    {"customer": "a", "item": "x", "amount": 0},
    {"customer": "a", "item": "x", "amount": "10"},
    {"customer": " ", "item": "x", "amount": 5},
    {"customer": "a", "item": "x", "amount": True},
])
def test_invalid_orders_rejected(aws, body):
    res = post(body)
    assert res["statusCode"] == 400
    assert aws.items == {} and aws.published == []


def test_bad_json_rejected(aws):
    res = handler.handler({"httpMethod": "POST", "body": "{oops"}, None)
    assert res["statusCode"] == 400


def test_get_existing_order(aws):
    order = json.loads(post({"customer": "A", "item": "B", "amount": 9.99})["body"])
    res = handler.handler({"httpMethod": "GET", "pathParameters": {"orderId": order["orderId"]}}, None)
    assert res["statusCode"] == 200
    assert json.loads(res["body"])["customer"] == "A"


def test_get_missing_order_404(aws):
    res = handler.handler({"httpMethod": "GET", "pathParameters": {"orderId": "nope"}}, None)
    assert res["statusCode"] == 404


def test_unsupported_method(aws):
    assert handler.handler({"httpMethod": "DELETE", "path": "/orders"}, None)["statusCode"] == 405
