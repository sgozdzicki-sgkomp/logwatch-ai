"""Entry point: the always-running main loop."""
from __future__ import annotations

import logging
import signal
import time

from .analyzer import Analyzer
from .config import load_config
from .db import init_db, make_engine
from .es_client import ESClient
from .notifier import DiscordNotifier
from .pipeline import Pipeline

log = logging.getLogger("logwatch")


def build_pipeline(cfg) -> Pipeline:
    engine = make_engine(cfg)
    init_db(engine)
    return Pipeline(cfg, engine, ESClient(cfg), Analyzer(cfg), DiscordNotifier(cfg))


def main() -> None:
    cfg = load_config()
    logging.basicConfig(level=cfg.log_level, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)

    log.info("Starting | ES=%s idx=%s | Ollama=%s model=%s | DB=%s | interval=%ss",
             cfg.es_base_url, cfg.es_index, cfg.ollama_base_url, cfg.ollama_model,
             cfg.db_type if not cfg.db_url else "DB_URL", cfg.poll_interval)
    pipe = build_pipeline(cfg)

    for name, fn in (("Elasticsearch", lambda: pipe.es.health()), ("Ollama", lambda: pipe.analyzer.ping())):
        try:
            log.info("%s: %s", name, fn())
        except Exception as e:  # do not abort - the services may come up later
            log.warning("%s unavailable at startup: %s", name, e)

    def _stop(signum, _frame):
        log.info("Signal %s received - finishing the current step and stopping", signum)
        pipe.stop.set()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    while not pipe.stop.is_set():
        t0 = time.monotonic()
        try:
            pipe.run_cycle()
        except Exception:
            log.exception("Unexpected error in cycle")
            pipe.beat()
        pipe.stop.wait(max(1.0, cfg.poll_interval - (time.monotonic() - t0)))
    log.info("Stopped")


if __name__ == "__main__":
    main()
