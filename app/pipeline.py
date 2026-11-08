"""Application core: read -> local filter -> patterns -> (Ollama teaches the filters) -> Discord alerts."""
from __future__ import annotations

import json
import logging
import threading
import time
from collections import Counter
from datetime import timedelta
from pathlib import Path

from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session

from .analyzer import Analyzer, OllamaError, Verdict
from .config import Config
from .db import Fingerprint, Notification, Rule, get_state, set_state, utcnow
from .es_client import ESClient
from .normalize import RANK_NAME, normalize
from .notifier import DiscordNotifier, alert_embed
from .prefilter import CRITICAL_RANK, Prefilter, validate_rule

log = logging.getLogger(__name__)
MAX_SAMPLES = 5


class _Agg:
    __slots__ = ("source", "template", "count", "max_rank", "samples", "texts")

    def __init__(self, ev):
        self.source, self.template = ev.source, ev.template
        self.count, self.max_rank = 0, -1
        self.samples: list[dict] = []
        self.texts: set[str] = set()


def merge_samples(old: list, new: list, cap: int = MAX_SAMPLES) -> list:
    out, seen = [], set()
    for x in list(new) + list(old or []):
        if x["text"] not in seen:
            seen.add(x["text"])
            out.append(x)
    return out[:cap]


class Pipeline:
    def __init__(self, cfg: Config, engine: Engine, es: ESClient, analyzer: Analyzer, notifier: DiscordNotifier):
        self.cfg, self.engine, self.es, self.analyzer, self.notifier = cfg, engine, es, analyzer, notifier
        self.prefilter = Prefilter(cfg)
        self.stop = threading.Event()
        self.es_failures = 0
        self.ollama_failures = 0
        self._last_housekeeping = 0.0

    # ------------------------------------------------------------------ cycle
    def run_cycle(self) -> None:
        t0 = time.monotonic()
        stats = self.ingest()
        self.beat()
        # Alerts for already known (learned) patterns go out immediately - they never wait for a slow Ollama.
        sent = self.dispatch()
        analyzed, sent_during = self.analyze_pending()
        sent += sent_during + self.dispatch()
        self.housekeeping()
        self.beat()
        log.info("cycle %.1fs | read=%d dropped_level=%d dropped_rules=%d candidates=%d new_patterns=%d | analyses=%d alerts=%d",
                 time.monotonic() - t0, stats["seen"], stats["drop_level"], stats["drop_rule"],
                 stats["candidates"], stats["new_patterns"], analyzed, sent)

    def beat(self) -> None:
        try:
            Path(self.cfg.heartbeat_file).touch()
        except OSError:
            pass

    # ---------------------------------------------------------------- ingest
    def ingest(self) -> Counter:
        cfg = self.cfg
        stats: Counter = Counter()
        now_ms = int(time.time() * 1000)
        upper = now_ms - cfg.es_ingest_lag_seconds * 1000

        with Session(self.engine) as s:
            self.prefilter.load_rules(s)
            cursor = int(get_state(s, "cursor_ms", "0") or 0)
            ids = set(json.loads(get_state(s, "cursor_ids", "[]") or "[]"))
        if cursor == 0:
            cursor, ids = now_ms - cfg.es_initial_lookback_minutes * 60_000, set()
        floor = now_ms - cfg.es_max_catchup_hours * 3_600_000
        if cursor < floor:
            log.warning("Cursor is older than %dh - skipping the oldest logs", cfg.es_max_catchup_hours)
            cursor, ids = floor, set()

        cycle_counts: Counter = Counter()
        for _ in range(cfg.es_max_batches_per_cycle):
            try:
                hits = self.es.fetch(cursor, upper, cfg.es_batch_size)
            except Exception as e:
                self._es_failed(e)
                break
            self._es_ok()
            if not hits:
                break

            aggs: dict[str, _Agg] = {}
            for h in hits:
                ts = int(h["sort"][0])
                uid = f"{h.get('_index')}/{h.get('_id')}"
                if ts == cursor and uid in ids:
                    continue
                ev = normalize(h)
                stats["seen"] += 1
                decision = self.prefilter.classify(ev)
                if decision != "candidate":
                    stats["drop_" + decision] += 1
                    continue
                stats["candidates"] += 1
                a = aggs.get(ev.fingerprint)
                if a is None:
                    a = aggs[ev.fingerprint] = _Agg(ev)
                a.count += 1
                a.max_rank = max(a.max_rank, ev.rank)
                if len(a.samples) < 3 and ev.message not in a.texts:
                    a.texts.add(ev.message)
                    a.samples.append(ev.sample())
                cycle_counts[ev.fingerprint] += 1

            last_ts = int(hits[-1]["sort"][0])
            uids = {f"{h.get('_index')}/{h.get('_id')}" for h in hits if int(h["sort"][0]) == last_ts}
            if last_ts == cursor:
                uids |= ids
            full = len(hits) >= cfg.es_batch_size
            if full and last_ts == cursor:  # the whole page falls in the same millisecond - force progress
                new_cursor, new_ids = last_ts + 1, set()
            else:
                new_cursor, new_ids = last_ts, uids

            with Session(self.engine) as s:
                stats["new_patterns"] += self._persist(s, aggs)
                set_state(s, "cursor_ms", str(new_cursor))
                set_state(s, "cursor_ids", json.dumps(sorted(new_ids)))
                s.commit()
            cursor, ids = new_cursor, new_ids
            if not full:
                break

        self._spike_check(cycle_counts)
        self._flush_rule_hits()
        return stats

    def _persist(self, s: Session, aggs: dict[str, _Agg]) -> int:
        created, now = 0, utcnow()
        for fp_id, a in aggs.items():
            row = s.get(Fingerprint, fp_id)
            if row is None:
                s.add(Fingerprint(id=fp_id, source=a.source, template=a.template[:2000], max_level_rank=a.max_rank,
                                  status="pending", review_reason="new pattern", samples=a.samples,
                                  first_seen=now, last_seen=now, hits_total=a.count,
                                  hits_since_notify=a.count, ewma_rate=0.0))
                created += 1
                continue
            row.hits_total += a.count
            row.hits_since_notify += a.count
            row.last_seen = now
            row.max_level_rank = max(row.max_level_rank, a.max_rank)
            row.samples = merge_samples(row.samples, a.samples)
            if (row.status != "pending" and row.verdict_source in ("ollama", "failopen")
                    and row.expires_at and row.expires_at < now):
                row.status, row.review_reason = "pending", "verdict expired (TTL)"
        return created

    def _spike_check(self, counts: Counter) -> None:
        """Self-regulation: an ignored/watched pattern that suddenly intensifies goes back to the model for review."""
        if not counts:
            return
        cfg = self.cfg
        with Session(self.engine) as s:
            for fp_id, n in counts.items():
                row = s.get(Fingerprint, fp_id)
                if row is None:
                    continue
                if (row.status in ("ignore", "watch") and row.verdict_source != "user"
                        and n >= cfg.spike_min_count and n > cfg.spike_factor * max(row.ewma_rate, 1.0)):
                    row.status = "pending"
                    row.review_reason = f"frequency spike ({n} in one cycle, usually ~{row.ewma_rate:.0f})"
                    log.info("Frequency spike for pattern %s - re-analysing", fp_id)
                row.ewma_rate = float(n) if row.ewma_rate <= 0 else 0.8 * row.ewma_rate + 0.2 * n
            s.commit()

    def _flush_rule_hits(self) -> None:
        if not self.prefilter.rule_hits:
            return
        with Session(self.engine) as s:
            for rid, n in self.prefilter.rule_hits.items():
                s.execute(update(Rule).where(Rule.id == rid).values(hits=Rule.hits + n))
            s.commit()
        self.prefilter.rule_hits.clear()

    # --------------------------------------------------------------- analiza
    def analyze_pending(self) -> tuple[int, int]:
        """Evaluates new patterns. Returns (number of verdicts, number of alerts sent).
        An alert is sent immediately after its verdict, not after the whole batch of analyses."""
        cfg = self.cfg
        t_start = time.monotonic()
        with Session(self.engine) as s:
            backlog = s.scalar(select(func.count()).select_from(Fingerprint).where(Fingerprint.status == "pending")) or 0
            ids = list(s.scalars(select(Fingerprint.id).where(Fingerprint.status == "pending")
                                 .order_by(Fingerprint.max_level_rank.desc(), Fingerprint.hits_total.desc())
                                 .limit(cfg.ollama_max_calls_per_cycle)))
        if backlog > 300:
            self.notifier.system("backlog", "Large queue of new patterns",
                                 f"{backlog} patterns are waiting for evaluation and the limit is {cfg.ollama_max_calls_per_cycle} "
                                 f"requests per cycle. Consider ES_EXTRA_QUERY, PREFILTER_MIN_LEVEL or a higher limit.")
        done = sent = attempted = 0
        for fp_id in ids:
            if self.stop.is_set():
                break
            if attempted and time.monotonic() - t_start > cfg.ollama_cycle_budget:
                log.info("Analysis time budget (%ss) exhausted - remaining patterns wait for the next cycle",
                         cfg.ollama_cycle_budget)
                break
            alerted = give_up = False
            with Session(self.engine) as s:
                row = s.get(Fingerprint, fp_id)
                if row is None or row.status != "pending":
                    continue
                attempted += 1
                info = {
                    "source": row.source, "level": RANK_NAME.get(row.max_level_rank, "unknown"),
                    "hits_total": row.hits_total, "reason": row.review_reason or "nowy wzorzec",
                    "template": row.template, "samples": (row.samples or [])[:3],
                    "previous": f"{row.summary} (severity {row.severity})" if row.analysis_count else None,
                }
                try:
                    verdict = self.analyzer.analyze(info, self._examples(s, row))
                except OllamaError as e:
                    self.ollama_failures += 1
                    log.warning("Ollama: %s", e)
                    self._failopen(row)
                    alerted = row.status == "alert"
                    s.commit()
                    if self.ollama_failures >= 3:
                        self.notifier.system("ollama_down", "Ollama unavailable",
                                             f"No valid responses from {self.cfg.ollama_base_url} "
                                             f"({self.cfg.ollama_model}): {e}")
                        give_up = True
                else:
                    self.ollama_failures = 0
                    self._apply(s, row, verdict)
                    alerted = row.status == "alert"
                    s.commit()
                    done += 1
            if alerted:  # after the session is closed so we do not block writes (SQLite)
                sent += self.dispatch()
            self.beat()
            if give_up:
                break
        return done, sent

    def _examples(self, s: Session, row: Fingerprint) -> list[dict]:
        out: list[dict] = []
        seen = {row.id}
        base = select(Fingerprint).where(Fingerprint.status != "pending")

        def add(rows):
            for r in rows:
                if r.id in seen or len(out) >= 14:
                    continue
                seen.add(r.id)
                out.append({"by": "OPERATOR" if r.verdict_source == "user" else "MODEL", "source": r.source,
                            "status": r.status, "severity": r.severity, "template": r.template[:200],
                            "summary": (r.summary or "")[:150]})

        add(s.scalars(base.where(Fingerprint.verdict_source == "user").order_by(Fingerprint.last_seen.desc()).limit(6)))
        add(s.scalars(base.where(Fingerprint.verdict_source == "ollama", Fingerprint.source == row.source)
                      .order_by(Fingerprint.last_analyzed.desc()).limit(4)))
        add(s.scalars(base.where(Fingerprint.verdict_source == "ollama", Fingerprint.status == "alert")
                      .order_by(Fingerprint.last_analyzed.desc()).limit(2)))
        add(s.scalars(base.where(Fingerprint.verdict_source == "ollama", Fingerprint.status == "ignore")
                      .order_by(Fingerprint.last_analyzed.desc()).limit(2)))
        return out

    def _apply(self, s: Session, row: Fingerprint, v: Verdict) -> None:
        cfg, now = self.cfg, utcnow()
        status = v.verdict
        if status == "alert" and v.severity < cfg.alert_min_severity:
            status = "watch"
        if status == "ignore" and (v.confidence < cfg.ignore_min_confidence or row.max_level_rank >= CRITICAL_RANK):
            status = "watch"  # uncertain or critical+ level => never silence permanently
        ttl = {"ignore": cfg.ttl_ignore_days, "watch": cfg.ttl_watch_days, "alert": cfg.ttl_alert_days}[status]
        row.status, row.verdict_source = status, "ollama"
        row.severity, row.confidence = v.severity, v.confidence
        row.category, row.summary, row.recommendation = v.category, v.summary, v.recommendation
        row.review_reason, row.last_analyzed = None, now
        row.expires_at = now + timedelta(days=ttl)
        row.analysis_count += 1
        log.info("Verdict %s [%s] -> %s (sev=%d, conf=%.2f): %s", row.id, row.source, status,
                 v.severity, v.confidence, v.summary[:100])
        if status == "ignore" and v.ignore_regex and cfg.learn_regex_rules:
            self._learn_rule(s, row, v.ignore_regex)

    def _learn_rule(self, s: Session, row: Fingerprint, pattern: str) -> None:
        alert_texts = [x["text"] for samples in s.scalars(
            select(Fingerprint.samples).where(Fingerprint.status == "alert").limit(300)) for x in (samples or [])]
        ok, why = validate_rule(pattern, [x["text"] for x in row.samples or []], alert_texts)
        if not ok:
            log.info("Rejected the model's rule for %s: %s (%s)", row.id, why, pattern[:80])
            return
        exists = s.scalar(select(Rule.id).where(Rule.source == row.source, Rule.pattern == pattern))
        if exists:
            return
        s.add(Rule(source=row.source, pattern=pattern, created_from=row.id, note=(row.summary or "")[:500]))
        log.info("New ignore rule for %s: %s", row.source, pattern[:100])

    def _failopen(self, row: Fingerprint) -> None:
        if self.cfg.ollama_fail_open and row.max_level_rank >= CRITICAL_RANK and row.status == "pending":
            row.status, row.verdict_source = "alert", "failopen"
            row.severity, row.category = 4, "unverified"
            row.summary = "Critical-level entry - Ollama unavailable, no model analysis (preliminary alert)."
            row.recommendation = "Check the log manually."
            row.expires_at = utcnow()  # on the next occurrence it goes back to the model for review

    # ---------------------------------------------------------------- alerts
    def dispatch(self) -> int:
        cfg, now = self.cfg, utcnow()
        sent_total = 0
        with Session(self.engine) as s:
            used = s.scalar(select(func.count()).select_from(Notification).where(
                Notification.kind == "alert", Notification.created_at >= now - timedelta(hours=1))) or 0
            budget = max(0, cfg.max_alerts_per_hour - used)
            cutoff = now - timedelta(minutes=cfg.alert_cooldown_minutes)
            rows = list(s.scalars(select(Fingerprint).where(
                Fingerprint.status == "alert", Fingerprint.hits_since_notify > 0,
                or_(Fingerprint.last_notified.is_(None), Fingerprint.last_notified < cutoff))
                .order_by(Fingerprint.severity.desc(), Fingerprint.last_seen.desc())))
            if not rows:
                return 0
            skipped = max(0, len(rows) - budget)
            rows = rows[:budget]
            if skipped:
                self.notifier.system("ratelimit", "Hourly alert limit",
                                     f"The limit of {cfg.max_alerts_per_hour} alerts/h has been reached. "
                                     f"{skipped} more are waiting and will be sent in later cycles.")
            if not rows:
                return 0
            mention = cfg.discord_mention if any((r.severity or 0) >= 5 for r in rows) else None
            results = self.notifier.send_embeds([alert_embed(r, cfg.ollama_model) for r in rows], content=mention)
            for r, ok in zip(rows, results):
                if ok:
                    r.last_notified, r.hits_since_notify = now, 0
                    s.add(Notification(fp_id=r.id, kind="alert", created_at=now))
                    sent_total += 1
            s.commit()
        return sent_total

    # ------------------------------------------------------- connection state
    def _es_failed(self, e: Exception) -> None:
        self.es_failures += 1
        log.warning("Elasticsearch unavailable (%d): %s", self.es_failures, e)
        if self.es_failures == self.cfg.es_fail_notice_after:
            self.notifier.system("es_down", "Elasticsearch unavailable",
                                 f"{self.es_failures} failed cycles in a row ({self.cfg.es_base_url}): {e}",
                                 color=0xE67E22)

    def _es_ok(self) -> None:
        if self.es_failures >= self.cfg.es_fail_notice_after:
            self.notifier.system("es_up", "Elasticsearch available again", "Log reading has resumed.",
                                 cooldown_s=60, color=0x2ECC71)
        self.es_failures = 0

    # ----------------------------------------------------------- housekeeping
    def housekeeping(self) -> None:
        if time.time() - self._last_housekeeping < 6 * 3600:
            return
        self._last_housekeeping = time.time()
        now = utcnow()
        with Session(self.engine) as s:
            n = s.execute(delete(Fingerprint).where(
                Fingerprint.last_seen < now - timedelta(days=self.cfg.retention_days),
                Fingerprint.verdict_source != "user")).rowcount
            s.execute(delete(Notification).where(Notification.created_at < now - timedelta(days=30)))
            s.commit()
        log.info("Housekeeping: removed %s inactive patterns", n)
