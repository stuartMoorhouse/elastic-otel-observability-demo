#!/bin/bash
# ==============================================================================
# EC2 Userdata Bootstrap — Elastic Observability OTel Demo
# ==============================================================================
# Processed by Terraform templatefile(). Bash variables must be double-dollar
# escaped so Terraform passes them through to the shell.
#
# Terraform-injected variables:
#   elasticsearch_url, api_key
# ==============================================================================
set -euxo pipefail

exec > >(tee /var/log/userdata.log) 2>&1
echo "=== Userdata script started at $(date -u) ==="

# ==============================================================================
# 1. System setup
# ==============================================================================
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y \
  python3 python3-pip python3-venv \
  postgresql postgresql-contrib \
  redis-server \
  curl jq netcat-openbsd \
  wget tar

# ==============================================================================
# 2. Create app user and directories
# ==============================================================================
useradd --system --no-create-home --shell /usr/sbin/nologin appuser || true

mkdir -p /opt/app/{frontend/templates,frontend/static,api,loadgen,config}
mkdir -p /var/log/app

chown -R appuser:appuser /opt/app /var/log/app
chmod 755 /var/log/app

# ==============================================================================
# 3. PostgreSQL setup
# ==============================================================================
systemctl start postgresql
systemctl enable postgresql

sudo -u postgres psql <<'PGEOF'
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'ecommerce') THEN
        CREATE ROLE ecommerce WITH LOGIN PASSWORD 'ecommerce';
    END IF;
END $$;

SELECT 'CREATE DATABASE ecommerce OWNER ecommerce'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ecommerce')\gexec

GRANT ALL PRIVILEGES ON DATABASE ecommerce TO ecommerce;
PGEOF

# Allow password auth for local connections
PG_HBA=$(find /etc/postgresql -name pg_hba.conf | head -1)
if grep -q "local.*all.*all.*peer" "$PG_HBA"; then
    sed -i 's/local\s*all\s*all\s*peer/local   all             all                                     md5/' "$PG_HBA"
    systemctl restart postgresql
fi

# ==============================================================================
# 4. Redis setup
# ==============================================================================
systemctl start redis-server
systemctl enable redis-server

# ==============================================================================
# 5. Install otelcol-contrib
# ==============================================================================
OTELCOL_VERSION="0.96.0"
cd /tmp
curl -L -o otelcol-contrib.tar.gz \
  "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$${OTELCOL_VERSION}/otelcol-contrib_$${OTELCOL_VERSION}_linux_amd64.tar.gz"
tar xzf otelcol-contrib.tar.gz
mv otelcol-contrib /usr/local/bin/otelcol-contrib
chmod +x /usr/local/bin/otelcol-contrib
rm -f otelcol-contrib.tar.gz
cd /

# ==============================================================================
# 6. Deploy application code
# ==============================================================================

# ---------- API: database.py ----------
cat > /opt/app/api/database.py <<'PYEOF'
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker, declarative_base

DATABASE_URL = "postgresql://ecommerce:ecommerce@localhost:5432/ecommerce"

engine = create_engine(
    DATABASE_URL,
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


SAMPLE_PRODUCTS = [
    # Electronics
    {
        "name": "Wireless Bluetooth Headphones",
        "description": "Premium noise-cancelling over-ear headphones with 30-hour battery life and Hi-Res audio support.",
        "price": 79.99,
        "image_url": "https://picsum.photos/seed/headphones/400/400",
        "category": "Electronics",
        "stock": 150,
    },
    {
        "name": "USB-C Fast Charger",
        "description": "65W GaN charger with dual USB-C ports. Compatible with laptops, tablets, and phones.",
        "price": 34.99,
        "image_url": "https://picsum.photos/seed/charger/400/400",
        "category": "Electronics",
        "stock": 300,
    },
    {
        "name": "Mechanical Keyboard",
        "description": "Compact 75% layout with hot-swappable switches, RGB backlighting, and aluminum frame.",
        "price": 119.99,
        "image_url": "https://picsum.photos/seed/keyboard/400/400",
        "category": "Electronics",
        "stock": 85,
    },
    # Clothing
    {
        "name": "Classic Cotton T-Shirt",
        "description": "Soft 100% organic cotton crew-neck tee. Pre-shrunk and available in 12 colors.",
        "price": 24.99,
        "image_url": "https://picsum.photos/seed/tshirt/400/400",
        "category": "Clothing",
        "stock": 500,
    },
    {
        "name": "Slim Fit Jeans",
        "description": "Stretch denim jeans with a modern slim fit. Dark indigo wash with subtle fading.",
        "price": 59.99,
        "image_url": "https://picsum.photos/seed/jeans/400/400",
        "category": "Clothing",
        "stock": 200,
    },
    {
        "name": "Wool Blend Sweater",
        "description": "Cozy merino wool blend pullover. Perfect for layering in cooler weather.",
        "price": 69.99,
        "image_url": "https://picsum.photos/seed/sweater/400/400",
        "category": "Clothing",
        "stock": 120,
    },
    # Books
    {
        "name": "The Art of Clean Code",
        "description": "A practical guide to writing maintainable, readable, and efficient code. 2nd edition.",
        "price": 39.99,
        "image_url": "https://picsum.photos/seed/codebook/400/400",
        "category": "Books",
        "stock": 75,
    },
    {
        "name": "Data Structures Illustrated",
        "description": "Visual approach to understanding data structures and algorithms with real-world examples.",
        "price": 44.99,
        "image_url": "https://picsum.photos/seed/dsbook/400/400",
        "category": "Books",
        "stock": 60,
    },
    {
        "name": "Observability Engineering",
        "description": "Comprehensive guide to building observable systems with metrics, logs, and traces.",
        "price": 49.99,
        "image_url": "https://picsum.photos/seed/obook/400/400",
        "category": "Books",
        "stock": 90,
    },
    # Home
    {
        "name": "Ceramic Coffee Mug Set",
        "description": "Set of 4 handcrafted ceramic mugs. Microwave and dishwasher safe. 12oz capacity.",
        "price": 29.99,
        "image_url": "https://picsum.photos/seed/mugs/400/400",
        "category": "Home",
        "stock": 180,
    },
    {
        "name": "LED Desk Lamp",
        "description": "Adjustable LED lamp with 5 brightness levels and 3 color temperatures. USB charging port.",
        "price": 42.99,
        "image_url": "https://picsum.photos/seed/lamp/400/400",
        "category": "Home",
        "stock": 95,
    },
    {
        "name": "Bamboo Cutting Board",
        "description": "Extra-large organic bamboo cutting board with juice grooves and carrying handles.",
        "price": 27.99,
        "image_url": "https://picsum.photos/seed/cuttingboard/400/400",
        "category": "Home",
        "stock": 140,
    },
]


def init_db():
    """Create all tables and seed sample products if the products table is empty."""
    from models import Product, Order, OrderItem, CartItem  # noqa: F401

    Base.metadata.create_all(bind=engine)

    db = SessionLocal()
    try:
        count = db.query(Product).count()
        if count == 0:
            for p in SAMPLE_PRODUCTS:
                db.add(Product(**p))
            db.commit()
    finally:
        db.close()
PYEOF

# ---------- API: models.py ----------
cat > /opt/app/api/models.py <<'PYEOF'
from sqlalchemy import Column, Integer, String, Float, DateTime, ForeignKey, Text
from sqlalchemy.orm import relationship
from datetime import datetime, timezone

from database import Base


class Product(Base):
    __tablename__ = "products"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(255), nullable=False)
    description = Column(Text, nullable=True)
    price = Column(Float, nullable=False)
    image_url = Column(String(512), nullable=True)
    category = Column(String(100), nullable=False, index=True)
    stock = Column(Integer, nullable=False, default=0)

    def to_dict(self):
        return {
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "price": self.price,
            "image_url": self.image_url,
            "category": self.category,
            "stock": self.stock,
        }


