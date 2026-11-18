"""Order service Lambda (API Gateway REST proxy integration).

POST /orders            {"customer": "...", "item": "...", "amount": 12.5}
    -> saves the order in DynamoDB, publishes an event to SNS, writes an invoice to S3
GET  /orders/{orderId}  -> returns the stored order

Configuration comes from environment variables set by Terraform.
APP_AWS_ENDPOINT points boto3 at Floci; leave it unset on real AWS.
"""
import json
import os
import uuid
from datetime import datetime, timezone

import boto3

_clients = {}


def _client(name):
    if name not in _clients:
        _clients[name] = boto3.client(name, endpoint_url=os.environ.get("APP_AWS_ENDPOINT") or None)
    return _clients[name]


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _validate(payload):
    errors = []
    for field in ("customer", "item"):
        if not isinstance(payload.get(field), str) or not payload[field].strip():
            errors.append(f"'{field}' is required")
    amount = payload.get("amount")
    if isinstance(amount, bool) or not isinstance(amount, (int, float)) or amount <= 0:
        errors.append("'amount' must be a positive number")
    return errors


def create_order(payload):
    errors = _validate(payload)
    if errors:
        return _response(400, {"errors": errors})

    order = {
        "orderId": str(uuid.uuid4()),
        "customer": payload["customer"].strip(),
        "item": payload["item"].strip(),
        "amount": round(float(payload["amount"]), 2),
        "status": "CREATED",
        "createdAt": datetime.now(timezone.utc).isoformat(),
    }

    _client("dynamodb").put_item(
        TableName=os.environ["ORDERS_TABLE"],
        Item={
            "orderId": {"S": order["orderId"]},
            "customer": {"S": order["customer"]},
            "item": {"S": order["item"]},
            "amount": {"N": str(order["amount"])},
            "status": {"S": order["status"]},
            "createdAt": {"S": order["createdAt"]},
        },
    )

    _client("sns").publish(
        TopicArn=os.environ["TOPIC_ARN"],
        Message=json.dumps({"eventType": "OrderCreated", "order": order}),
        MessageAttributes={"eventType": {"DataType": "String", "StringValue": "OrderCreated"}},
    )

    invoice = (
        f"INVOICE {order['orderId']}\n"
        f"Date:     {order['createdAt']}\n"
        f"Customer: {order['customer']}\n"
        f"Item:     {order['item']}\n"
        f"Amount:   {order['amount']:.2f}\n"
    )
    _client("s3").put_object(
        Bucket=os.environ["INVOICES_BUCKET"],
        Key=f"invoices/{order['orderId']}.txt",
        Body=invoice.encode(),
        ContentType="text/plain",
    )

    return _response(201, order)


def get_order(order_id):
    res = _client("dynamodb").get_item(
        TableName=os.environ["ORDERS_TABLE"], Key={"orderId": {"S": order_id}}
    )
    item = res.get("Item")
    if not item:
        return _response(404, {"error": f"order {order_id} not found"})
    order = {k: (float(v["N"]) if "N" in v else v.get("S")) for k, v in item.items()}
    return _response(200, order)


def handler(event, context):
    method = event.get("httpMethod", "")
    params = event.get("pathParameters") or {}

    if method == "POST" and not params.get("orderId"):
        try:
            payload = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return _response(400, {"errors": ["body must be valid JSON"]})
        if not isinstance(payload, dict):
            return _response(400, {"errors": ["body must be a JSON object"]})
        return create_order(payload)

    if method == "GET" and params.get("orderId"):
        return get_order(params["orderId"])

    return _response(405, {"error": f"{method} {event.get('path', '')} not supported"})
