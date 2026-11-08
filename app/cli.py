"""Admin tool: docker compose exec logwatch python -m app.cli <command>"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .analyzer import Analyzer
from .config import load_config
from .db import Fingerprint, Notification, Rule, State, init_db, make_engine, utcnow
from .es_client import ESClient
from .normalize import RANK_NAME
from .notifier import DiscordNotifier
from .prefilter import validate_rule


def _resolve(s: Session, prefix: str) -> Fingerprint:
    rows = s.scalars(select(Fingerprint).where(Fingerprint.id.like(prefix + "%"))).all()
    if len(rows) != 1:
        sys.exit(f"Found {len(rows)} patterns for '{prefix}' (exactly 1 required)")
    return rows[0]


def main(argv=None) -> None:
    p = argparse.ArgumentParser(prog="logwatch")
    sub = p.add_subparsers(dest="cmd", required=True)

    fp = sub.add_parser("fp", help="log patterns").add_subparsers(dest="sub", required=True)
    l = fp.add_parser("list"); l.add_argument("--status", choices=["pending", "ignore", "watch", "alert"]); l.add_argument("--limit", type=int, default=30)
    for name, helptext in (("show", "details"), ("ignore", "silence permanently (operator decision)"),
                           ("alert", "always alert (operator decision)"), ("watch", "watch only, no alerts (operator decision)"),
                           ("reset", "send back to Ollama for re-evaluation")):
        fp.add_parser(name, help=helptext).add_argument("id")

    rule = sub.add_parser("rule", help="regex rules").add_subparsers(dest="sub", required=True)
    rule.add_parser("list")
    ra = rule.add_parser("add"); ra.add_argument("source"); ra.add_argument("pattern")
    rule.add_parser("disable").add_argument("id", type=int)

    sub.add_parser("stats", help="statistics")
    sub.add_parser("check", help="connectivity test: Elasticsearch, Ollama, Discord")
    a = p.parse_args(argv)

    cfg = load_config()
    engine = make_engine(cfg)
    init_db(engine)

    if a.cmd == "check":
        for name, fn in (("Elasticsearch", lambda: ESClient(cfg).health()), ("Ollama", lambda: Analyzer(cfg).ping())):
            try:
                print(f"[OK]   {name}: {fn()}")
            except Exception as e:
                print(f"[FAIL] {name}: {e}")
        n = DiscordNotifier(cfg)
        if n.enabled:
            n.system("test", "LogWatch AI test", "The webhook works.", cooldown_s=0, color=0x2ECC71)
            print("[OK]   Discord: test message sent")
        else:
            print("[WARN] Discord: DISCORD_WEBHOOK_URL is not set")
        return

    with Session(engine) as s:
        if a.cmd == "stats":
            by = dict(s.execute(select(Fingerprint.status, func.count()).group_by(Fingerprint.status)).all())
            rules = s.scalar(select(func.count()).select_from(Rule).where(Rule.active.is_(True)))
            day = s.scalar(select(func.count()).select_from(Notification).where(
                Notification.created_at >= utcnow() - timedelta(days=1)))
            cur = s.get(State, "cursor_ms")
            print("patterns by status:", by or "none")
            print("active regex rules:", rules)
            print("alerts in the last 24h:", day)
            print("ES cursor (ms):", cur.value if cur else "none")
        elif a.cmd == "fp":
            if a.sub == "list":
                q = select(Fingerprint).order_by(Fingerprint.last_seen.desc()).limit(a.limit)
                if a.status:
                    q = q.where(Fingerprint.status == a.status)
                for r in s.scalars(q):
                    print(f"{r.id[:8]}  {r.status:<7} sev={r.severity} {r.verdict_source:<7} n={r.hits_total:<7} "
                          f"{r.source[:20]:<20} {r.template[:90]}")
            else:
                r = _resolve(s, a.id)
                if a.sub == "show":
                    print(f"id: {r.id}\nsource: {r.source}\nstatus: {r.status} ({r.verdict_source}) "
                          f"sev={r.severity} conf={r.confidence:.2f}\nmax level: {RANK_NAME.get(r.max_level_rank)}\n"
                          f"occurrences: {r.hits_total}\ncategory: {r.category}\nsummary: {r.summary}\n"
                          f"recommendation: {r.recommendation}\ntemplate: {r.template}\nsamples:")
                    for x in r.samples or []:
                        print("  -", x.get("host"), x["text"][:300])
                    return
                if a.sub in ("ignore", "alert", "watch"):
                    r.status, r.verdict_source, r.expires_at, r.review_reason = a.sub, "user", None, None
                    if a.sub == "alert":
                        r.severity = max(r.severity, 4)
                elif a.sub == "reset":
                    r.status, r.verdict_source, r.review_reason = "pending", "none", "reset by operator"
                s.commit()
                print(f"{r.id[:8]} -> {r.status}")
        elif a.cmd == "rule":
            if a.sub == "list":
                for r in s.scalars(select(Rule).order_by(Rule.id)):
                    print(f"#{r.id} {'ON ' if r.active else 'off'} hits={r.hits:<7} {r.source[:20]:<20} {r.pattern}")
            elif a.sub == "add":
                try:
                    re.compile(a.pattern, re.I)
                except re.error as e:
                    sys.exit(f"Invalid regex: {e}")
                s.add(Rule(source=a.source, pattern=a.pattern, created_from="user", note="added manually"))
                s.commit()
                print("Rule added.")
            elif a.sub == "disable":
                r = s.get(Rule, a.id)
                if not r:
                    sys.exit("No such rule")
                r.active = False
                s.commit()
                print("Disabled.")


if __name__ == "__main__":
    main()
