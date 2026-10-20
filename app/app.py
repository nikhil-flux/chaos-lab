"""Tiny three-role microservice app used as the target for chaos experiments.

One image, three roles, selected by the SERVICE environment variable:

    frontend   GET /checkout  ->  orders
    orders     GET /order     ->  inventory
    inventory  GET /reserve

Every role also exposes GET /healthz and GET /metrics (Prometheus format).
"""
import os
import random
import time
import uuid

import requests
from flask import Flask, Response, g, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)

# Metrics live at module level so create_app() can be called many times
# (tests do this) without registering duplicate collectors.
REQUESTS = Counter(
    "chaoslab_http_requests_total",
    "HTTP requests handled",
    ["component", "path", "status"],
)
LATENCY = Histogram(
    "chaoslab_http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["component", "path"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5),
)
UPSTREAM_ERRORS = Counter(
    "chaoslab_upstream_errors_total",
    "Failed calls to an upstream service",
    ["component", "reason"],
)

SKUS = ["sku-keyboard", "sku-mouse", "sku-monitor", "sku-dock", "sku-cable"]


class UpstreamError(Exception):
    """Raised when a downstream service cannot be reached or returns 5xx."""

    def __init__(self, status, reason):
        super().__init__(reason)
        self.status = status
        self.reason = reason


def create_app(service=None):
    service = service or os.getenv("SERVICE", "frontend")
    timeout = float(os.getenv("UPSTREAM_TIMEOUT", "2"))
    retries = int(os.getenv("UPSTREAM_RETRIES", "1"))
    orders_url = os.getenv("ORDERS_URL", "http://orders:8080")
    inventory_url = os.getenv("INVENTORY_URL", "http://inventory:8080")

    app = Flask(__name__)

    def call(url):
        """GET an upstream URL with a timeout and a small number of retries."""
        last = None
        for _ in range(retries + 1):
            try:
                resp = requests.get(url, timeout=timeout)
                if resp.status_code >= 500:
                    raise UpstreamError(502, "upstream_%d" % resp.status_code)
                return resp.json()
            except requests.exceptions.Timeout:
                last = UpstreamError(504, "timeout")
            except requests.exceptions.RequestException:
                last = UpstreamError(502, "connection")
            except UpstreamError as exc:
                last = exc
            UPSTREAM_ERRORS.labels(service, last.reason).inc()
        raise last

    @app.errorhandler(UpstreamError)
    def handle_upstream_error(exc):
        return jsonify(error=exc.reason, component=service), exc.status

    @app.before_request
    def start_timer():
        g.start = time.perf_counter()

    @app.after_request
    def record_metrics(resp):
        if request.path in ("/metrics", "/healthz"):
            return resp
        path = request.url_rule.rule if request.url_rule else "unmatched"
        REQUESTS.labels(service, path, str(resp.status_code)).inc()
        LATENCY.labels(service, path).observe(time.perf_counter() - g.start)
        return resp

    @app.get("/healthz")
    def healthz():
        return jsonify(status="ok", service=service)

    @app.get("/metrics")
    def metrics():
        return Response(generate_latest(), content_type=CONTENT_TYPE_LATEST)

    if service == "frontend":

        @app.get("/")
        def index():
            return jsonify(service=service, hint="GET /checkout")

        @app.get("/checkout")
        def checkout():
            order = call(orders_url + "/order")
            return jsonify(status="confirmed", order=order)

    elif service == "orders":

        @app.get("/order")
        def order():
            inventory = call(inventory_url + "/reserve")
            return jsonify(order_id=str(uuid.uuid4()), inventory=inventory)

    elif service == "inventory":

        @app.get("/reserve")
        def reserve():
            time.sleep(random.uniform(0.005, 0.03))
            return jsonify(sku=random.choice(SKUS), reserved=True)

    else:
        raise ValueError("unknown SERVICE %r" % service)

    return app


app = create_app()
