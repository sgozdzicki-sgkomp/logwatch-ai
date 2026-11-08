"""Ollama client: log pattern classification (structured output / JSON schema)."""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass

import httpx

from .config import Config

log = logging.getLogger(__name__)

# Order matters: the model first "thinks" (summary), then decides.
SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "category": {"type": "string"},
        "severity": {"type": "integer", "minimum": 1, "maximum": 5},
        "verdict": {"type": "string", "enum": ["ignore", "watch", "alert"]},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "recommendation": {"type": "string"},
        "ignore_regex": {"type": "string"},
    },
    "required": ["summary", "category", "severity", "verdict", "confidence", "recommendation", "ignore_regex"],
}

SYSTEM = """You are a senior SRE and security engineer triaging log patterns coming from an Elasticsearch cluster.
For the given log pattern decide whether a human must be interrupted.

Verdicts:
- "ignore": harmless or routine noise (successful retries, client disconnects, deprecation warnings, expected
  failures of optional components, health-check chatter, "0 errors" style messages).
- "watch": minor or unclear problem worth tracking, but not worth interrupting a human. It is re-checked
  automatically if its frequency spikes.
- "alert": serious problem needing human attention soon: outages, crashes, OOM, disk full or filesystem errors,
  data loss or corruption, failed backups, RAID/SMART/hardware faults, expired certificates, repeated service
  failures, security incidents (brute force, intrusion, privilege escalation, unexpected admin actions).

Severity: 1 = noise, 2 = minor, 3 = notable, 4 = serious, 5 = critical / ongoing damage.
The operator does NOT want to be flooded: be conservative with "alert", but never ignore anything that suggests
data loss, security compromise or service outage. Decisions marked OPERATOR in the examples are authoritative.

Fields:
- summary: one or two sentences explaining what happens and why it matters (write in {language}).
- category: short label, e.g. "disk", "auth", "network", "database", "application", "noise" (in {language}).
- recommendation: concrete next step for the operator (in {language}); for "ignore" write a short note.
- ignore_regex: ONLY when verdict is "ignore": a Python regular expression (used with re.search, case-insensitive)
  matching this and equally harmless variants of the message. Keep the stable wording, replace variable parts with
  \\d+ or \\S+. It must be specific (at least ~15 letters of fixed text) and must not match error conditions.
  Otherwise return an empty string.
Respond with JSON only."""


@dataclass
class Verdict:
    verdict: str
    severity: int
    confidence: float
    category: str
    summary: str
    recommendation: str
    ignore_regex: str


class OllamaError(Exception):
    pass


def build_user_prompt(info: dict, examples: list[dict]) -> str:
    out: list[str] = []
    if examples:
        out.append("Previously judged patterns (stay consistent with them):")
        for e in examples:
            out.append(f"- [{e['by']}] source={e['source']} | {e['status']} sev={e['severity']} | "
                       f"{e['template']} => {e['summary']}")
        out.append("")
    out.append("Analyse this log pattern.")
    out.append(f"source/service: {info['source']}")
    out.append(f"highest level seen: {info['level']}")
    out.append(f"occurrences so far: {info['hits_total']}")
    out.append(f"reason for analysis: {info['reason']}")
    if info.get("previous"):
        out.append(f"previous verdict: {info['previous']}")
    out.append(f"normalized template: {info['template']}")
    out.append("sample log lines:")
    for i, s in enumerate(info["samples"], 1):
        out.append(f"{i}. [{s.get('level') or '?'}] host={s.get('host') or '?'}: {s['text'][:700]}")
    return "\n".join(out)


class Analyzer:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.http = httpx.Client(base_url=cfg.ollama_base_url, timeout=cfg.ollama_timeout)

    def ping(self) -> str:
        """Returns a status message; raises when the server is unreachable."""
        r = self.http.get("/api/tags", timeout=15)
        r.raise_for_status()
        names = [m.get("name", "") for m in r.json().get("models", [])]
        want = self.cfg.ollama_model
        if any(n == want or n.split(":")[0] == want for n in names):
            return f"model {want} available"
        return f"WARNING: model {want} is not pulled (available: {', '.join(names) or 'none'}) - run: ollama pull {want}"

    def analyze(self, info: dict, examples: list[dict]) -> Verdict:
        cfg = self.cfg
        system = SYSTEM.format(language=cfg.language)
        if cfg.env_context:
            system += f"\n\nEnvironment description from the operator:\n{cfg.env_context}"
        payload = {
            "model": cfg.ollama_model,
            "stream": False,
            "format": SCHEMA,
            "keep_alive": cfg.ollama_keep_alive,
            "options": {"temperature": cfg.ollama_temperature, "num_ctx": cfg.ollama_num_ctx},
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": build_user_prompt(info, examples)}],
        }
        try:
            r = self.http.post("/api/chat", json=payload)
        except httpx.HTTPError as e:
            raise OllamaError(f"connection to Ollama failed: {e}") from e
        if r.status_code >= 400:
            raise OllamaError(f"HTTP {r.status_code}: {r.text[:300]}")
        try:
            content = r.json()["message"]["content"]
        except Exception as e:
            raise OllamaError(f"unexpected response: {r.text[:200]}") from e
        return parse_verdict(content)


def parse_verdict(content: str) -> Verdict:
    text = content.strip()
    text = re.sub(r"^```(?:json)?|```$", "", text, flags=re.M).strip()
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", text, re.S)
        if not m:
            raise OllamaError(f"response is not JSON: {content[:200]}")
        try:
            data = json.loads(m.group(0))
        except json.JSONDecodeError as e:
            raise OllamaError(f"invalid JSON: {e}") from e

    verdict = str(data.get("verdict", "watch")).lower()
    if verdict not in ("ignore", "watch", "alert"):
        verdict = "watch"
    try:
        sev = min(5, max(1, int(data.get("severity", 3))))
    except (TypeError, ValueError):
        sev = 3
    try:
        conf = min(1.0, max(0.0, float(data.get("confidence", 0.5))))
    except (TypeError, ValueError):
        conf = 0.5
    return Verdict(verdict=verdict, severity=sev, confidence=conf,
                   category=str(data.get("category", ""))[:120], summary=str(data.get("summary", ""))[:1500],
                   recommendation=str(data.get("recommendation", ""))[:1000],
                   ignore_regex=str(data.get("ignore_regex", "") or "").strip())
