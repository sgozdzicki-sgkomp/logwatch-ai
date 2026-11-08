"""Minimal Elasticsearch REST client (independent of the client library version)."""
from __future__ import annotations

import logging
from urllib.parse import quote

import httpx

from .config import Config

log = logging.getLogger(__name__)


class ESError(Exception):
    pass


class ESClient:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        headers, auth = {}, None
        if cfg.es_api_key:
            headers["Authorization"] = f"ApiKey {cfg.es_api_key}"
        elif cfg.es_username:
            auth = (cfg.es_username, cfg.es_password)
        verify: bool | str = cfg.es_ca_cert or cfg.es_verify_certs
        self.http = httpx.Client(base_url=cfg.es_base_url, headers=headers, auth=auth,
                                 verify=verify, timeout=cfg.es_timeout)

    def health(self) -> dict:
        r = self.http.get("/")
        if r.status_code >= 400:
            raise ESError(f"HTTP {r.status_code}: {r.text[:200]}")
        j = r.json()
        return {"name": j.get("cluster_name"), "version": (j.get("version") or {}).get("number")}

    def fetch(self, from_ms: int, to_ms: int, size: int) -> list[dict]:
        """Documents in the range [from_ms, to_ms], ascending by time. sort[0] = epoch ms."""
        ts = self.cfg.es_timestamp_field
        filters: list[dict] = [{"range": {ts: {"gte": from_ms, "lte": to_ms, "format": "epoch_millis"}}}]
        if self.cfg.es_extra_query:
            filters.append({"query_string": {"query": self.cfg.es_extra_query, "default_operator": "AND"}})
        body = {
            "size": size,
            "track_total_hits": False,
            "sort": [{ts: {"order": "asc", "unmapped_type": "date", "numeric_type": "date"}}],
            "query": {"bool": {"filter": filters}},
        }
        path = f"/{quote(self.cfg.es_index, safe='*,-.:_+')}/_search"
        r = self.http.post(path, params={"ignore_unavailable": "true", "allow_no_indices": "true"}, json=body)
        if r.status_code >= 400:
            raise ESError(f"HTTP {r.status_code}: {r.text[:300]}")
        j = r.json()
        sh = j.get("_shards") or {}
        if sh.get("failed"):
            log.warning("Elasticsearch: %s shards failed (results may be incomplete)", sh["failed"])
        return j.get("hits", {}).get("hits", [])