class Order(Base):
    __tablename__ = "orders"

    id = Column(Integer, primary_key=True, index=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    total = Column(Float, nullable=False)
    status = Column(String(50), nullable=False, default="pending")

    items = relationship("OrderItem", back_populates="order", lazy="joined")

    def to_dict(self):
        return {
            "id": self.id,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "total": self.total,
            "status": self.status,
            "items": [item.to_dict() for item in self.items],
        }


class OrderItem(Base):
    __tablename__ = "order_items"

    id = Column(Integer, primary_key=True, index=True)
    order_id = Column(Integer, ForeignKey("orders.id"), nullable=False)
    product_id = Column(Integer, ForeignKey("products.id"), nullable=False)
    quantity = Column(Integer, nullable=False)
    price = Column(Float, nullable=False)

    order = relationship("Order", back_populates="items")
    product = relationship("Product")

    def to_dict(self):
        return {
            "id": self.id,
            "order_id": self.order_id,
            "product_id": self.product_id,
            "quantity": self.quantity,
            "price": self.price,
        }


class CartItem(Base):
    __tablename__ = "cart_items"

    id = Column(Integer, primary_key=True, index=True)
    session_id = Column(String(255), nullable=False, index=True)
    product_id = Column(Integer, ForeignKey("products.id"), nullable=False)
    quantity = Column(Integer, nullable=False, default=1)

    product = relationship("Product")

    def to_dict(self):
        return {
            "id": self.id,
            "session_id": self.session_id,
            "product_id": self.product_id,
            "quantity": self.quantity,
            "product": self.product.to_dict() if self.product else None,
        }
PYEOF

# ---------- API: chaos.py ----------
cat > /opt/app/api/chaos.py <<'PYEOF'
import asyncio
import logging
import math
import os
import random
import tempfile
import threading
import time
from dataclasses import dataclass, field

from fastapi import HTTPException, Request
from opentelemetry import trace
from starlette.middleware.base import BaseHTTPMiddleware

logger = logging.getLogger("api")
tracer = trace.get_tracer("chaos-engineering")


@dataclass
class ChaosState:
    """In-memory state for all 10 chaos engineering scenarios."""

    # 1. Slow Database Queries — extra delay in ms (0-5000)
    slow_db_ms: int = 0

    # 2. High Error Rate (5xx) — percentage chance 0-100
    error_rate_pct: int = 0

    # 3. Memory Leak — toggle
    memory_leak_enabled: bool = False
    _leaked_data: list = field(default_factory=list, repr=False)

    # 4. CPU Saturation — number of busy-wait threads (0-8)
    cpu_threads: int = 0
    _cpu_thread_handles: list = field(default_factory=list, repr=False)
    _cpu_stop_event: threading.Event = field(default_factory=threading.Event, repr=False)

    # 5. Downstream Dependency Timeout — sleep in seconds (0-30)
    downstream_timeout_s: int = 0

    # 6. DB Connection Pool Exhaustion — pool size (1-20, default managed externally)
    db_pool_size: int = 0  # 0 means "not active / use default"

    # 7. Log Flooding — extra log lines per request (0-1000)
    log_flood_lines: int = 0

    # 8. N+1 Query Problem — toggle
    n_plus_one_enabled: bool = False

    # 9. Disk I/O Saturation — MB to write per request (0-50)
    disk_io_mb: int = 0

    # 10. Cascading Latency (Retry Storm) — toggle
    retry_storm_enabled: bool = False

    def to_dict(self):
        return {
            "slow_db_ms": self.slow_db_ms,
            "error_rate_pct": self.error_rate_pct,
            "memory_leak_enabled": self.memory_leak_enabled,
            "memory_leak_size_mb": round(
                len(self._leaked_data) * 0.001, 2
            ),
            "cpu_threads": self.cpu_threads,
            "downstream_timeout_s": self.downstream_timeout_s,
            "db_pool_size": self.db_pool_size,
            "log_flood_lines": self.log_flood_lines,
            "n_plus_one_enabled": self.n_plus_one_enabled,
            "disk_io_mb": self.disk_io_mb,
            "retry_storm_enabled": self.retry_storm_enabled,
        }

    def reset(self):
        self.slow_db_ms = 0
        self.error_rate_pct = 0
        self.memory_leak_enabled = False
        self._leaked_data.clear()
        self.stop_cpu_threads()
        self.cpu_threads = 0
        self.downstream_timeout_s = 0
        self.db_pool_size = 0
        self.log_flood_lines = 0
        self.n_plus_one_enabled = False
        self.disk_io_mb = 0
        self.retry_storm_enabled = False

    # --- CPU saturation helpers ---

    def _cpu_busy_loop(self, stop_event: threading.Event):
        """Busy-wait loop that burns CPU until stopped."""
        while not stop_event.is_set():
            _ = math.factorial(500)

    def start_cpu_threads(self, count: int):
        self.stop_cpu_threads()
        self.cpu_threads = count
        self._cpu_stop_event.clear()
        for _ in range(count):
            t = threading.Thread(target=self._cpu_busy_loop, args=(self._cpu_stop_event,), daemon=True)
            t.start()
            self._cpu_thread_handles.append(t)

    def stop_cpu_threads(self):
        self._cpu_stop_event.set()
        for t in self._cpu_thread_handles:
            t.join(timeout=2)
        self._cpu_thread_handles.clear()
        self._cpu_stop_event.clear()

    # --- Per-request chaos application ---

    async def apply_pre_request(self):
        """Apply chaos effects that should happen before request processing."""
        with tracer.start_as_current_span("chaos.pre_request") as span:

            # 2. High Error Rate
            if self.error_rate_pct > 0:
                if random.randint(1, 100) <= self.error_rate_pct:
                    span.set_attribute("chaos.error_injected", True)
                    logger.warning("Chaos: injecting 500 error (rate=%d%%)", self.error_rate_pct)
                    raise HTTPException(status_code=500, detail="Chaos: injected server error")

            # 3. Memory Leak
            if self.memory_leak_enabled:
                chunk = "X" * 1024  # 1KB per request
                self._leaked_data.append(chunk)
                span.set_attribute("chaos.memory_leak_entries", len(self._leaked_data))

            # 7. Log Flooding
            if self.log_flood_lines > 0:
                span.set_attribute("chaos.log_flood_lines", self.log_flood_lines)
                for i in range(self.log_flood_lines):
                    logger.info(
                        "Chaos log flood line %d/%d — This is intentional noise generated by the chaos engineering module.",
                        i + 1,
                        self.log_flood_lines,
                    )

    async def apply_slow_db(self):
        """Inject latency before database calls."""
        if self.slow_db_ms > 0:
            with tracer.start_as_current_span("chaos.slow_db") as span:
                delay = self.slow_db_ms / 1000.0
                span.set_attribute("chaos.delay_ms", self.slow_db_ms)
                logger.info("Chaos: adding %dms DB delay", self.slow_db_ms)
                await asyncio.sleep(delay)

    async def apply_downstream_timeout(self):
        """Simulate a slow downstream dependency."""
        if self.downstream_timeout_s > 0:
            with tracer.start_as_current_span("chaos.downstream_timeout") as span:
                span.set_attribute("chaos.timeout_s", self.downstream_timeout_s)
                logger.info("Chaos: simulating downstream timeout of %ds", self.downstream_timeout_s)
                await asyncio.sleep(self.downstream_timeout_s)

    async def apply_disk_io(self):
        """Write temporary files to saturate disk I/O."""
        if self.disk_io_mb > 0:
            with tracer.start_as_current_span("chaos.disk_io") as span:
                span.set_attribute("chaos.disk_io_mb", self.disk_io_mb)
                logger.info("Chaos: writing %dMB to disk", self.disk_io_mb)
                data = b"0" * (1024 * 1024)  # 1MB chunk
                for _ in range(self.disk_io_mb):
                    fd, path = tempfile.mkstemp(prefix="chaos_io_")
                    try:
                        os.write(fd, data)
                    finally:
                        os.close(fd)
                        os.unlink(path)

    async def apply_retry_storm(self):
        """Simulate cascading latency via internal retry loop with backoff."""
        if self.retry_storm_enabled:
            with tracer.start_as_current_span("chaos.retry_storm") as span:
                retries = 5
                span.set_attribute("chaos.retry_count", retries)
                logger.info("Chaos: starting retry storm with %d retries", retries)
                for attempt in range(retries):
                    delay = min(0.1 * (2 ** attempt), 3.0)
                    with tracer.start_as_current_span(f"chaos.retry_attempt_{attempt}") as retry_span:
                        retry_span.set_attribute("chaos.attempt", attempt)
                        retry_span.set_attribute("chaos.backoff_s", delay)
                        await asyncio.sleep(delay)


# Global singleton
chaos_state = ChaosState()


class ChaosMiddleware(BaseHTTPMiddleware):
    """Middleware that applies chaos effects to every request."""

    async def dispatch(self, request: Request, call_next):
        # Skip chaos for the chaos control endpoints themselves
        path = request.url.path
        if path.startswith("/api/chaos") or path == "/api/health":
            return await call_next(request)

        # Apply pre-request chaos
        await chaos_state.apply_pre_request()

        # Apply per-request disk I/O
        await chaos_state.apply_disk_io()

        # Apply downstream timeout simulation
        await chaos_state.apply_downstream_timeout()

        # Apply retry storm
        await chaos_state.apply_retry_storm()

        response = await call_next(request)
        return response
PYEOF

# ---------- API: main.py ----------
cat > /opt/app/api/main.py <<'PYEOF'
import json
import logging
import os
import sys
from contextlib import asynccontextmanager

import redis
import uvicorn
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from opentelemetry import trace
from pydantic import BaseModel
from sqlalchemy.orm import Session

from chaos import ChaosMiddleware, chaos_state
from database import SessionLocal, get_db, init_db, engine
from models import CartItem, Order, OrderItem, Product

# ---------------------------------------------------------------------------
# Structured JSON logging with trace correlation
# ---------------------------------------------------------------------------

class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_record = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "module": record.module,
            "function": record.funcName,
            "line": record.lineno,
        }
        # Add trace context if available
        span = trace.get_current_span()
        ctx = span.get_span_context()
        if ctx and ctx.trace_id:
            log_record["trace_id"] = format(ctx.trace_id, "032x")
            log_record["span_id"] = format(ctx.span_id, "016x")
        else:
            log_record["trace_id"] = "0" * 32
            log_record["span_id"] = "0" * 16
        if record.exc_info and record.exc_info[0] is not None:
            log_record["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_record)


def setup_logging():
    logger = logging.getLogger("api")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()

    # File handler
    log_dir = "/var/log/app"
    os.makedirs(log_dir, exist_ok=True)
    fh = logging.FileHandler(os.path.join(log_dir, "api.log"))
    fh.setFormatter(JSONFormatter())
    logger.addHandler(fh)

    # Also log to stdout for convenience
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(JSONFormatter())
    logger.addHandler(sh)

    return logger


logger = setup_logging()
tracer = trace.get_tracer("ecommerce-api")

# ---------------------------------------------------------------------------
# Redis client
# ---------------------------------------------------------------------------

redis_client = redis.Redis.from_url("redis://localhost:6379/0", decode_responses=True)

CACHE_TTL = 60  # seconds

# ---------------------------------------------------------------------------
# Pydantic request models
# ---------------------------------------------------------------------------

class AddToCartRequest(BaseModel):
    product_id: int
    quantity: int = 1


class CheckoutRequest(BaseModel):
    name: str = "Guest"
    email: str = "guest@example.com"


class ChaosConfig(BaseModel):
    value: int | float | bool | None = None

# ---------------------------------------------------------------------------
# Application lifespan
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting ecommerce API — initializing database")
    init_db()
    yield
    logger.info("Shutting down ecommerce API")
    chaos_state.reset()


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------

app = FastAPI(title="E-Commerce API", version="1.0.0", lifespan=lifespan)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Chaos middleware
app.add_middleware(ChaosMiddleware)

# Default session ID (single-user demo)
DEFAULT_SESSION = "demo-session"

# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/api/health")
async def health():
    return {"status": "healthy"}

# ---------------------------------------------------------------------------
# Products
# ---------------------------------------------------------------------------

@app.get("/api/products")
async def list_products(db: Session = Depends(get_db)):
    with tracer.start_as_current_span("list_products"):
        # Check Redis cache
        cached = None
        try:
            cached = redis_client.get("products:all")
        except Exception:
            logger.warning("Redis unavailable, skipping cache read")

        if cached:
            logger.info("Returning cached product list")
            return json.loads(cached)

        # Apply chaos: slow DB
        await chaos_state.apply_slow_db()

        # N+1 chaos
        if chaos_state.n_plus_one_enabled:
            with tracer.start_as_current_span("chaos.n_plus_one_query"):
                ids = [row[0] for row in db.query(Product.id).all()]
                products = []
                for pid in ids:
                    p = db.query(Product).filter(Product.id == pid).first()
                    if p:
                        products.append(p.to_dict())
        else:
            products = [p.to_dict() for p in db.query(Product).all()]

        # Cache result
        try:
            redis_client.setex("products:all", CACHE_TTL, json.dumps(products))
        except Exception:
            logger.warning("Redis unavailable, skipping cache write")

        logger.info("Listed %d products", len(products))
        return products


@app.get("/api/products/{product_id}")
async def get_product(product_id: int, db: Session = Depends(get_db)):
    with tracer.start_as_current_span("get_product") as span:
        span.set_attribute("product.id", product_id)
        await chaos_state.apply_slow_db()

        product = db.query(Product).filter(Product.id == product_id).first()
        if not product:
            raise HTTPException(status_code=404, detail="Product not found")

        logger.info("Retrieved product %d: %s", product_id, product.name)
        return product.to_dict()

# ---------------------------------------------------------------------------
# Cart
# ---------------------------------------------------------------------------

@app.post("/api/cart/add")
async def add_to_cart(req: AddToCartRequest, db: Session = Depends(get_db)):
    with tracer.start_as_current_span("add_to_cart") as span:
        span.set_attribute("product.id", req.product_id)
        span.set_attribute("cart.quantity", req.quantity)
        await chaos_state.apply_slow_db()

        product = db.query(Product).filter(Product.id == req.product_id).first()
        if not product:
            raise HTTPException(status_code=404, detail="Product not found")

        # Check if already in cart
        existing = (
            db.query(CartItem)
            .filter(CartItem.session_id == DEFAULT_SESSION, CartItem.product_id == req.product_id)
            .first()
        )
        if existing:
            existing.quantity += req.quantity
        else:
            item = CartItem(
                session_id=DEFAULT_SESSION,
                product_id=req.product_id,
                quantity=req.quantity,
            )
            db.add(item)

        db.commit()
        logger.info("Added product %d (qty %d) to cart", req.product_id, req.quantity)
        return {"message": "Added to cart", "product_id": req.product_id, "quantity": req.quantity}


@app.get("/api/cart")
async def view_cart(db: Session = Depends(get_db)):
    with tracer.start_as_current_span("view_cart"):
        await chaos_state.apply_slow_db()

        if chaos_state.n_plus_one_enabled:
            with tracer.start_as_current_span("chaos.n_plus_one_cart"):
                item_ids = [
                    row[0]
                    for row in db.query(CartItem.id)
                    .filter(CartItem.session_id == DEFAULT_SESSION)
                    .all()
                ]
                items = []
                for cid in item_ids:
                    ci = db.query(CartItem).filter(CartItem.id == cid).first()
                    if ci:
                        items.append(ci.to_dict())
        else:
            items = [
                ci.to_dict()
                for ci in db.query(CartItem)
                .filter(CartItem.session_id == DEFAULT_SESSION)
                .all()
            ]

        total = sum((item.get("product", {}) or {}).get("price", 0) * item["quantity"] for item in items)
        logger.info("Cart viewed — %d items, total=%.2f", len(items), total)
        return {"items": items, "total": round(total, 2)}

# ---------------------------------------------------------------------------
# Checkout / Orders
# ---------------------------------------------------------------------------

@app.post("/api/checkout")
async def checkout(req: CheckoutRequest = None, db: Session = Depends(get_db)):
    with tracer.start_as_current_span("checkout") as span:
        await chaos_state.apply_slow_db()

        cart_items = (
            db.query(CartItem).filter(CartItem.session_id == DEFAULT_SESSION).all()
        )
        if not cart_items:
            raise HTTPException(status_code=400, detail="Cart is empty")

        total = 0.0
        order_items = []
        for ci in cart_items:
            product = db.query(Product).filter(Product.id == ci.product_id).first()
            if product:
                line_total = product.price * ci.quantity
                total += line_total
                order_items.append(
                    OrderItem(
                        product_id=ci.product_id,
                        quantity=ci.quantity,
                        price=product.price,
                    )
                )
                # Reduce stock
                product.stock = max(0, product.stock - ci.quantity)

        order = Order(total=round(total, 2), status="confirmed")
        order.items = order_items
        db.add(order)

        # Clear cart
        db.query(CartItem).filter(CartItem.session_id == DEFAULT_SESSION).delete()
        db.commit()
        db.refresh(order)

        span.set_attribute("order.id", order.id)
        span.set_attribute("order.total", order.total)
        logger.info("Order %d placed — total=%.2f, items=%d", order.id, order.total, len(order_items))

        # Invalidate product cache since stock changed
        try:
            redis_client.delete("products:all")
        except Exception:
            pass

        return order.to_dict()


@app.get("/api/orders")
async def list_orders(db: Session = Depends(get_db)):
    with tracer.start_as_current_span("list_orders"):
        await chaos_state.apply_slow_db()
        orders = db.query(Order).order_by(Order.created_at.desc()).all()
        logger.info("Listed %d orders", len(orders))
        return [o.to_dict() for o in orders]

# ---------------------------------------------------------------------------
# Chaos control endpoints
# ---------------------------------------------------------------------------

@app.get("/api/chaos/status")
async def chaos_status():
    return chaos_state.to_dict()


@app.post("/api/chaos/reset")
async def chaos_reset():
    chaos_state.reset()
    logger.info("Chaos: all scenarios reset")
    return {"message": "All chaos scenarios reset", "state": chaos_state.to_dict()}


@app.post("/api/chaos/{scenario}")
async def chaos_configure(scenario: str, config: ChaosConfig):
    value = config.value

    if scenario == "slow-db":
        chaos_state.slow_db_ms = max(0, min(5000, int(value or 0)))
        logger.info("Chaos: slow_db_ms set to %d", chaos_state.slow_db_ms)

    elif scenario == "error-rate":
        chaos_state.error_rate_pct = max(0, min(100, int(value or 0)))
        logger.info("Chaos: error_rate_pct set to %d", chaos_state.error_rate_pct)

    elif scenario == "memory-leak":
        chaos_state.memory_leak_enabled = bool(value)
        if not chaos_state.memory_leak_enabled:
            chaos_state._leaked_data.clear()
        logger.info("Chaos: memory_leak_enabled = %s", chaos_state.memory_leak_enabled)

    elif scenario == "cpu-saturation":
        count = max(0, min(8, int(value or 0)))
        chaos_state.start_cpu_threads(count)
        logger.info("Chaos: cpu_threads set to %d", chaos_state.cpu_threads)

    elif scenario == "downstream-timeout":
        chaos_state.downstream_timeout_s = max(0, min(30, int(value or 0)))
        logger.info("Chaos: downstream_timeout_s set to %d", chaos_state.downstream_timeout_s)

    elif scenario == "db-pool-exhaustion":
        pool_size = max(1, min(20, int(value or 0)))
        chaos_state.db_pool_size = pool_size
        # Dynamically reconfigure pool — in practice this limits new connections
        engine.pool._pool.maxsize = pool_size
        logger.info("Chaos: db_pool_size set to %d", pool_size)

    elif scenario == "log-flood":
        chaos_state.log_flood_lines = max(0, min(1000, int(value or 0)))
        logger.info("Chaos: log_flood_lines set to %d", chaos_state.log_flood_lines)

    elif scenario == "n-plus-one":
        chaos_state.n_plus_one_enabled = bool(value)
        logger.info("Chaos: n_plus_one_enabled = %s", chaos_state.n_plus_one_enabled)

    elif scenario == "disk-io":
        chaos_state.disk_io_mb = max(0, min(50, int(value or 0)))
        logger.info("Chaos: disk_io_mb set to %d", chaos_state.disk_io_mb)

    elif scenario == "retry-storm":
        chaos_state.retry_storm_enabled = bool(value)
        logger.info("Chaos: retry_storm_enabled = %s", chaos_state.retry_storm_enabled)

    else:
        raise HTTPException(status_code=404, detail=f"Unknown chaos scenario: {scenario}")

    return {"message": f"Chaos scenario '{scenario}' configured", "state": chaos_state.to_dict()}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, log_level="info")
