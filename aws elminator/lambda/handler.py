import json
import os


def handler(event, context):
    name = (event or {}).get("name", "world")
    return {
        "statusCode": 200,
        "body": json.dumps({
            "hello": name,
            "runtime": os.environ.get("AWS_EXECUTION_ENV", "unknown"),
            "function": getattr(context, "function_name", "unknown"),
        }),
    }
