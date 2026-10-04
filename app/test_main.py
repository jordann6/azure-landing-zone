"""Smoke tests for routes that need no database or Azure."""
import os
import sys
import types

# The container image installs the ODBC driver; a dev laptop may not have the
# system library, so stub the module for these database-free tests.
try:
    import pyodbc  # noqa: F401
except ImportError:
    fake = types.ModuleType("pyodbc")
    fake.Error = Exception
    fake.Connection = object

    def _no_db(*args, **kwargs):
        raise fake.Error("no database in unit tests")

    fake.connect = _no_db
    sys.modules["pyodbc"] = fake

os.environ["FRONT_DOOR_ID"] = "fd-123"
os.environ["REGION"] = "centralus"

from fastapi.testclient import TestClient  # noqa: E402

import main  # noqa: E402

client = TestClient(main.app)


def test_livez_needs_no_front_door_header():
    r = client.get("/livez")
    assert r.status_code == 200 and r.json()["region"] == "centralus"


def test_requests_without_front_door_header_are_rejected():
    assert client.get("/api/orders").status_code == 403
    assert client.get("/api/orders", headers={"X-Azure-FDID": "wrong"}).status_code == 403


def test_front_door_header_passes_and_region_is_stamped():
    r = client.get("/config.js", headers={"X-Azure-FDID": "fd-123"})
    assert r.status_code == 200
    assert r.headers["X-Served-By-Region"] == "centralus"
    assert '"region": "centralus"' in r.text


def test_me_reports_sign_in_not_configured():
    r = client.get("/api/me", headers={"X-Azure-FDID": "fd-123"})
    assert r.status_code == 501


def test_order_validation_rejects_bad_quantity():
    r = client.post("/api/orders", headers={"X-Azure-FDID": "fd-123"},
                    json={"pharmacy": "Main St", "item": "Amoxicillin", "quantity": 0})
    assert r.status_code == 422
