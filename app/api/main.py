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

from app.api.chaos import ChaosMiddleware, chaos_state
from app.api.database import SessionLocal, get_db, init_db, engine
from app.api.models import CartItem, Order, OrderItem, Product

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

redis_client = redis.Redis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379/0"), decode_responses=True)

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
    uvicorn.run("app.api.main:app", host="0.0.0.0", port=8000, log_level="info")
