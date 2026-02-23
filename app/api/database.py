import os

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://ecommerce:ecommerce@localhost:5432/ecommerce")

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
    from app.api.models import Product, Order, OrderItem, CartItem  # noqa: F401

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