PYEOF

# ---------- Frontend: main.py ----------
cat > /opt/app/frontend/main.py <<'PYEOF'
import json
import logging
import os
import sys
from contextlib import asynccontextmanager

import httpx
import uvicorn
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from opentelemetry import trace
from opentelemetry.propagate import inject

# ---------------------------------------------------------------------------
# Structured JSON logging with trace correlation
# ---------------------------------------------------------------------------

class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_record = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "module": record.module,
            "function": record.funcName,
            "line": record.lineno,
        }
        span = trace.get_current_span()
        ctx = span.get_span_context()
        if ctx and ctx.trace_id:
            log_record["trace_id"] = format(ctx.trace_id, "032x")
            log_record["span_id"] = format(ctx.span_id, "016x")
        else:
            log_record["trace_id"] = "0" * 32
            log_record["span_id"] = "0" * 16
        if record.exc_info and record.exc_info[0] is not None:
            log_record["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_record)


def setup_logging():
    lgr = logging.getLogger("frontend")
    lgr.setLevel(logging.INFO)
    lgr.handlers.clear()

    log_dir = "/var/log/app"
    os.makedirs(log_dir, exist_ok=True)
    fh = logging.FileHandler(os.path.join(log_dir, "frontend.log"))
    fh.setFormatter(JSONFormatter())
    lgr.addHandler(fh)

    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(JSONFormatter())
    lgr.addHandler(sh)

    return lgr


logger = setup_logging()
tracer = trace.get_tracer("ecommerce-frontend")

API_BASE = "http://localhost:8000"

# ---------------------------------------------------------------------------
# HTTP client helper with W3C trace propagation
# ---------------------------------------------------------------------------

async def api_call(method: str, path: str, **kwargs):
    """Make an HTTP call to the backend API with trace context propagation."""
    headers = kwargs.pop("headers", {})
    # Inject W3C traceparent header
    inject(headers)

    url = f"{API_BASE}{path}"
    async with httpx.AsyncClient(timeout=60.0) as client:
        resp = await client.request(method, url, headers=headers, **kwargs)
        return resp

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Frontend starting")
    yield
    logger.info("Frontend shutting down")


app = FastAPI(title="E-Commerce Frontend", version="1.0.0", lifespan=lifespan)

app.mount("/static", StaticFiles(directory=os.path.join(BASE_DIR, "static")), name="static")
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))

# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------

@app.get("/", response_class=HTMLResponse)
async def homepage(request: Request):
    with tracer.start_as_current_span("frontend.homepage"):
        products = []
        try:
            resp = await api_call("GET", "/api/products")
            if resp.status_code == 200:
                products = resp.json()
        except Exception as e:
            logger.error("Failed to fetch products: %s", e)

        featured = products[:4]
        return templates.TemplateResponse("index.html", {
            "request": request,
            "featured_products": featured,
        })


@app.get("/products", response_class=HTMLResponse)
async def products_page(request: Request, q: str = "", category: str = ""):
    with tracer.start_as_current_span("frontend.products"):
        products = []
        try:
            resp = await api_call("GET", "/api/products")
            if resp.status_code == 200:
                products = resp.json()
        except Exception as e:
            logger.error("Failed to fetch products: %s", e)

        if q:
            q_lower = q.lower()
            products = [p for p in products if q_lower in p["name"].lower() or q_lower in (p.get("description") or "").lower()]
        if category:
            products = [p for p in products if p["category"] == category]

        categories = sorted(set(p["category"] for p in products)) if products else []

        return templates.TemplateResponse("products.html", {
            "request": request,
            "products": products,
            "categories": categories,
            "query": q,
            "selected_category": category,
        })


@app.get("/products/{product_id}", response_class=HTMLResponse)
async def product_detail(request: Request, product_id: int):
    with tracer.start_as_current_span("frontend.product_detail") as span:
        span.set_attribute("product.id", product_id)
        product = None
        try:
            resp = await api_call("GET", f"/api/products/{product_id}")
            if resp.status_code == 200:
                product = resp.json()
        except Exception as e:
            logger.error("Failed to fetch product %d: %s", product_id, e)

        if not product:
            return templates.TemplateResponse("product_detail.html", {
                "request": request,
                "product": None,
                "error": "Product not found",
            })

        return templates.TemplateResponse("product_detail.html", {
            "request": request,
            "product": product,
            "error": None,
        })


@app.get("/cart", response_class=HTMLResponse)
async def cart_page(request: Request):
    with tracer.start_as_current_span("frontend.cart"):
        cart = {"items": [], "total": 0}
        try:
            resp = await api_call("GET", "/api/cart")
            if resp.status_code == 200:
                cart = resp.json()
        except Exception as e:
            logger.error("Failed to fetch cart: %s", e)

        return templates.TemplateResponse("cart.html", {
            "request": request,
            "cart": cart,
        })


@app.post("/cart/add")
async def add_to_cart(request: Request, product_id: int = Form(...), quantity: int = Form(1)):
    with tracer.start_as_current_span("frontend.add_to_cart"):
        try:
            await api_call("POST", "/api/cart/add", json={"product_id": product_id, "quantity": quantity})
        except Exception as e:
            logger.error("Failed to add to cart: %s", e)
        return RedirectResponse(url="/cart", status_code=303)


@app.get("/checkout", response_class=HTMLResponse)
async def checkout_page(request: Request):
    with tracer.start_as_current_span("frontend.checkout"):
        cart = {"items": [], "total": 0}
        try:
            resp = await api_call("GET", "/api/cart")
            if resp.status_code == 200:
                cart = resp.json()
        except Exception as e:
            logger.error("Failed to fetch cart for checkout: %s", e)

        return templates.TemplateResponse("checkout.html", {
            "request": request,
            "cart": cart,
        })


@app.post("/checkout")
async def do_checkout(request: Request, name: str = Form("Guest"), email: str = Form("guest@example.com")):
    with tracer.start_as_current_span("frontend.do_checkout"):
        order = None
        error = None
        try:
            resp = await api_call("POST", "/api/checkout", json={"name": name, "email": email})
            if resp.status_code == 200:
                order = resp.json()
            else:
                error = resp.json().get("detail", "Checkout failed")
        except Exception as e:
            logger.error("Checkout failed: %s", e)
            error = str(e)

        if order:
            return RedirectResponse(url="/orders", status_code=303)

        cart = {"items": [], "total": 0}
        return templates.TemplateResponse("checkout.html", {
            "request": request,
            "cart": cart,
            "error": error,
        })


@app.get("/orders", response_class=HTMLResponse)
async def orders_page(request: Request):
    with tracer.start_as_current_span("frontend.orders"):
        orders = []
        try:
            resp = await api_call("GET", "/api/orders")
            if resp.status_code == 200:
                orders = resp.json()
        except Exception as e:
            logger.error("Failed to fetch orders: %s", e)

        return templates.TemplateResponse("orders.html", {
            "request": request,
            "orders": orders,
        })


@app.get("/admin/chaos", response_class=HTMLResponse)
async def chaos_panel(request: Request):
    with tracer.start_as_current_span("frontend.chaos_panel"):
        state = {}
        try:
            resp = await api_call("GET", "/api/chaos/status")
            if resp.status_code == 200:
                state = resp.json()
        except Exception as e:
            logger.error("Failed to fetch chaos status: %s", e)

        return templates.TemplateResponse("chaos.html", {
            "request": request,
            "state": state,
        })


# ---------------------------------------------------------------------------
# Proxy routes for chaos API calls from the frontend JS
# ---------------------------------------------------------------------------

@app.post("/api/chaos/reset")
async def proxy_chaos_reset():
    resp = await api_call("POST", "/api/chaos/reset")
    return resp.json()


@app.get("/api/chaos/status")
async def proxy_chaos_status():
    resp = await api_call("GET", "/api/chaos/status")
    return resp.json()


@app.post("/api/chaos/{scenario}")
async def proxy_chaos_set(scenario: str, request: Request):
    body = await request.json()
    resp = await api_call("POST", f"/api/chaos/{scenario}", json=body)
    return resp.json()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=80, log_level="info")
PYEOF

# ---------- Frontend: templates/base.html ----------
cat > /opt/app/frontend/templates/base.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en" data-bs-theme="light">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{% block title %}E-Commerce Demo{% endblock %}</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.2/font/bootstrap-icons.min.css" rel="stylesheet">
    <link href="/static/style.css" rel="stylesheet">
    {% block extra_head %}{% endblock %}
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-dark bg-dark sticky-top">
        <div class="container">
            <a class="navbar-brand fw-bold" href="/">
                <i class="bi bi-shop"></i> OTel Demo Shop
            </a>
            <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav">
                <span class="navbar-toggler-icon"></span>
            </button>
            <div class="collapse navbar-collapse" id="navbarNav">
                <ul class="navbar-nav me-auto">
                    <li class="nav-item">
                        <a class="nav-link" href="/products"><i class="bi bi-grid"></i> Products</a>
                    </li>
                    <li class="nav-item">
                        <a class="nav-link" href="/cart"><i class="bi bi-cart3"></i> Cart</a>
                    </li>
                    <li class="nav-item">
                        <a class="nav-link" href="/orders"><i class="bi bi-receipt"></i> Orders</a>
                    </li>
                </ul>
                <ul class="navbar-nav">
                    <li class="nav-item">
                        <a class="nav-link text-warning" href="/admin/chaos"><i class="bi bi-radioactive"></i> Chaos Panel</a>
                    </li>
                </ul>
            </div>
        </div>
    </nav>

    <main class="container py-4">
        {% block content %}{% endblock %}
    </main>

    <footer class="bg-dark text-light py-3 mt-5">
        <div class="container text-center">
            <small>Elastic Observability OTel Demo &mdash; Instrumented with OpenTelemetry</small>
        </div>
    </footer>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
    {% block extra_js %}{% endblock %}
</body>
</html>
HTMLEOF

# ---------- Frontend: templates/index.html ----------
cat > /opt/app/frontend/templates/index.html <<'HTMLEOF'
{% extends "base.html" %}

{% block title %}OTel Demo Shop — Home{% endblock %}

{% block content %}
<div class="hero-banner bg-primary text-white rounded-3 p-5 mb-5">
    <div class="row align-items-center">
        <div class="col-lg-8">
            <h1 class="display-4 fw-bold">Welcome to OTel Demo Shop</h1>
            <p class="lead mb-4">A fully instrumented e-commerce application for exploring Elastic Observability with OpenTelemetry. Browse products, place orders, and inject chaos to see how observability helps you debug real-world issues.</p>
            <a href="/products" class="btn btn-light btn-lg me-2"><i class="bi bi-grid"></i> Browse Products</a>
            <a href="/admin/chaos" class="btn btn-outline-light btn-lg"><i class="bi bi-radioactive"></i> Chaos Panel</a>
        </div>
        <div class="col-lg-4 text-center d-none d-lg-block">
            <i class="bi bi-shop display-1" style="font-size: 8rem; opacity: 0.3;"></i>
        </div>
    </div>
