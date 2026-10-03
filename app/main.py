"""Member portal API.

Runs in Azure Container Apps in two regions behind Front Door Premium. Talks to
Azure SQL through the failover group listener with its managed identity (no
password), validates Entra External ID tokens for member sign-in, and refuses
requests that did not come through this Front Door profile.
"""

import logging
import os
import threading
import time
from functools import lru_cache

import jwt
import pyodbc
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse
from pydantic import BaseModel, Field

REGION = os.environ.get("REGION", "local")
SQL_SERVER = os.environ.get("SQL_SERVER", "")
SQL_DATABASE = os.environ.get("SQL_DATABASE", "portal")
AZURE_CLIENT_ID = os.environ.get("AZURE_CLIENT_ID", "")
FRONT_DOOR_ID = os.environ.get("FRONT_DOOR_ID", "")
EXTERNAL_ID_TENANT_ID = os.environ.get("EXTERNAL_ID_TENANT_ID", "")
EXTERNAL_ID_SUBDOMAIN = os.environ.get("EXTERNAL_ID_SUBDOMAIN", "")
EXTERNAL_ID_CLIENT_ID = os.environ.get("EXTERNAL_ID_CLIENT_ID", "")

if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor()

log = logging.getLogger("portal")
logging.basicConfig(level=logging.INFO)

app = FastAPI(title="Member Portal", docs_url=None, redoc_url=None)

# Paths that must work without the Front Door header: Container Apps probes.
UNGUARDED = {"/livez"}


@app.middleware("http")
async def require_front_door(request: Request, call_next):
    """Reject anything that did not arrive through our Front Door profile.

    The environment already has no public ingress; this is defense in depth in
    case the app is ever exposed another way. Front Door stamps every request
    with X-Azure-FDID, the profile's unique ID.
    """
    if FRONT_DOOR_ID and request.url.path not in UNGUARDED:
        if request.headers.get("x-azure-fdid") != FRONT_DOOR_ID:
            return JSONResponse({"error": "forbidden"}, status_code=403)
    response = await call_next(request)
    response.headers["X-Served-By-Region"] = REGION
    return response


# ── Database ────────────────────────────────────────────────────────────────

def connect() -> pyodbc.Connection:
    """Connect with the user-assigned managed identity. No password exists."""
    return pyodbc.connect(
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server=tcp:{SQL_SERVER},1433;Database={SQL_DATABASE};"
        f"Authentication=ActiveDirectoryMsi;UID={AZURE_CLIENT_ID};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=15;",
        timeout=15,
    )


SCHEMA = """
IF OBJECT_ID('dbo.orders', 'U') IS NULL
CREATE TABLE dbo.orders (
    id         INT IDENTITY(1,1) PRIMARY KEY,
    pharmacy   NVARCHAR(100) NOT NULL,
    item       NVARCHAR(200) NOT NULL,
    quantity   INT           NOT NULL CHECK (quantity > 0),
    region     NVARCHAR(32)  NOT NULL,
    created_at DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
"""


def ensure_schema() -> None:
    """Create the table if needed, retrying until the database is reachable."""
    for attempt in range(1, 61):
        try:
            with connect() as conn:
                conn.execute(SCHEMA)
                conn.commit()
            log.info("schema ready")
            return
        except pyodbc.Error as exc:
            log.warning("schema attempt %s failed: %s", attempt, exc)
            time.sleep(10)


@app.on_event("startup")
def start_schema_thread() -> None:
    # In the background, so the server starts listening immediately and the
    # Container Apps probes (/livez) pass while the database comes up. A first
    # deploy showed that blocking startup on SQL gets the container killed by
    # its liveness probe before it ever serves a request.
    if SQL_SERVER:
        threading.Thread(target=ensure_schema, daemon=True).start()


# ── Health ──────────────────────────────────────────────────────────────────

@app.get("/livez")
def livez():
    """Process is up. Used by Container Apps probes; no dependencies."""
    return {"ok": True, "region": REGION}


@app.get("/health")
def health():
    """Front Door's probe and the availability test.

    503 if the database is unreachable, which takes this region out of Front
    Door's rotation. Reports which SQL server answered and whether it is
    writable, so a failover drill can watch the data tier move.
    """
    try:
        with connect() as conn:
            row = conn.execute(
                "SELECT @@SERVERNAME, CAST(DATABASEPROPERTYEX(DB_NAME(), 'Updateability') AS NVARCHAR(32))"
            ).fetchone()
        return {"status": "ok", "region": REGION, "sql_server": row[0], "updateability": row[1]}
    except pyodbc.Error as exc:
        log.error("health check failed: %s", exc)
        return JSONResponse({"status": "degraded", "region": REGION}, status_code=503)


