from fastapi.testclient import TestClient

from python_example.main import app

client = TestClient(app)


def test_root() -> None:
    r = client.get("/")
    assert r.status_code == 200
    assert r.json()["stack"] == "fastapi"


def test_health() -> None:
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"ok": True}