</div>

<h2 class="mb-4">Featured Products</h2>
<div class="row row-cols-1 row-cols-md-2 row-cols-lg-4 g-4">
    {% for product in featured_products %}
    <div class="col">
        <div class="card h-100 shadow-sm product-card">
            <img src="{{ product.image_url }}" class="card-img-top" alt="{{ product.name }}" style="height: 200px; object-fit: cover;">
            <div class="card-body d-flex flex-column">
                <span class="badge bg-secondary mb-2 align-self-start">{{ product.category }}</span>
                <h5 class="card-title">{{ product.name }}</h5>
                <p class="card-text text-muted small flex-grow-1">{{ product.description[:80] }}...</p>
                <div class="d-flex justify-content-between align-items-center mt-2">
                    <span class="h5 text-primary mb-0">$${{ "%.2f"|format(product.price) }}</span>
                    <a href="/products/{{ product.id }}" class="btn btn-sm btn-outline-primary">View</a>
                </div>
            </div>
        </div>
    </div>
    {% endfor %}
</div>

{% if not featured_products %}
<div class="alert alert-info">
    <i class="bi bi-info-circle"></i> No products available. The API may be starting up.
</div>
{% endif %}
{% endblock %}
HTMLEOF

# ---------- Frontend: templates/products.html ----------
cat > /opt/app/frontend/templates/products.html <<'HTMLEOF'
{% extends "base.html" %}

{% block title %}Products — OTel Demo Shop{% endblock %}

{% block content %}
<h1 class="mb-4">Products</h1>

<div class="row mb-4">
    <div class="col-md-6">
        <form method="get" action="/products" class="input-group">
            <input type="text" name="q" class="form-control" placeholder="Search products..." value="{{ query }}">
            {% if selected_category %}
            <input type="hidden" name="category" value="{{ selected_category }}">
            {% endif %}
            <button class="btn btn-primary" type="submit"><i class="bi bi-search"></i></button>
        </form>
    </div>
    <div class="col-md-6">
        <div class="d-flex gap-2 flex-wrap justify-content-md-end mt-2 mt-md-0">
            <a href="/products" class="btn btn-sm {% if not selected_category %}btn-primary{% else %}btn-outline-primary{% endif %}">All</a>
            {% for cat in categories %}
            <a href="/products?category={{ cat }}{% if query %}&q={{ query }}{% endif %}" class="btn btn-sm {% if selected_category == cat %}btn-primary{% else %}btn-outline-primary{% endif %}">{{ cat }}</a>
            {% endfor %}
        </div>
    </div>
</div>

<div class="row row-cols-1 row-cols-md-2 row-cols-lg-3 row-cols-xl-4 g-4">
    {% for product in products %}
    <div class="col">
        <div class="card h-100 shadow-sm product-card">
            <img src="{{ product.image_url }}" class="card-img-top" alt="{{ product.name }}" style="height: 200px; object-fit: cover;">
            <div class="card-body d-flex flex-column">
                <span class="badge bg-secondary mb-2 align-self-start">{{ product.category }}</span>
                <h5 class="card-title">{{ product.name }}</h5>
                <p class="card-text text-muted small flex-grow-1">{{ product.description[:100] }}{% if product.description|length > 100 %}...{% endif %}</p>
                <div class="d-flex justify-content-between align-items-center mt-2">
                    <span class="h5 text-primary mb-0">$${{ "%.2f"|format(product.price) }}</span>
                    <div>
                        <span class="badge {% if product.stock > 0 %}bg-success{% else %}bg-danger{% endif %} me-1">
                            {% if product.stock > 0 %}In Stock{% else %}Out of Stock{% endif %}
                        </span>
                        <a href="/products/{{ product.id }}" class="btn btn-sm btn-outline-primary">View</a>
                    </div>
                </div>
            </div>
        </div>
    </div>
    {% endfor %}
</div>

{% if not products %}
<div class="alert alert-info mt-4">
    <i class="bi bi-info-circle"></i> No products found{% if query %} matching "{{ query }}"{% endif %}.
</div>
{% endif %}
{% endblock %}
HTMLEOF

# ---------- Frontend: templates/product_detail.html ----------
cat > /opt/app/frontend/templates/product_detail.html <<'HTMLEOF'
{% extends "base.html" %}

{% block title %}{% if product %}{{ product.name }}{% else %}Product Not Found{% endif %} — OTel Demo Shop{% endblock %}

{% block content %}
{% if error %}
<div class="alert alert-danger">
    <i class="bi bi-exclamation-triangle"></i> {{ error }}
</div>
<a href="/products" class="btn btn-primary">Back to Products</a>
{% elif product %}
<nav aria-label="breadcrumb" class="mb-4">
    <ol class="breadcrumb">
        <li class="breadcrumb-item"><a href="/products">Products</a></li>
        <li class="breadcrumb-item"><a href="/products?category={{ product.category }}">{{ product.category }}</a></li>
        <li class="breadcrumb-item active">{{ product.name }}</li>
    </ol>
</nav>

<div class="row">
    <div class="col-md-5 mb-4">
        <img src="{{ product.image_url }}" class="img-fluid rounded shadow" alt="{{ product.name }}" style="width: 100%; max-height: 400px; object-fit: cover;">
    </div>
    <div class="col-md-7">
        <span class="badge bg-secondary mb-2">{{ product.category }}</span>
        <h1>{{ product.name }}</h1>
        <p class="text-muted">{{ product.description }}</p>

        <div class="d-flex align-items-center gap-3 mb-4">
            <span class="display-6 text-primary fw-bold">$${{ "%.2f"|format(product.price) }}</span>
            <span class="badge {% if product.stock > 0 %}bg-success{% else %}bg-danger{% endif %} fs-6">
                {% if product.stock > 0 %}{{ product.stock }} in stock{% else %}Out of Stock{% endif %}
            </span>
        </div>

        {% if product.stock > 0 %}
        <form method="post" action="/cart/add">
            <input type="hidden" name="product_id" value="{{ product.id }}">
            <div class="input-group" style="max-width: 250px;">
                <span class="input-group-text">Qty</span>
                <input type="number" name="quantity" class="form-control" value="1" min="1" max="{{ product.stock }}">
                <button type="submit" class="btn btn-primary"><i class="bi bi-cart-plus"></i> Add to Cart</button>
            </div>
        </form>
        {% else %}
        <button class="btn btn-secondary" disabled>Out of Stock</button>
        {% endif %}
    </div>
</div>
{% endif %}
{% endblock %}
HTMLEOF

# ---------- Frontend: templates/cart.html ----------
cat > /opt/app/frontend/templates/cart.html <<'HTMLEOF'
{% extends "base.html" %}

{% block title %}Shopping Cart — OTel Demo Shop{% endblock %}

{% block content %}
<h1 class="mb-4"><i class="bi bi-cart3"></i> Shopping Cart</h1>

{% if cart.items %}
<div class="table-responsive">
    <table class="table table-hover align-middle">
        <thead class="table-dark">
            <tr>
                <th>Product</th>
                <th>Price</th>
                <th>Quantity</th>
                <th class="text-end">Subtotal</th>
            </tr>
        </thead>
        <tbody>
            {% for item in cart.items %}
            <tr>
                <td>
                    {% if item.product %}
                    <div class="d-flex align-items-center">
                        <img src="{{ item.product.image_url }}" alt="{{ item.product.name }}" class="rounded me-3" style="width: 50px; height: 50px; object-fit: cover;">
                        <div>
                            <a href="/products/{{ item.product.id }}" class="text-decoration-none fw-semibold">{{ item.product.name }}</a>
                            <br><small class="text-muted">{{ item.product.category }}</small>
                        </div>
                    </div>
                    {% else %}
                    Product #{{ item.product_id }}
                    {% endif %}
                </td>
                <td>$${{ "%.2f"|format(item.product.price if item.product else 0) }}</td>
                <td>{{ item.quantity }}</td>
                <td class="text-end">$${{ "%.2f"|format((item.product.price if item.product else 0) * item.quantity) }}</td>
            </tr>
            {% endfor %}
        </tbody>
        <tfoot>
            <tr class="table-light">
                <td colspan="3" class="text-end fw-bold">Total:</td>
                <td class="text-end fw-bold fs-5 text-primary">$${{ "%.2f"|format(cart.total) }}</td>
            </tr>
        </tfoot>
    </table>
</div>

<div class="d-flex justify-content-between mt-3">
    <a href="/products" class="btn btn-outline-primary"><i class="bi bi-arrow-left"></i> Continue Shopping</a>
    <a href="/checkout" class="btn btn-success btn-lg"><i class="bi bi-credit-card"></i> Proceed to Checkout</a>
</div>

{% else %}
<div class="text-center py-5">
    <i class="bi bi-cart-x display-1 text-muted"></i>
    <h3 class="mt-3 text-muted">Your cart is empty</h3>
    <a href="/products" class="btn btn-primary mt-3"><i class="bi bi-grid"></i> Browse Products</a>
</div>
{% endif %}
{% endblock %}
HTMLEOF

# ---------- Frontend: templates/checkout.html ----------
cat > /opt/app/frontend/templates/checkout.html <<'HTMLEOF'
{% extends "base.html" %}

{% block title %}Checkout — OTel Demo Shop{% endblock %}

{% block content %}
<h1 class="mb-4"><i class="bi bi-credit-card"></i> Checkout</h1>

{% if error %}
<div class="alert alert-danger">
    <i class="bi bi-exclamation-triangle"></i> {{ error }}
</div>
{% endif %}

