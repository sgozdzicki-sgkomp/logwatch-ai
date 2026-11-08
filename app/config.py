"""Configuration read exclusively from environment variables (the .env file)."""
from __future__ import annotations

import os
from dataclasses import dataclass

LEVEL_NAMES = ("trace", "debug", "info", "warn", "error", "critical")


def _get(name: str, default: str = "") -> str:
    v = os.getenv(name)
    return default if v is None or not v.strip() else v.strip()


def _int(name: str, default: int) -> int:
    raw = _get(name, str(default))
    try:
        return int(raw)
    except ValueError:
        raise SystemExit(f"[config] {name}={raw!r} is not an integer")


def _float(name: str, default: float) -> float:
    raw = _get(name, str(default))
    try:
        return float(raw)
    except ValueError:
        raise SystemExit(f"[config] {name}={raw!r} is not a number")


def _bool(name: str, default: bool) -> bool:
    return _get(name, "true" if default else "false").lower() in ("1", "true", "yes", "y", "on", "tak")


def _list(name: str) -> list[str]:
    return [x.strip() for x in _get(name).split(",") if x.strip()]


def _host(h: str) -> str:
    return f"[{h}]" if ":" in h and not h.startswith("[") else h


@dataclass(frozen=True)
class Config:
    log_level: str
    poll_interval: int
    heartbeat_file: str

    # Elasticsearch
    es_scheme: str
    es_host: str
    es_port: int
    es_username: str
    es_password: str
    es_api_key: str
    es_verify_certs: bool
    es_ca_cert: str
    es_index: str
    es_timestamp_field: str
    es_extra_query: str
    es_batch_size: int
    es_max_batches_per_cycle: int
    es_ingest_lag_seconds: int
    es_initial_lookback_minutes: int
    es_max_catchup_hours: int
    es_timeout: int
    es_fail_notice_after: int

    # Ollama
    ollama_scheme: str
    ollama_host: str
    ollama_port: int
    ollama_model: str
    ollama_timeout: int
    ollama_num_ctx: int
    ollama_temperature: float
    ollama_keep_alive: str
    ollama_max_calls_per_cycle: int
    ollama_cycle_budget: int
    ollama_fail_open: bool
    language: str
    env_context: str

    # Discord
    discord_webhook_url: str
    discord_username: str
    discord_mention: str
    alert_cooldown_minutes: int
    max_alerts_per_hour: int

    # Filters
    prefilter_min_level: str
    prefilter_extra_keywords: list
    alert_min_severity: int
    ignore_min_confidence: float
    learn_regex_rules: bool
    ttl_ignore_days: int
    ttl_watch_days: int
    ttl_alert_days: int
    spike_min_count: int
    spike_factor: float
    retention_days: int

    # Database
    db_type: str
    db_url: str
    sqlite_path: str
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str

    @property
    def es_base_url(self) -> str:
        return f"{self.es_scheme}://{_host(self.es_host)}:{self.es_port}"

    @property
    def ollama_base_url(self) -> str:
        return f"{self.ollama_scheme}://{_host(self.ollama_host)}:{self.ollama_port}"


