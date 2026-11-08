# LogWatch AI

A long-running service that reads logs from Elasticsearch, filters out noise with cheap local rules,
asks an [Ollama](https://ollama.com) model to judge only the *new log patterns*, and notifies you on
**Discord only when something serious is going on**. The filters teach themselves from the model's
verdicts (and from your own decisions), so the amount of noise - and the load on Ollama - keeps shrinking.

## Installation and updates - exclusively through `setup.sh`

`setup.sh` is the single source of truth: it contains the application code, the configuration
questions and the update logic.

```bash
chmod +x setup.sh && ./setup.sh
```

1. The script asks for your Elasticsearch, Ollama, Discord and database settings (passwords and the
   webhook are typed invisibly), tests the connections and writes a ready-to-deploy structure:
   `.env`, `docker-compose.yml`, `Dockerfile` and the application code.
2. It then asks **"Do you want to build the application?"** - `y` builds, starts and tests the
   connections; `n` only prepares the files (later: `cd <dir> && docker compose up -d --build`).
3. **Updating:** run a newer `setup.sh`. It detects the existing installation, shows a plan of changes
   (new / changed / removed files), keeps your `.env` (new keys are added with their defaults),
   backs up hand-edited files to `.backup/` and rebuilds the container. No changes means
   "the application is up to date".

Options: `--reconfigure` (ask the questions again), `--dir DIR`, `-y` (auto-confirm), `--no-build`,
`--extract DIR` (unpack the sources for working on the code).
New releases are made by changing the code inside `setup.sh` and bumping `SETUP_VERSION`; database or
`.env` migrations go into the `run_migrations` function.

Requirements: Docker Engine with Compose >= 2.20, a model pulled in Ollama (`ollama pull <model>`),
Ollama >= 0.5 (structured output). Elasticsearch is assumed to be reachable over **http without
authentication** by default; https, username/password or an API key can be selected in the questions.

## How it works

```
Elasticsearch -> normalization -> local filter -> fingerprint (pattern) -> pattern table
 (cursor in DB)   level/host       level, keywords,   numbers/IPs/UUIDs     status:
                                   learned regex      become <N>/<IP>        pending -> Ollama
                                   rules                                     ignore / watch / alert
                                                                                 |
                                         alert + cooldown + hourly cap  <--------+ --> Discord
```

1. **Local filter (no Ollama)** - drops `trace/debug`, entries below `PREFILTER_MIN_LEVEL` that contain no
   keywords, and everything matching a learned regex rule. `critical` and above are never dropped locally.
2. **Patterns** - every message is reduced to a template (`Connection reset by <IP> retry <N>`), so the
   model judges **one pattern once** instead of every line. `OLLAMA_MAX_CALLS_PER_CYCLE` and the time budget
   `OLLAMA_CYCLE_BUDGET_SECONDS` protect Ollama from being flooded; an alert goes to Discord right after
   its verdict, not after the whole batch of analyses.
3. **Learning from Ollama** - the model returns a verdict (`ignore` / `watch` / `alert`), a severity 1-5,
   a confidence, a description and a recommendation. The verdict is stored in the database and from then
   on applies without involving the model. Previous verdicts are passed back to the model as examples
   (operator decisions take precedence), which keeps its judgements consistent.
   For `ignore` the model may propose a regex. It is **validated**: it compiles, matches the samples,
   does not match any pattern flagged as an alert, has no nested quantifiers, and is scoped to a
   single source/service.
4. **Self-regulation**
   - an `ignore` with confidence below `IGNORE_MIN_CONFIDENCE`, or for a `critical+` level, becomes `watch`;
   - an `alert` with severity below `ALERT_MIN_SEVERITY` becomes `watch`;
   - verdicts expire (TTL) and are re-evaluated because environments change;
   - a **frequency spike** of an ignored pattern (`SPIKE_*`) sends it back to the model;
   - an operator decision is never overwritten by the model.
5. **Discord** - alerts only. The same pattern is reported at most once per `ALERT_COOLDOWN_MINUTES`,
   with a global cap of `MAX_ALERTS_PER_HOUR`. Log content cannot ping anyone (`allowed_mentions`);
   a mention is added only via `DISCORD_MENTION` for severity 5/5. Separate, rare system notices cover:
   Elasticsearch/Ollama unavailable, a large pattern queue, the hourly cap.
6. **Ollama unavailable** - patterns wait in a queue; with `OLLAMA_FAIL_OPEN=true`, `critical+` entries
   are reported as a preliminary alert without analysis.

## Database

The application needs **persistent state** (read cursor, learned verdicts, rules, cooldowns) and has a
single writing process, so **SQLite is the default and fully sufficient** (a file in the `/data` volume).
Other options are chosen in `setup.sh` (stored in `.env`):

| Scenario | `.env` |
|---|---|
| SQLite (default) | `DB_TYPE=sqlite` |
| PostgreSQL in Docker | `DB_TYPE=postgresql`, `COMPOSE_PROFILES=postgres`, `DB_HOST=postgres`, `DB_PASSWORD=...` |
| MariaDB in Docker | `DB_TYPE=mariadb`, `COMPOSE_PROFILES=mariadb`, `DB_HOST=mariadb`, `DB_PASSWORD=...` |
| External PostgreSQL/MariaDB | `DB_TYPE=...`, `DB_HOST=<address>`, `DB_PORT/DB_NAME/DB_USER/DB_PASSWORD`, empty `COMPOSE_PROFILES` |
| Any SQLAlchemy URL | `DB_URL=...` |

Tables are created automatically on startup. Switching databases does not migrate existing data.

## CLI (operator decisions)

Every alert footer contains a ready-to-use command. A manual decision takes precedence over the model
and never expires.

```bash
docker compose exec logwatch python -m app.cli fp list --status alert
docker compose exec logwatch python -m app.cli fp show   <id>
docker compose exec logwatch python -m app.cli fp ignore <id>   # stop bothering me with this
docker compose exec logwatch python -m app.cli fp alert  <id>   # always alert
docker compose exec logwatch python -m app.cli fp reset  <id>   # let Ollama re-evaluate
docker compose exec logwatch python -m app.cli rule list | rule add <source> <regex> | rule disable <n>
docker compose exec logwatch python -m app.cli stats
docker compose exec logwatch python -m app.cli check           # test ES / Ollama / Discord
```

## Tuning

- Too many alerts: raise `ALERT_MIN_SEVERITY` to 5, describe your environment in `ENV_CONTEXT`, use `fp ignore`.
- Too few: lower `ALERT_MIN_SEVERITY` to 3 and set `PREFILTER_MIN_LEVEL=info`.
- Pattern queue keeps growing: narrow `ES_INDEX` / `ES_EXTRA_QUERY`, raise `OLLAMA_MAX_CALLS_PER_CYCLE`.
- Weak verdicts: use a larger model; keep the temperature low.
- Output language of the model's descriptions: `LANGUAGE` (default `en`).

## Limitations and notes

- Reading is *at-least-once* with deduplication at the cursor boundary; documents indexed later than
  `ES_INGEST_LAG_SECONDS` after their timestamp may be missed.
- The model sees only 1-3 samples of a pattern, without neighbouring log lines (a possible extension).
- Log samples are sent to Ollama and to Discord - do not point the application at logs containing data
  you do not want to expose there.
- Regex rules proposed by the model are validated heuristically; if in doubt, `rule disable <n>`.
- The Discord webhook is a secret - `.env` is created with mode 600 and is listed in `.gitignore`.
