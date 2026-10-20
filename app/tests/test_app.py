import pytest
import requests

from app import create_app


class FakeResponse:
    def __init__(self, payload, status_code=200):
        self._payload = payload
        self.status_code = status_code

    def json(self):
        return self._payload


@pytest.fixture
def inventory():
    return create_app("inventory").test_client()


@pytest.fixture
def orders():
    return create_app("orders").test_client()


@pytest.fixture
def frontend():
    return create_app("frontend").test_client()


def test_unknown_service_is_rejected():
    with pytest.raises(ValueError):
        create_app("billing")


@pytest.mark.parametrize("name", ["frontend", "orders", "inventory"])
def test_healthz(name):
    resp = create_app(name).test_client().get("/healthz")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok", "service": name}


def test_inventory_reserve(inventory):
    resp = inventory.get("/reserve")
    assert resp.status_code == 200
    assert resp.get_json()["reserved"] is True


def test_metrics_are_exposed(inventory):
    inventory.get("/reserve")
    body = inventory.get("/metrics").data.decode()
    assert "chaoslab_http_requests_total" in body
    assert 'path="/reserve"' in body


def test_orders_calls_inventory(orders, monkeypatch):
    monkeypatch.setattr(
        requests, "get", lambda url, timeout: FakeResponse({"reserved": True})
    )
    resp = orders.get("/order")
    assert resp.status_code == 200
    assert resp.get_json()["inventory"] == {"reserved": True}


def test_frontend_checkout(frontend, monkeypatch):
    monkeypatch.setattr(
        requests, "get", lambda url, timeout: FakeResponse({"order_id": "abc"})
    )
    resp = frontend.get("/checkout")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "confirmed"


def test_retry_hides_a_single_failure(orders, monkeypatch):
    calls = {"n": 0}

    def flaky(url, timeout):
        calls["n"] += 1
        if calls["n"] == 1:
            raise requests.exceptions.ConnectionError("pod went away")
        return FakeResponse({"reserved": True})

    monkeypatch.setattr(requests, "get", flaky)
    resp = orders.get("/order")
    assert resp.status_code == 200
    assert calls["n"] == 2


def test_connection_failure_returns_502(orders, monkeypatch):
    def down(url, timeout):
        raise requests.exceptions.ConnectionError("down")

    monkeypatch.setattr(requests, "get", down)
    resp = orders.get("/order")
    assert resp.status_code == 502
    assert resp.get_json()["error"] == "connection"


def test_timeout_returns_504(orders, monkeypatch):
    def slow(url, timeout):
        raise requests.exceptions.Timeout("slow")

    monkeypatch.setattr(requests, "get", slow)
    resp = orders.get("/order")
    assert resp.status_code == 504
    assert resp.get_json()["error"] == "timeout"


def test_upstream_5xx_returns_502(frontend, monkeypatch):
    monkeypatch.setattr(
        requests, "get", lambda url, timeout: FakeResponse({}, status_code=503)
    )
    resp = frontend.get("/checkout")
    assert resp.status_code == 502
    assert resp.get_json()["error"] == "upstream_503"