def load_config() -> Config:
    es_scheme = _get("ES_SCHEME", "http").lower()
    ollama_scheme = _get("OLLAMA_SCHEME", "http").lower()
    for n, v in (("ES_SCHEME", es_scheme), ("OLLAMA_SCHEME", ollama_scheme)):
        if v not in ("http", "https"):
            raise SystemExit(f"[config] {n} must be http or https")

    es_host, ollama_host = _get("ES_HOST"), _get("OLLAMA_HOST")
    if not es_host:
        raise SystemExit("[config] ES_HOST is missing in .env")
    if not ollama_host:
        raise SystemExit("[config] OLLAMA_HOST is missing in .env")

    db_type = _get("DB_TYPE", "sqlite").lower()
    if db_type in ("postgres", "pg"):
        db_type = "postgresql"
    if db_type not in ("sqlite", "postgresql", "mariadb"):
        raise SystemExit("[config] DB_TYPE must be one of: sqlite | postgresql | mariadb")
    default_port = {"postgresql": 5432, "mariadb": 3306, "sqlite": 0}[db_type]

    min_level = _get("PREFILTER_MIN_LEVEL", "warn").lower()
    if min_level not in LEVEL_NAMES:
        raise SystemExit(f"[config] PREFILTER_MIN_LEVEL must be one of: {', '.join(LEVEL_NAMES)}")

    cfg = Config(
        log_level=_get("LOG_LEVEL", "INFO").upper(),
        poll_interval=max(5, _int("POLL_INTERVAL_SECONDS", 30)),
        heartbeat_file=_get("HEARTBEAT_FILE", "/tmp/logwatch.heartbeat"),
        es_scheme=es_scheme, es_host=es_host, es_port=_int("ES_PORT", 9200),
        es_username=_get("ES_USERNAME"), es_password=_get("ES_PASSWORD"), es_api_key=_get("ES_API_KEY"),
        es_verify_certs=_bool("ES_VERIFY_CERTS", True), es_ca_cert=_get("ES_CA_CERT"),
        es_index=_get("ES_INDEX", "*"), es_timestamp_field=_get("ES_TIMESTAMP_FIELD", "@timestamp"),
        es_extra_query=_get("ES_EXTRA_QUERY"),
        es_batch_size=max(10, _int("ES_BATCH_SIZE", 500)),
        es_max_batches_per_cycle=max(1, _int("ES_MAX_BATCHES_PER_CYCLE", 10)),
        es_ingest_lag_seconds=max(0, _int("ES_INGEST_LAG_SECONDS", 5)),
        es_initial_lookback_minutes=max(1, _int("ES_INITIAL_LOOKBACK_MINUTES", 15)),
        es_max_catchup_hours=max(1, _int("ES_MAX_CATCHUP_HOURS", 6)),
        es_timeout=_int("ES_TIMEOUT_SECONDS", 30),
        es_fail_notice_after=max(1, _int("ES_FAIL_NOTICE_AFTER", 5)),
        ollama_scheme=ollama_scheme, ollama_host=ollama_host, ollama_port=_int("OLLAMA_PORT", 11434),
        ollama_model=_get("OLLAMA_MODEL", "qwen2.5:14b"),
        ollama_timeout=_int("OLLAMA_TIMEOUT_SECONDS", 300),
        ollama_num_ctx=_int("OLLAMA_NUM_CTX", 4096),
        ollama_temperature=_float("OLLAMA_TEMPERATURE", 0.1),
        ollama_keep_alive=_get("OLLAMA_KEEP_ALIVE", "10m"),
        ollama_max_calls_per_cycle=max(1, _int("OLLAMA_MAX_CALLS_PER_CYCLE", 8)),
        ollama_cycle_budget=max(10, _int("OLLAMA_CYCLE_BUDGET_SECONDS", 120)),
        ollama_fail_open=_bool("OLLAMA_FAIL_OPEN", True),
        language=_get("LANGUAGE", "pl"), env_context=_get("ENV_CONTEXT"),
        discord_webhook_url=_get("DISCORD_WEBHOOK_URL"), discord_username=_get("DISCORD_USERNAME", "LogWatch AI"),
        discord_mention=_get("DISCORD_MENTION"),
        alert_cooldown_minutes=_int("ALERT_COOLDOWN_MINUTES", 60),
        max_alerts_per_hour=max(1, _int("MAX_ALERTS_PER_HOUR", 20)),
        prefilter_min_level=min_level, prefilter_extra_keywords=_list("PREFILTER_EXTRA_KEYWORDS"),
        alert_min_severity=min(5, max(1, _int("ALERT_MIN_SEVERITY", 4))),
        ignore_min_confidence=_float("IGNORE_MIN_CONFIDENCE", 0.7),
        learn_regex_rules=_bool("LEARN_REGEX_RULES", True),
        ttl_ignore_days=_int("VERDICT_TTL_DAYS_IGNORE", 14),
        ttl_watch_days=_int("VERDICT_TTL_DAYS_WATCH", 3),
        ttl_alert_days=_int("VERDICT_TTL_DAYS_ALERT", 7),
        spike_min_count=_int("SPIKE_MIN_COUNT", 50), spike_factor=_float("SPIKE_FACTOR", 5),
        retention_days=_int("FINGERPRINT_RETENTION_DAYS", 60),
        db_type=db_type, db_url=_get("DB_URL"), sqlite_path=_get("SQLITE_PATH", "/data/logwatch.sqlite3"),
        db_host=_get("DB_HOST"), db_port=_int("DB_PORT", default_port),
        db_name=_get("DB_NAME", "logwatch"), db_user=_get("DB_USER", "logwatch"), db_password=_get("DB_PASSWORD"),
    )
    if cfg.db_type != "sqlite" and not cfg.db_url and not cfg.db_host:
        raise SystemExit("[config] Set DB_HOST for DB_TYPE=postgresql/mariadb (bundled database: postgres / mariadb)")
    return cfg
