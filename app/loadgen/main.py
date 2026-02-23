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
import os
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

FRONTEND_BASE = os.environ.get("FRONTEND_BASE", "http://localhost")
API_BASE = os.environ.get("API_BASE", "http://localhost:8000")

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
