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

from app.logging import JSONFormatter


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

API_BASE = os.environ.get("API_BASE", "http://localhost:8000")

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Frontend starting")
    app.state.http_client = httpx.AsyncClient(base_url=API_BASE, timeout=60.0)
    yield
    await app.state.http_client.aclose()
    logger.info("Frontend shutting down")


app = FastAPI(title="E-Commerce Frontend", version="1.0.0", lifespan=lifespan)


# ---------------------------------------------------------------------------
# HTTP client helper with W3C trace propagation
# ---------------------------------------------------------------------------

async def api_call(method: str, path: str, **kwargs):
    """Make an HTTP call to the backend API with trace context propagation."""
    headers = kwargs.pop("headers", {})
    inject(headers)
    client = app.state.http_client
    resp = await client.request(method, path, headers=headers, **kwargs)
    return resp

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
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run("app.frontend.main:app", host="0.0.0.0", port=80, log_level="info")