# ── Orders ──────────────────────────────────────────────────────────────────

class OrderIn(BaseModel):
    pharmacy: str = Field(min_length=1, max_length=100)
    item: str = Field(min_length=1, max_length=200)
    quantity: int = Field(gt=0, le=10000)


@app.get("/api/orders")
def list_orders(limit: int = 50):
    limit = max(1, min(limit, 200))
    with connect() as conn:
        rows = conn.execute(
            "SELECT TOP (?) id, pharmacy, item, quantity, region, created_at "
            "FROM dbo.orders ORDER BY id DESC",
            limit,
        ).fetchall()
    return [
        {"id": r[0], "pharmacy": r[1], "item": r[2], "quantity": r[3],
         "region": r[4], "created_at": r[5].isoformat()}
        for r in rows
    ]


@app.get("/api/orders/{order_id}")
def get_order(order_id: int):
    with connect() as conn:
        row = conn.execute(
            "SELECT id, pharmacy, item, quantity, region, created_at FROM dbo.orders WHERE id = ?",
            order_id,
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="not found")
    return {"id": row[0], "pharmacy": row[1], "item": row[2], "quantity": row[3],
            "region": row[4], "created_at": row[5].isoformat()}


@app.post("/api/orders", status_code=201)
def create_order(order: OrderIn):
    try:
        with connect() as conn:
            row = conn.execute(
                "INSERT INTO dbo.orders (pharmacy, item, quantity, region) "
                "OUTPUT INSERTED.id VALUES (?, ?, ?, ?)",
                order.pharmacy, order.item, order.quantity, REGION,
            ).fetchone()
            conn.commit()
    except pyodbc.Error as exc:
        # During a failover the listener briefly points nowhere writable.
        log.warning("write failed: %s", exc)
        raise HTTPException(status_code=503, detail="database unavailable, retry")
    return {"id": row[0], "region": REGION}


@app.get("/api/reports/daily")
def daily_report():
    """Aggregate counts only (no member detail). Pulled by the Logic App."""
    with connect() as conn:
        rows = conn.execute(
            "SELECT region, COUNT(*), SUM(quantity) FROM dbo.orders "
            "WHERE created_at > DATEADD(day, -1, SYSUTCDATETIME()) GROUP BY region"
        ).fetchall()
    return {"window": "24h", "by_region": [
        {"region": r[0], "orders": r[1], "units": int(r[2] or 0)} for r in rows
    ]}


# ── Member sign-in (Entra External ID) ──────────────────────────────────────

@lru_cache(maxsize=1)
def jwks_client() -> jwt.PyJWKClient:
    return jwt.PyJWKClient(
        f"https://{EXTERNAL_ID_SUBDOMAIN}.ciamlogin.com/{EXTERNAL_ID_TENANT_ID}/discovery/v2.0/keys"
    )


@app.get("/api/me")
def me(request: Request):
    """Validate the member's ID token from External ID and return who they are."""
    if not (EXTERNAL_ID_TENANT_ID and EXTERNAL_ID_CLIENT_ID):
        raise HTTPException(status_code=501, detail="sign-in not configured")
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = auth.split(" ", 1)[1]
    try:
        key = jwks_client().get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            audience=EXTERNAL_ID_CLIENT_ID,
            issuer=f"https://{EXTERNAL_ID_TENANT_ID}.ciamlogin.com/{EXTERNAL_ID_TENANT_ID}/v2.0",
        )
    except jwt.PyJWTError as exc:
        raise HTTPException(status_code=401, detail=f"invalid token: {exc}")
    return {"name": claims.get("name"), "email": claims.get("email") or claims.get("preferred_username"),
            "oid": claims.get("oid"), "served_by": REGION}


# ── Static sign-in page ─────────────────────────────────────────────────────

STATIC = os.path.join(os.path.dirname(__file__), "static")


@app.get("/config.js", response_class=PlainTextResponse)
def config_js():
    """Public sign-in settings for the browser (no secrets)."""
    authority = f"https://{EXTERNAL_ID_SUBDOMAIN}.ciamlogin.com/" if EXTERNAL_ID_SUBDOMAIN else ""
    return (
        "window.PORTAL_CONFIG = "
        f'{{"clientId": "{EXTERNAL_ID_CLIENT_ID}", "authority": "{authority}", "region": "{REGION}"}};'
    )


@app.get("/")
def index():
    return FileResponse(os.path.join(STATIC, "index.html"))
