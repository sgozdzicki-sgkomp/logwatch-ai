"""Database layer (SQLAlchemy) - SQLite / PostgreSQL / MariaDB."""
from __future__ import annotations

import logging
import os
import time
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import (JSON, BigInteger, Boolean, DateTime, Float, Integer, String, Text,
                        create_engine, event)
from sqlalchemy.engine import URL, Engine
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

from .config import Config

log = logging.getLogger(__name__)


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


class Base(DeclarativeBase):
    pass


class State(Base):
    """Simple key-value store: Elasticsearch read cursor, etc."""
    __tablename__ = "state"
    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(Text, default="")


class Fingerprint(Base):
    """Log pattern (normalized template) plus the knowledge gained about it from Ollama or the operator."""
    __tablename__ = "fingerprints"
    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    source: Mapped[str] = mapped_column(String(255), index=True)
    template: Mapped[str] = mapped_column(Text)
    max_level_rank: Mapped[int] = mapped_column(Integer, default=-1)
    # pending | ignore | watch | alert
    status: Mapped[str] = mapped_column(String(16), default="pending", index=True)
    # none | ollama | user | failopen
    verdict_source: Mapped[str] = mapped_column(String(16), default="none")
    severity: Mapped[int] = mapped_column(Integer, default=0)
    confidence: Mapped[float] = mapped_column(Float, default=0.0)
    category: Mapped[str] = mapped_column(String(128), default="")
    summary: Mapped[str] = mapped_column(Text, default="")
    recommendation: Mapped[str] = mapped_column(Text, default="")
    review_reason: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    samples: Mapped[list] = mapped_column(JSON, default=list)
    first_seen: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    last_seen: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    hits_total: Mapped[int] = mapped_column(BigInteger, default=0)
    hits_since_notify: Mapped[int] = mapped_column(BigInteger, default=0)
    ewma_rate: Mapped[float] = mapped_column(Float, default=0.0)
    last_notified: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    last_analyzed: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    expires_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    analysis_count: Mapped[int] = mapped_column(Integer, default=0)


class Rule(Base):
    """An 'ignore' regex rule proposed by Ollama (or added manually), scoped to a single source."""
    __tablename__ = "rules"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    source: Mapped[str] = mapped_column(String(255), index=True)
    pattern: Mapped[str] = mapped_column(Text)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    hits: Mapped[int] = mapped_column(BigInteger, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    created_from: Mapped[str] = mapped_column(String(32), default="")
    note: Mapped[str] = mapped_column(Text, default="")


class Notification(Base):
    __tablename__ = "notifications"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    fp_id: Mapped[str] = mapped_column(String(32), index=True)
    kind: Mapped[str] = mapped_column(String(16), default="alert")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, index=True)


def build_url(cfg: Config) -> URL | str:
    if cfg.db_url:
        return cfg.db_url
    if cfg.db_type == "sqlite":
        return URL.create("sqlite", database=cfg.sqlite_path)
    driver = "postgresql+psycopg2" if cfg.db_type == "postgresql" else "mysql+pymysql"
    query = {"charset": "utf8mb4"} if cfg.db_type == "mariadb" else {}
    return URL.create(driver, username=cfg.db_user, password=cfg.db_password or None,
                      host=cfg.db_host, port=cfg.db_port, database=cfg.db_name, query=query)


def make_engine(cfg: Config) -> Engine:
    url = build_url(cfg)
    is_sqlite = str(url).startswith("sqlite")
    if is_sqlite and not cfg.db_url:
        d = os.path.dirname(cfg.sqlite_path)
        if d:
            os.makedirs(d, exist_ok=True)
    engine = create_engine(url, pool_pre_ping=True, pool_recycle=1800,
                           connect_args={"timeout": 30} if is_sqlite else {})
    if is_sqlite:
        @event.listens_for(engine, "connect")
        def _pragmas(dbapi_conn, _):  # WAL: the CLI can read/write concurrently with the main process
            cur = dbapi_conn.cursor()
            cur.execute("PRAGMA journal_mode=WAL")
            cur.execute("PRAGMA busy_timeout=30000")
            cur.close()
    return engine


def init_db(engine: Engine, attempts: int = 30, delay: float = 2.0) -> None:
    last: Exception | None = None
    for i in range(attempts):
        try:
            Base.metadata.create_all(engine)
            return
        except Exception as e:  # the database may still be starting up
            last = e
            log.warning("Database unavailable (%d/%d): %s", i + 1, attempts, e)
            time.sleep(delay)
    raise RuntimeError(f"Could not connect to the database: {last}")


def get_state(s: Session, key: str, default: str | None = None) -> str | None:
    row = s.get(State, key)
    return row.value if row else default


def set_state(s: Session, key: str, value: str) -> None:
    row = s.get(State, key)
    if row:
        row.value = value
    else:
        s.add(State(key=key, value=value))
