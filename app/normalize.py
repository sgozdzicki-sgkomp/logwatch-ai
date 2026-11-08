"""Normalizes ES documents into LogEvent objects and builds the log pattern fingerprint."""
from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass

MAX_MSG = 2000

LEVEL_RANK = {"trace": 0, "debug": 1, "info": 2, "warn": 3, "error": 4, "critical": 5, "emergency": 6}
RANK_NAME = {-1: "unknown", 0: "trace", 1: "debug", 2: "info", 3: "warn", 4: "error", 5: "critical", 6: "emergency"}

_ALIASES = {
    "trace": "trace", "verbose": "trace", "finest": "trace", "debug": "debug", "fine": "debug",
    "info": "info", "information": "info", "informational": "info", "notice": "info",
    "warn": "warn", "warning": "warn", "error": "error", "err": "error", "severe": "error",
    "critical": "critical", "crit": "critical", "fatal": "critical", "alert": "critical",
    "emerg": "emergency", "emergency": "emergency", "panic": "emergency",
}
_SYSLOG_NUM = {0: "emergency", 1: "critical", 2: "critical", 3: "error", 4: "warn", 5: "info", 6: "info", 7: "debug"}
_PINO_NUM = {10: "trace", 20: "debug", 30: "info", 40: "warn", 50: "error", 60: "critical"}

MESSAGE_FIELDS = ["message", "log.original", "event.original", "msg", "log", "body", "text"]
LEVEL_FIELDS = ["log.level", "level", "severity", "log_level", "loglevel", "syslog.severity_label",
                "syslog.severity", "event.severity", "log.syslog.severity.name"]
SERVICE_FIELDS = ["service.name", "kubernetes.container.name", "container.name", "docker.container.name",
                  "process.name", "program", "log.logger", "logger_name"]
HOST_FIELDS = ["host.name", "hostname", "host", "agent.hostname", "agent.name", "kubernetes.node.name"]

_LEVEL_IN_MSG = re.compile(
    r"\b(TRACE|DEBUG|INFO|NOTICE|WARN(?:ING)?|ERROR|ERR|SEVERE|CRIT(?:ICAL)?|FATAL|ALERT|EMERG(?:ENCY)?|PANIC)\b")

_SUBS = [
    (re.compile(r"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"), "<TS>"),
    (re.compile(r"\b[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\b"), "<TS>"),
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<UUID>"),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"), "<IP>"),
    (re.compile(r"\b0x[0-9a-fA-F]+\b"), "<HEX>"),
    (re.compile(r"\b[0-9a-fA-F]{16,}\b"), "<HEX>"),
    (re.compile(r"\b\d+(?:\.\d+)?\b"), "<N>"),
]


def get_field(src: dict, path: str):
    """Supports both nested objects and flat keys containing dots."""
    if path in src:
        return src[path]
    cur = src
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur


def parse_level(value) -> str | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        n = int(value)
        return (_PINO_NUM if n >= 10 else _SYSLOG_NUM).get(n)
    s = str(value).strip().lower()
    if s.isdigit():
        return parse_level(int(s))
    return _ALIASES.get(s)


def _first_str(src: dict, paths: list[str]) -> str | None:
    for p in paths:
        v = get_field(src, p)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return None


def index_base(index: str) -> str:
    s = re.sub(r"^\.ds-", "", index)
    s = re.sub(r"-\d{6}$", "", s)
    s = re.sub(r"[-_.]?\d{4}[.\-]\d{2}(?:[.\-]\d{2})?$", "", s)
    return s or index


def make_template(msg: str) -> str:
    t = msg.strip()[:400]
    for rx, repl in _SUBS:
        t = rx.sub(repl, t)
    return re.sub(r"\s+", " ", t).strip()


@dataclass
class LogEvent:
    uid: str
    ts_ms: int
    message: str
    level: str | None
    rank: int
    source: str
    host: str
    template: str
    fingerprint: str

    def sample(self) -> dict:
        return {"text": self.message[:600], "host": self.host, "ts": self.ts_ms, "level": self.level or ""}


def normalize(hit: dict) -> LogEvent:
    src = hit.get("_source") or {}
    index = hit.get("_index", "")
    msg = _first_str(src, MESSAGE_FIELDS)
    if msg is None:
        msg = json.dumps(src, ensure_ascii=False, default=str)
    msg = msg[:MAX_MSG]

    level = None
    for p in LEVEL_FIELDS:
        level = parse_level(get_field(src, p))
        if level:
            break
    if level is None:
        m = _LEVEL_IN_MSG.search(msg[:150])
        if m:
            level = parse_level(m.group(1))

    host = _first_str(src, HOST_FIELDS) or ""
    source = (_first_str(src, SERVICE_FIELDS) or host or index_base(index) or "unknown")[:255]
    template = make_template(msg)
    fp = hashlib.sha1(f"{source}\x1f{template}".encode("utf-8", "replace")).hexdigest()[:16]
    sort = hit.get("sort") or [0]
    return LogEvent(uid=f"{index}/{hit.get('_id')}", ts_ms=int(sort[0]), message=msg, level=level,
                    rank=LEVEL_RANK.get(level, -1), source=source, host=host, template=template, fingerprint=fp)