<div class="row">
    <div class="col-md-7">
        <div class="card shadow-sm">
            <div class="card-header bg-dark text-white">
                <h5 class="mb-0">Your Information</h5>
            </div>
            <div class="card-body">
                <form method="post" action="/checkout">
                    <div class="mb-3">
                        <label for="name" class="form-label">Full Name</label>
                        <input type="text" class="form-control" id="name" name="name" value="Guest" required>
                    </div>
                    <div class="mb-3">
                        <label for="email" class="form-label">Email Address</label>
                        <input type="email" class="form-control" id="email" name="email" value="guest@example.com" required>
                    </div>
                    <button type="submit" class="btn btn-success btn-lg w-100">
                        <i class="bi bi-bag-check"></i> Place Order — $${{ "%.2f"|format(cart.total) }}
                    </button>
                </form>
            </div>
        </div>
    </div>
    <div class="col-md-5">
        <div class="card shadow-sm">
            <div class="card-header bg-dark text-white">
                <h5 class="mb-0">Order Summary</h5>
            </div>
            <div class="card-body">
                {% if cart.items %}
                <ul class="list-group list-group-flush mb-3">
                    {% for item in cart.items %}
                    <li class="list-group-item d-flex justify-content-between">
                        <span>
                            {{ item.product.name if item.product else 'Product #' ~ item.product_id }}
                            <small class="text-muted">x{{ item.quantity }}</small>
                        </span>
                        <span>$${{ "%.2f"|format((item.product.price if item.product else 0) * item.quantity) }}</span>
                    </li>
                    {% endfor %}
                </ul>
                <div class="d-flex justify-content-between fw-bold fs-5">
                    <span>Total:</span>
                    <span class="text-primary">$${{ "%.2f"|format(cart.total) }}</span>
                </div>
                {% else %}
                <p class="text-muted">Your cart is empty.</p>
                <a href="/products" class="btn btn-outline-primary">Browse Products</a>
                {% endif %}
            </div>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

# ---------- Frontend: templates/orders.html ----------
cat > /opt/app/frontend/templates/orders.html <<'HTMLEOF'
{% extends "base.html" %}

{% block title %}Orders — OTel Demo Shop{% endblock %}

{% block content %}
<h1 class="mb-4"><i class="bi bi-receipt"></i> Order History</h1>

{% if orders %}
<div class="row row-cols-1 g-4">
    {% for order in orders %}
    <div class="col">
        <div class="card shadow-sm">
            <div class="card-header d-flex justify-content-between align-items-center">
                <div>
                    <h5 class="mb-0">Order #{{ order.id }}</h5>
                    <small class="text-muted">{{ order.created_at }}</small>
                </div>
                <div>
                    <span class="badge {% if order.status == 'confirmed' %}bg-success{% elif order.status == 'pending' %}bg-warning{% else %}bg-secondary{% endif %} fs-6">
                        {{ order.status|capitalize }}
                    </span>
                </div>
            </div>
            <div class="card-body">
                <table class="table table-sm mb-0">
                    <thead>
                        <tr>
                            <th>Product ID</th>
                            <th>Quantity</th>
                            <th>Unit Price</th>
                            <th class="text-end">Subtotal</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for item in order.items %}
                        <tr>
                            <td>#{{ item.product_id }}</td>
                            <td>{{ item.quantity }}</td>
                            <td>$${{ "%.2f"|format(item.price) }}</td>
                            <td class="text-end">$${{ "%.2f"|format(item.price * item.quantity) }}</td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
            </div>
            <div class="card-footer text-end">
                <span class="fw-bold fs-5">Total: <span class="text-primary">$${{ "%.2f"|format(order.total) }}</span></span>
            </div>
        </div>
    </div>
    {% endfor %}
</div>
{% else %}
<div class="text-center py-5">
    <i class="bi bi-receipt-cutoff display-1 text-muted"></i>
    <h3 class="mt-3 text-muted">No orders yet</h3>
    <p class="text-muted">Place your first order by browsing our products.</p>
    <a href="/products" class="btn btn-primary mt-2"><i class="bi bi-grid"></i> Browse Products</a>
</div>
{% endif %}
{% endblock %}
HTMLEOF

# ---------- Frontend: templates/chaos.html ----------
cat > /opt/app/frontend/templates/chaos.html <<'HTMLEOF'
{% extends "base.html" %}

{% block title %}Chaos Engineering Panel — OTel Demo Shop{% endblock %}

{% block content %}
<div class="d-flex justify-content-between align-items-center mb-4">
    <h1><i class="bi bi-radioactive"></i> Chaos Engineering Panel</h1>
    <button id="resetAll" class="btn btn-danger btn-lg"><i class="bi bi-arrow-counterclockwise"></i> Reset All</button>
</div>

<div class="alert alert-warning">
    <i class="bi bi-exclamation-triangle"></i> <strong>Warning:</strong> These controls inject real failures into the running application. Use them to observe how failures appear in Elastic Observability.
</div>

<div class="row row-cols-1 row-cols-md-2 g-4" id="chaosCards">

    <!-- 1. Slow Database Queries -->
    <div class="col">
        <div class="card shadow-sm chaos-card" id="card-slow-db">
            <div class="card-header d-flex justify-content-between align-items-center">
                <h5 class="mb-0"><i class="bi bi-hourglass-split"></i> Slow Database Queries</h5>
                <span class="badge status-badge bg-success">OFF</span>
            </div>
            <div class="card-body">
                <p class="text-muted">Add artificial latency before every database call.</p>
                <label class="form-label">Delay: <strong class="slider-value">0</strong> ms</label>
                <input type="range" class="form-range chaos-slider" min="0" max="5000" step="100" value="{{ state.get('slow_db_ms', 0) }}"
                       data-scenario="slow-db" data-unit="ms">
            </div>
        </div>
    </div>

    <!-- 2. High Error Rate -->
    <div class="col">
        <div class="card shadow-sm chaos-card" id="card-error-rate">
            <div class="card-header d-flex justify-content-between align-items-center">
                <h5 class="mb-0"><i class="bi bi-bug"></i> High Error Rate (5xx)</h5>
                <span class="badge status-badge bg-success">OFF</span>
            </div>
            <div class="card-body">
                <p class="text-muted">Random chance each request returns HTTP 500.</p>
                <label class="form-label">Error rate: <strong class="slider-value">0</strong>%</label>
                <input type="range" class="form-range chaos-slider" min="0" max="100" step="5" value="{{ state.get('error_rate_pct', 0) }}"
                       data-scenario="error-rate" data-unit="%">
            </div>
        </div>
    </div>

    <!-- 3. Memory Leak -->
    <div class="col">
        <div class="card shadow-sm chaos-card" id="card-memory-leak">
            <div class="card-header d-flex justify-content-between align-items-center">
                <h5 class="mb-0"><i class="bi bi-memory"></i> Memory Leak</h5>
                <span class="badge status-badge bg-success">OFF</span>
            </div>
            <div class="card-body">
                <p class="text-muted">Append 1KB to a growing list on every request. Memory usage will climb steadily.</p>
                <div class="form-check form-switch">
                    <input class="form-check-input chaos-toggle" type="checkbox" id="toggle-memory-leak"
                           data-scenario="memory-leak" {% if state.get('memory_leak_enabled') %}checked{% endif %}>
                    <label class="form-check-label" for="toggle-memory-leak">Enable Memory Leak</label>
                </div>
                <small class="text-muted mt-2 d-block">Leaked: <span id="memory-leak-size">{{ state.get('memory_leak_size_mb', 0) }}</span> MB</small>
            </div>
        </div>
    </div>

    <!-- 4. CPU Saturation -->
    <div class="col">
        <div class="card shadow-sm chaos-card" id="card-cpu-saturation">
            <div class="card-header d-flex justify-content-between align-items-center">
                <h5 class="mb-0"><i class="bi bi-cpu"></i> CPU Saturation</h5>
                <span class="badge status-badge bg-success">OFF</span>
            </div>
            <div class="card-body">
                <p class="text-muted">Spawn busy-wait threads that burn CPU cycles.</p>
                <label class="form-label">Threads: <strong class="slider-value">0</strong></label>
                <input type="range" class="form-range chaos-slider" min="0" max="8" step="1" value="{{ state.get('cpu_threads', 0) }}"
                       data-scenario="cpu-saturation" data-unit="">
            </div>
        </div>
    </div>

    <!-- 5. Downstream Dependency Timeout -->
    <div class="col">
        <div class="card shadow-sm chaos-card" id="card-downstream-timeout">
            <div class="card-header d-flex justify-content-between align-items-center">
                <h5 class="mb-0"><i class="bi bi-clock-history"></i> Downstream Timeout</h5>
                <span class="badge status-badge bg-success">OFF</span>
            </div>
            <div class="card-body">
                <p class="text-muted">Simulate a slow external dependency by adding a sleep to each request.</p>
                <label class="form-label">Timeout: <strong class="slider-value">0</strong> s</label>
                <input type="range" class="form-range chaos-slider" min="0" max="30" step="1" value="{{ state.get('downstream_timeout_s', 0) }}"
                       data-scenario="downstream-timeout" data-unit="s">
            </div>
        </div>
    </div>

    <!-- 6. DB Connection Pool Exhaustion -->
    <div class="col">
        <div class="card shadow-sm chaos-card" id="card-db-pool">
            <div class="card-header d-flex justify-content-between align-items-center">
                <h5 class="mb-0"><i class="bi bi-database-x"></i> DB Pool Exhaustion</h5>
                <span class="badge status-badge bg-success">OFF</span>
            </div>
            <div class="card-body">
                <p class="text-muted">Dynamically reduce the database connection pool size to starve queries.</p>
                <label class="form-label">Pool size: <strong class="slider-value">0</strong></label>
                <input type="range" class="form-range chaos-slider" min="0" max="20" step="1" value="{{ state.get('db_pool_size', 0) }}"
                       data-scenario="db-pool-exhaustion" data-unit="">
                <small class="text-muted">0 = default (not active). Lower values = more contention.</small>
            </div>
        </div>
    </div>

    <!-- 7. Log Flooding -->
    <div class="col">
        <div class="card shadow-sm chaos-card" id="card-log-flood">
            <div class="card-header d-flex justify-content-between align-items-center">
                <h5 class="mb-0"><i class="bi bi-file-earmark-text"></i> Log Flooding</h5>
                <span class="badge status-badge bg-success">OFF</span>
            </div>
            <div class="card-body">
                <p class="text-muted">Write extra log lines per request, flooding log storage.</p>
                <label class="form-label">Lines/request: <strong class="slider-value">0</strong></label>
                <input type="range" class="form-range chaos-slider" min="0" max="1000" step="50" value="{{ state.get('log_flood_lines', 0) }}"
                       data-scenario="log-flood" data-unit=" lines">
            </div>
        </div>
    </div>

    <!-- 8. N+1 Query Problem -->
    <div class="col">
        <div class="card shadow-sm chaos-card" id="card-n-plus-one">
            <div class="card-header d-flex justify-content-between align-items-center">
                <h5 class="mb-0"><i class="bi bi-arrow-repeat"></i> N+1 Query Problem</h5>
                <span class="badge status-badge bg-success">OFF</span>
            </div>
            <div class="card-body">
                <p class="text-muted">Replace efficient batch queries with N individual queries, one per row.</p>
                <div class="form-check form-switch">
                    <input class="form-check-input chaos-toggle" type="checkbox" id="toggle-n-plus-one"
                           data-scenario="n-plus-one" {% if state.get('n_plus_one_enabled') %}checked{% endif %}>
                    <label class="form-check-label" for="toggle-n-plus-one">Enable N+1 Queries</label>
                </div>
            </div>
        </div>
    </div>

    <!-- 9. Disk I/O Saturation -->
    <div class="col">
        <div class="card shadow-sm chaos-card" id="card-disk-io">
            <div class="card-header d-flex justify-content-between align-items-center">
                <h5 class="mb-0"><i class="bi bi-hdd"></i> Disk I/O Saturation</h5>
                <span class="badge status-badge bg-success">OFF</span>
            </div>
            <div class="card-body">
                <p class="text-muted">Write temporary files to disk on each request to saturate I/O.</p>
                <label class="form-label">Write: <strong class="slider-value">0</strong> MB/req</label>
                <input type="range" class="form-range chaos-slider" min="0" max="50" step="5" value="{{ state.get('disk_io_mb', 0) }}"
                       data-scenario="disk-io" data-unit=" MB">
            </div>
        </div>
    </div>

    <!-- 10. Cascading Latency (Retry Storm) -->
    <div class="col">
        <div class="card shadow-sm chaos-card" id="card-retry-storm">
            <div class="card-header d-flex justify-content-between align-items-center">
                <h5 class="mb-0"><i class="bi bi-tornado"></i> Retry Storm</h5>
                <span class="badge status-badge bg-success">OFF</span>
            </div>
            <div class="card-body">
                <p class="text-muted">Simulate cascading latency with an internal retry loop using exponential backoff.</p>
                <div class="form-check form-switch">
                    <input class="form-check-input chaos-toggle" type="checkbox" id="toggle-retry-storm"
                           data-scenario="retry-storm" {% if state.get('retry_storm_enabled') %}checked{% endif %}>
                    <label class="form-check-label" for="toggle-retry-storm">Enable Retry Storm</label>
                </div>
            </div>
        </div>
    </div>

