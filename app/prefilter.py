"""Cheap local pre-filter (no Ollama): level + keywords + rules learned from the model."""
from __future__ import annotations

import logging
import re
from collections import Counter

from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import Config
from .db import Rule
from .normalize import LEVEL_RANK, LogEvent

log = logging.getLogger(__name__)

DEFAULT_KEYWORDS = (
    r"error|exception|fail(?:ed|ure|ing|s)?|fatal|panic|critical|denied|refused|time[ds]? ?out|timeout|"
    r"unreachable|\boom\b|out of memory|segfault|segmentation|corrupt|unauthori[sz]ed|forbidden|crash|"
    r"traceback|deadlock|disk full|no space left|broken pipe|connection reset|cannot|could not|unable to|"
    r"i/o error|authentication fail|invalid user|brute.?force|attack|intrusion|ransom|breach|"
    r"certificate.{0,20}expired|stack ?trace|read-only file ?system|raid|degraded|smart"
)
CRITICAL_RANK = LEVEL_RANK["critical"]
_NESTED_QUANT = re.compile(r"\([^()]*[*+}][^()]*\)\s*[*+{]")


class Prefilter:
    def __init__(self, cfg: Config):
        self.min_rank = LEVEL_RANK[cfg.prefilter_min_level]
        extra = "".join("|" + re.escape(k) for k in cfg.prefilter_extra_keywords)
        self.kw = re.compile(DEFAULT_KEYWORDS + extra, re.I)
        self.rules: dict[str, list[tuple[int, re.Pattern]]] = {}
        self.rule_hits: Counter = Counter()

    def load_rules(self, s: Session) -> None:
        self.rules = {}
        for r in s.scalars(select(Rule).where(Rule.active.is_(True))):
            try:
                self.rules.setdefault(r.source, []).append((r.id, re.compile(r.pattern, re.I)))
            except re.error:
                log.warning("Skipped invalid rule #%s", r.id)

    def classify(self, ev: LogEvent) -> str:
        """candidate | rule | level"""
        if ev.rank >= CRITICAL_RANK:  # critical+ is never dropped locally
            return "candidate"
        for rid, rx in self.rules.get(ev.source, ()):
            if rx.search(ev.message):
                self.rule_hits[rid] += 1
                return "rule"
        if ev.rank >= self.min_rank:
            return "candidate"
        if 0 <= ev.rank <= 1:  # trace/debug
            return "level"
        return "candidate" if self.kw.search(ev.message) else "level"


def validate_rule(pattern: str, samples: list[str], alert_texts: list[str]) -> tuple[bool, str]:
    """Validates a regex proposed by the model. Returns (ok, rejection_reason)."""
    if not pattern or len(pattern) > 300:
        return False, "empty or too long"
    if _NESTED_QUANT.search(pattern):
        return False, "nested quantifiers (ReDoS risk)"
    try:
        rx = re.compile(pattern, re.I)
    except re.error as e:
        return False, f"invalid regex: {e}"
    stripped = re.sub(r"\(\?[^)]*\)|\[[^\]]*\]", "", re.sub(r"\\.", "", pattern))
    if len(re.findall(r"[A-Za-z]", stripped)) < 15:
        return False, "too generic (not enough fixed text)"
    if not samples or not all(rx.search(t) for t in samples[:3]):
        return False, "does not match the samples"
    if any(rx.search(t) for t in alert_texts):
        return False, "matches a pattern flagged as alerting"
    return True, ""
