"""Discord notifications (webhook)."""
from __future__ import annotations

import logging
import time

import httpx

from .config import Config

log = logging.getLogger(__name__)

COLORS = {5: 0xE74C3C, 4: 0xE67E22, 3: 0xF1C40F}
EMOJI = {5: "🚨", 4: "🔴", 3: "🟠"}


def _cut(text: str, n: int) -> str:
    text = text or "—"
    return text if len(text) <= n else text[: n - 1] + "…"


def _embed_len(e: dict) -> int:
    n = len(e.get("title", "")) + len(e.get("description", "")) + len(e.get("footer", {}).get("text", ""))
    return n + sum(len(f["name"]) + len(f["value"]) for f in e.get("fields", []))


def alert_embed(row, model: str) -> dict:
    sev = row.severity or 4
    sample = row.samples[0] if row.samples else {}
    hosts = sorted({x.get("host") for x in (row.samples or []) if x.get("host")})[:5]
    code = (sample.get("text") or row.template).replace("```", "'''")
    fmt = "%Y-%m-%d %H:%M"
    return {
        "title": _cut(f"{EMOJI.get(sev, '🔴')} [{sev}/5] {row.source}: {row.category or 'incident'}", 250),
        "description": _cut(row.summary, 900),
        "color": COLORS.get(sev, 0xE67E22),
        "fields": [
            {"name": "Recommendation", "value": _cut(row.recommendation, 500), "inline": False},
            {"name": "Sample log", "value": f"```\n{_cut(code, 700)}\n```", "inline": False},
            {"name": "Occurrences", "value": f"{row.hits_since_notify} since the last alert\n{row.hits_total} in total", "inline": True},
            {"name": "Hosts", "value": _cut(", ".join(hosts), 200), "inline": True},
            {"name": "Period (UTC)", "value": f"{row.first_seen.strftime(fmt)} -> {row.last_seen.strftime(fmt)}", "inline": True},
        ],
        "footer": {"text": f"fp {row.id} • {model} • mute: python -m app.cli fp ignore {row.id[:8]}"},
        "timestamp": row.last_seen.isoformat() + "Z",
    }


class DiscordNotifier:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.url = cfg.discord_webhook_url
        self.http = httpx.Client(timeout=15)
        self._last_system: dict[str, float] = {}
        if not self.url:
            log.warning("DISCORD_WEBHOOK_URL is empty - alerts will only be logged")
        elif "/api/webhooks/" not in self.url:
            log.warning("DISCORD_WEBHOOK_URL does not look like a Discord webhook")

    @property
    def enabled(self) -> bool:
        return bool(self.url)

    def _post(self, payload: dict) -> bool:
        if not self.url:
            return False
        for attempt in range(4):
            try:
                r = self.http.post(self.url, json=payload)
            except httpx.HTTPError as e:
                log.warning("Discord: connection error: %s", e)
                time.sleep(2)
                continue
            if r.status_code in (200, 204):
                return True
            if r.status_code == 429:
                try:
                    wait = float(r.json().get("retry_after", 1))
                except Exception:
                    wait = 2.0
                time.sleep(min(wait, 30))
                continue
            if r.status_code >= 500:
                time.sleep(2)
                continue
            log.error("Discord: HTTP %s: %s", r.status_code, r.text[:200])
            return False
        return False

    def send_embeds(self, embeds: list[dict], content: str | None = None) -> list[bool]:
        """Sends embeds in batches (Discord limits: 10 embeds / ~6000 characters). Returns a result per embed."""
        results = [False] * len(embeds)
        if not self.url:
            for e in embeds:
                log.warning("[DRY-RUN] ALERT: %s | %s", e["title"], e.get("description", ""))
            return [True] * len(embeds)  # dry-run mode - treat as delivered
        i, first = 0, True
        while i < len(embeds):
            chunk, size = [], 0
            while i + len(chunk) < len(embeds) and len(chunk) < 10:
                n = _embed_len(embeds[i + len(chunk)])
                if chunk and size + n > 5500:
                    break
                chunk.append(embeds[i + len(chunk)])
                size += n
            payload = {"username": self.cfg.discord_username, "embeds": chunk,
                       "allowed_mentions": {"parse": []}}
            if first and content:
                payload["content"] = content[:1900]
                payload["allowed_mentions"] = {"parse": ["users", "roles", "everyone"]}
            ok = self._post(payload)
            for j in range(len(chunk)):
                results[i + j] = ok
            i += len(chunk)
            first = False
        return results

    def system(self, key: str, title: str, text: str, cooldown_s: int = 3600, color: int = 0x95A5A6) -> None:
        """Rare system notices (e.g. ES/Ollama unavailable) - with a per-key cooldown."""
        now = time.time()
        if now - self._last_system.get(key, 0) < cooldown_s:
            return
        self._last_system[key] = now
        embed = {"title": _cut(f"⚙️ {title}", 250), "description": _cut(text, 1500), "color": color}
        if self.url:
            self._post({"username": self.cfg.discord_username, "embeds": [embed], "allowed_mentions": {"parse": []}})
        else:
            log.warning("[DRY-RUN] SYSTEM: %s | %s", title, text)