</div>
{% endblock %}

{% block extra_js %}
<script>
const API_BASE = '';

function updateCardStyle(card, isActive) {
    const badge = card.querySelector('.status-badge');
    if (isActive) {
        badge.textContent = 'ACTIVE';
        badge.classList.remove('bg-success');
        badge.classList.add('bg-danger');
        card.classList.add('border-danger');
    } else {
        badge.textContent = 'OFF';
        badge.classList.remove('bg-danger');
        badge.classList.add('bg-success');
        card.classList.remove('border-danger');
    }
}

// Initialize UI state from current values
function initializeUI() {
    document.querySelectorAll('.chaos-slider').forEach(slider => {
        const card = slider.closest('.chaos-card');
        const label = card.querySelector('.slider-value');
        label.textContent = slider.value;
        updateCardStyle(card, parseInt(slider.value) > 0);
    });
    document.querySelectorAll('.chaos-toggle').forEach(toggle => {
        const card = toggle.closest('.chaos-card');
        updateCardStyle(card, toggle.checked);
    });
}

// Slider change handler
document.querySelectorAll('.chaos-slider').forEach(slider => {
    slider.addEventListener('input', function() {
        const card = this.closest('.chaos-card');
        const label = card.querySelector('.slider-value');
        label.textContent = this.value;
        updateCardStyle(card, parseInt(this.value) > 0);
    });

    slider.addEventListener('change', function() {
        const scenario = this.dataset.scenario;
        const value = parseInt(this.value);
        fetch(API_BASE + '/api/chaos/' + scenario, {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({value: value})
        })
        .then(r => r.json())
        .then(data => console.log('Chaos updated:', scenario, data))
        .catch(err => console.error('Chaos error:', err));
    });
});

// Toggle change handler
document.querySelectorAll('.chaos-toggle').forEach(toggle => {
    toggle.addEventListener('change', function() {
        const scenario = this.dataset.scenario;
        const value = this.checked;
        const card = this.closest('.chaos-card');
        updateCardStyle(card, value);

        fetch(API_BASE + '/api/chaos/' + scenario, {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({value: value})
        })
        .then(r => r.json())
        .then(data => console.log('Chaos updated:', scenario, data))
        .catch(err => console.error('Chaos error:', err));
    });
});

// Reset All
document.getElementById('resetAll').addEventListener('click', function() {
    if (!confirm('Reset all chaos scenarios to off?')) return;

    fetch(API_BASE + '/api/chaos/reset', {method: 'POST'})
    .then(r => r.json())
    .then(data => {
        console.log('Chaos reset:', data);
        // Reset all UI controls
        document.querySelectorAll('.chaos-slider').forEach(s => {
            s.value = 0;
        });
        document.querySelectorAll('.chaos-toggle').forEach(t => {
            t.checked = false;
        });
        initializeUI();
    })
    .catch(err => console.error('Reset error:', err));
});

// Periodic status refresh
function refreshStatus() {
    fetch(API_BASE + '/api/chaos/status')
    .then(r => r.json())
    .then(state => {
        // Update memory leak size
        const memEl = document.getElementById('memory-leak-size');
        if (memEl) memEl.textContent = state.memory_leak_size_mb || 0;
    })
    .catch(() => {});
}

initializeUI();
setInterval(refreshStatus, 5000);
</script>
{% endblock %}
HTMLEOF

# ---------- Frontend: static/style.css ----------
cat > /opt/app/frontend/static/style.css <<'CSSEOF'
/* OTel Demo Shop — Custom Styles */

body {
    min-height: 100vh;
    display: flex;
    flex-direction: column;
}

main {
    flex: 1;
}

/* Hero banner */
.hero-banner {
    background: linear-gradient(135deg, #0d6efd 0%, #6610f2 100%);
}

/* Product cards */
.product-card {
    transition: transform 0.2s ease, box-shadow 0.2s ease;
}

.product-card:hover {
    transform: translateY(-4px);
    box-shadow: 0 0.5rem 1rem rgba(0, 0, 0, 0.15);
}

/* Chaos cards */
.chaos-card {
    transition: border-color 0.3s ease;
    border-width: 2px;
}

.chaos-card.border-danger {
    border-color: #dc3545 !important;
    background-color: #fff5f5;
}

/* Slider styling */
.form-range::-webkit-slider-thumb {
    cursor: pointer;
}

/* Navbar active link */
.navbar .nav-link:hover {
    opacity: 0.85;
}

/* Badge in card headers */
.status-badge {
    font-size: 0.85rem;
    min-width: 60px;
    text-align: center;
}

/* Footer */
footer {
    margin-top: auto;
}

/* Table tweaks */
.table th {
    font-weight: 600;
}
CSSEOF

# ---------- Loadgen: main.py ----------
cat > /opt/app/loadgen/main.py <<'PYEOF'
"""
Load generator for the OTel Demo Shop.

Simulates realistic user journeys:
  - 60% browse only (list products, view a random product)
  - 30% add to cart (browse + add item to cart)
  - 10% full purchase (browse + add + checkout)

Targets ~10-20 requests/second with randomized delays.
Runs continuously; designed to be managed by systemd.
"""

import logging
import random
import sys
import time

import httpx
from opentelemetry import trace

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("loadgen")
tracer = trace.get_tracer("loadgen")

FRONTEND_BASE = "http://localhost"
API_BASE = "http://localhost:8000"

# Delays between actions in seconds
MIN_DELAY = 0.5
MAX_DELAY = 2.0

# Retry configuration
MAX_RETRIES = 3
RETRY_BACKOFF = 1.0


def random_delay():
    time.sleep(random.uniform(MIN_DELAY, MAX_DELAY))


def make_request(client: httpx.Client, method: str, url: str, **kwargs) -> httpx.Response | None:
    """Make an HTTP request with retries and backoff."""
    for attempt in range(MAX_RETRIES):
        try:
            resp = client.request(method, url, timeout=30.0, **kwargs)
            if resp.status_code < 500:
                return resp
            logger.warning("Server error %d on %s %s (attempt %d)", resp.status_code, method, url, attempt + 1)
        except (httpx.ConnectError, httpx.ReadTimeout, httpx.WriteTimeout, httpx.PoolTimeout) as e:
            logger.warning("Request failed: %s %s — %s (attempt %d)", method, url, e, attempt + 1)
        except Exception as e:
            logger.error("Unexpected error: %s %s — %s", method, url, e)
            return None

        if attempt < MAX_RETRIES - 1:
            backoff = RETRY_BACKOFF * (2 ** attempt) + random.uniform(0, 0.5)
            time.sleep(backoff)

    logger.error("All retries exhausted for %s %s", method, url)
    return None


def journey_browse(client: httpx.Client):
    """Browse products — view listing and one random product."""
    with tracer.start_as_current_span("loadgen.journey.browse") as span:
        span.set_attribute("journey.type", "browse")

        # Visit homepage
        make_request(client, "GET", f"{FRONTEND_BASE}/")
        random_delay()

        # List products
        resp = make_request(client, "GET", f"{FRONTEND_BASE}/products")
        random_delay()

        # Fetch product list from API to pick a random product
        api_resp = make_request(client, "GET", f"{API_BASE}/api/products")
        if api_resp and api_resp.status_code == 200:
            products = api_resp.json()
            if products:
                product = random.choice(products)
                make_request(client, "GET", f"{FRONTEND_BASE}/products/{product['id']}")
                random_delay()
                return products

        return []


def journey_add_to_cart(client: httpx.Client):
    """Browse + add a random product to the cart."""
    with tracer.start_as_current_span("loadgen.journey.add_to_cart") as span:
        span.set_attribute("journey.type", "add_to_cart")

        products = journey_browse(client)
        if not products:
            return

        product = random.choice(products)
        quantity = random.randint(1, 3)

        # Add to cart via frontend form POST
        make_request(
            client,
            "POST",
            f"{FRONTEND_BASE}/cart/add",
            data={"product_id": product["id"], "quantity": quantity},
            follow_redirects=True,
        )
        random_delay()

        # View cart
        make_request(client, "GET", f"{FRONTEND_BASE}/cart")
        random_delay()


def journey_purchase(client: httpx.Client):
    """Full purchase: browse, add to cart, checkout."""
    with tracer.start_as_current_span("loadgen.journey.purchase") as span:
        span.set_attribute("journey.type", "purchase")

        products = journey_browse(client)
        if not products:
            return

        # Add 1-3 items
        num_items = random.randint(1, 3)
        for _ in range(num_items):
            product = random.choice(products)
            quantity = random.randint(1, 2)
            make_request(
                client,
                "POST",
                f"{FRONTEND_BASE}/cart/add",
                data={"product_id": product["id"], "quantity": quantity},
                follow_redirects=True,
            )
            random_delay()

        # View cart
        make_request(client, "GET", f"{FRONTEND_BASE}/cart")
        random_delay()

        # Go to checkout page
        make_request(client, "GET", f"{FRONTEND_BASE}/checkout")
        random_delay()

        # Place order
        names = ["Alice Smith", "Bob Jones", "Carol White", "Dave Brown", "Eve Davis"]
        name = random.choice(names)
        email = name.lower().replace(" ", ".") + "@example.com"

        make_request(
            client,
            "POST",
            f"{FRONTEND_BASE}/checkout",
            data={"name": name, "email": email},
            follow_redirects=True,
        )
        random_delay()

        # View orders
        make_request(client, "GET", f"{FRONTEND_BASE}/orders")
        random_delay()


def run():
    """Main loop — run journeys continuously."""
    logger.info("Load generator starting — targeting %s", FRONTEND_BASE)

    # Wait for services to be ready
    with httpx.Client() as client:
        for attempt in range(30):
            try:
                resp = client.get(f"{API_BASE}/api/health", timeout=5.0)
                if resp.status_code == 200:
                    logger.info("API is healthy, starting load generation")
                    break
            except Exception:
                pass
            logger.info("Waiting for API to be ready (attempt %d/30)...", attempt + 1)
            time.sleep(2)
        else:
            logger.error("API did not become healthy after 60 seconds, starting anyway")

    iteration = 0
    with httpx.Client() as client:
        while True:
            iteration += 1
            roll = random.random()

            try:
                if roll < 0.60:
                    logger.info("Journey %d: browse", iteration)
                    journey_browse(client)
                elif roll < 0.90:
                    logger.info("Journey %d: add_to_cart", iteration)
                    journey_add_to_cart(client)
                else:
                    logger.info("Journey %d: purchase", iteration)
                    journey_purchase(client)
            except Exception as e:
                logger.error("Journey %d failed: %s", iteration, e)
                time.sleep(2)

            # Small pause between journeys to maintain ~10-20 req/s overall
            time.sleep(random.uniform(0.2, 0.8))


if __name__ == "__main__":
    run()
PYEOF

# ---------- Set ownership ----------
chown -R appuser:appuser /opt/app

# ==============================================================================
# 7. Install Python dependencies
# ==============================================================================
pip3 install --break-system-packages \
  fastapi \
  'uvicorn[standard]' \
  sqlalchemy \
  psycopg2-binary \
  redis \
  httpx \
  jinja2 \
  python-multipart \
  opentelemetry-distro \
  opentelemetry-exporter-otlp \
  opentelemetry-instrumentation-fastapi \
  opentelemetry-instrumentation-sqlalchemy \
  opentelemetry-instrumentation-redis \
  opentelemetry-instrumentation-httpx

opentelemetry-bootstrap -a install || true

# ==============================================================================
# 8. OTel Collector configuration
# ==============================================================================
cat > /opt/app/config/otel-collector.yaml <<'OTELEOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
        metrics:
          system.cpu.utilization:
            enabled: true
      memory:
        metrics:
          system.memory.utilization:
            enabled: true
      disk: {}
      filesystem: {}
      network: {}

  filelog:
    include:
      - /var/log/app/*.log
    operators:
      - type: json_parser
        timestamp:
          parse_from: attributes.timestamp
          layout: "%Y-%m-%dT%H:%M:%S.%fZ"
          layout_type: gotime
        severity:
          parse_from: attributes.level
          mapping:
            debug: DEBUG
            info: INFO
            warn: WARN
            error: ERROR
            fatal: FATAL
      - type: move
        from: attributes.message
        to: body
      - type: move
        from: attributes.service
        to: resource["service.name"]

processors:
  batch:
    timeout: 5s
    send_batch_size: 256

  resourcedetection:
    detectors: [env, system]
    system:
      hostname_sources: [os]

  attributes/logs:
    actions:
      - key: event.dataset
        value: app.logs
        action: upsert

exporters:
  elasticsearch:
OTELEOF

# Now append the lines with Terraform-injected values (these cannot be in a
# quoted heredoc because Terraform must interpolate them).
cat >> /opt/app/config/otel-collector.yaml <<OTELEOF2
    endpoints: ["${elasticsearch_url}"]
    api_key: "${api_key}"
OTELEOF2

cat >> /opt/app/config/otel-collector.yaml <<'OTELEOF3'
    logs_dynamic_index:
      enabled: true
    mapping:
      mode: ecs

  debug:
    verbosity: basic

service:
  telemetry:
    logs:
      level: info

  pipelines:
    traces:
      receivers: [otlp]
      processors: [resourcedetection, batch]
      exporters: [elasticsearch]

    metrics:
      receivers: [otlp, hostmetrics]
      processors: [resourcedetection, batch]
      exporters: [elasticsearch]

    logs:
      receivers: [filelog]
      processors: [resourcedetection, attributes/logs, batch]
      exporters: [elasticsearch]
OTELEOF3

chown -R appuser:appuser /opt/app/config

# ==============================================================================
# 9. Systemd unit files
# ==============================================================================

cat > /etc/systemd/system/otelcol.service <<'SVCEOF'
[Unit]
Description=OpenTelemetry Collector Contrib
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/otelcol-contrib --config /opt/app/config/otel-collector.yaml
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/api.service <<'SVCEOF'
[Unit]
Description=OTel Demo API
After=network.target postgresql.service redis-server.service otelcol.service
Requires=postgresql.service redis-server.service

[Service]
Type=simple
WorkingDirectory=/opt/app/api
ExecStart=/usr/bin/opentelemetry-instrument python3 /opt/app/api/main.py
Restart=always
RestartSec=5
User=appuser
Environment=OTEL_SERVICE_NAME=api
Environment=OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
Environment=OTEL_EXPORTER_OTLP_PROTOCOL=grpc
Environment=OTEL_PYTHON_LOG_CORRELATION=true
Environment=OTEL_TRACES_EXPORTER=otlp
Environment=OTEL_METRICS_EXPORTER=otlp
Environment=OTEL_LOGS_EXPORTER=none

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/frontend.service <<'SVCEOF'
[Unit]
Description=OTel Demo Frontend
After=network.target api.service otelcol.service

[Service]
Type=simple
WorkingDirectory=/opt/app/frontend
ExecStart=/usr/bin/opentelemetry-instrument python3 /opt/app/frontend/main.py
Restart=always
RestartSec=5
User=root
Environment=OTEL_SERVICE_NAME=frontend
Environment=OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
Environment=OTEL_EXPORTER_OTLP_PROTOCOL=grpc
Environment=OTEL_PYTHON_LOG_CORRELATION=true
Environment=OTEL_TRACES_EXPORTER=otlp
Environment=OTEL_METRICS_EXPORTER=otlp
Environment=OTEL_LOGS_EXPORTER=none

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/loadgen.service <<'SVCEOF'
[Unit]
Description=OTel Demo Load Generator
After=network.target frontend.service api.service

[Service]
Type=simple
WorkingDirectory=/opt/app/loadgen
ExecStart=python3 /opt/app/loadgen/main.py
Restart=always
RestartSec=10
User=appuser
Environment=OTEL_SERVICE_NAME=loadgen
Environment=OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
Environment=OTEL_EXPORTER_OTLP_PROTOCOL=grpc
Environment=OTEL_PYTHON_LOG_CORRELATION=true
Environment=OTEL_TRACES_EXPORTER=otlp
Environment=OTEL_METRICS_EXPORTER=otlp
Environment=OTEL_LOGS_EXPORTER=none

[Install]
WantedBy=multi-user.target
SVCEOF

# ==============================================================================
# 10. Start all services
# ==============================================================================
systemctl daemon-reload
systemctl enable --now otelcol
sleep 3
systemctl enable --now api
sleep 5
systemctl enable --now frontend
sleep 2
systemctl enable --now loadgen

echo "=== Userdata script completed at $(date -u) ==="
echo "Services status:"
systemctl --no-pager status otelcol api frontend loadgen || true
