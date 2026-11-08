#!/usr/bin/env bash
#
# LogWatch AI - installer, configurator and updater (the single source of truth for the application).
#
#   ./setup.sh                 first installation, or update of an existing one
#   ./setup.sh --reconfigure   ask the configuration questions again (current values become defaults)
#   ./setup.sh --dir DIR       installation directory (default ./logwatch-ai)
#   ./setup.sh -y              automatically answer "yes" to build / update confirmations
#   ./setup.sh --no-build      prepare the files, do not ask about building
#   ./setup.sh --extract DIR   unpack the application sources into DIR (for working on the code)
#
# The application code is embedded below (function emit_files). Development and fixes are made in
# this script by bumping SETUP_VERSION - installations update by running a newer setup.sh.
#
set -Eeo pipefail

SETUP_VERSION="1.0.2"
MARKER=".logwatch-setup"
SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")

if (( BASH_VERSINFO[0] < 4 )); then
  echo "bash >= 4 is required (you have ${BASH_VERSION})." >&2
  exit 1
fi

# ───────────────────────────── output / helpers ─────────────────────────────
if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else
  C_B=''; C_G=''; C_Y=''; C_R=''; C_C=''; C_0=''
fi
info() { printf '%s\n' "${C_C}▸${C_0} $*"; }
ok()   { printf '%s\n' "${C_G}✔${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}!${C_0} $*" >&2; }
err()  { printf '%s\n' "${C_R}✘${C_0} $*" >&2; }
die()  { err "$*"; exit 1; }
hdr()  { printf '\n%s\n' "${C_B}── $* ──${C_0}"; }

STAGE=""
cleanup() { if [[ -n $STAGE && -d $STAGE ]]; then rm -rf "$STAGE"; fi; return 0; }
trap cleanup EXIT
trap 'rc=$?; err "Unexpected error (line $LINENO, exit code $rc)"' ERR

usage() { sed -n '3,13p' "$SELF" | sed 's/^# \{0,1\}//'; }

DIR_ARG=""; RECONF=0; ASSUME_YES=0; NO_BUILD=0; EXTRACT_DIR=""
while (( $# )); do
  case $1 in
    --dir)         [[ -n ${2:-} ]] || die "--dir requires an argument"; DIR_ARG=$2; shift 2;;
    --reconfigure) RECONF=1; shift;;
    -y|--yes)      ASSUME_YES=1; shift;;
    --no-build)    NO_BUILD=1; shift;;
    --extract)     [[ -n ${2:-} ]] || die "--extract requires an argument"; EXTRACT_DIR=$2; shift 2;;
    -h|--help)     usage; exit 0;;
    *)             die "Unknown option: $1 (see --help)";;
  esac
done

trim() { local s=${1//$'\r'/}; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
sha()  { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
version_lt() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$1" ]]; }
abspath() {
  local p=${1/#\~/$HOME}
  case $p in /*) ;; *) p=$PWD/$p;; esac
  printf '%s' "${p%/}"
}
gen_pass() { ( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 ); }

# ───────────────────────── .env variable specification ─────────────────────────
# Format: "KEY|default value|comment"  and  "#|Section title"
ENV_SPEC=(
"#|General"
"TZ|Europe/Warsaw|Time zone"
"LOG_LEVEL|INFO|Application log level: DEBUG, INFO, WARNING, ERROR"
"POLL_INTERVAL_SECONDS|30|How often (in seconds) to check Elasticsearch for new logs"
"#|Elasticsearch (http without authentication by default)"
"ES_SCHEME|http|Protocol: http or https"
"ES_HOST||IP address or hostname of the Elasticsearch server"
"ES_PORT|9200|Elasticsearch port"
"ES_USERNAME||Username (empty = no authentication)"
"ES_PASSWORD||Password"
"ES_API_KEY||API key instead of username and password (takes precedence)"
"ES_VERIFY_CERTS|true|Verify the TLS certificate (https only)"
"ES_CA_CERT||Path to a CA certificate inside the container (optional)"
"ES_INDEX|*|Index or data stream pattern, e.g. logs-*,filebeat-*"
"ES_TIMESTAMP_FIELD|@timestamp|Event timestamp field"
"ES_EXTRA_QUERY||Extra query_string filter, e.g. NOT service.name:healthcheck"
"ES_BATCH_SIZE|500|Size of a single read batch"
"ES_MAX_BATCHES_PER_CYCLE|10|Maximum number of batches per cycle"
"ES_INGEST_LAG_SECONDS|5|Do not read the most recent seconds (indexing delay)"
"ES_INITIAL_LOOKBACK_MINUTES|15|How far back to read on the very first start"
"ES_MAX_CATCHUP_HOURS|6|After a long outage, do not catch up further back than this many hours"
"ES_TIMEOUT_SECONDS|30|Elasticsearch request timeout"
"ES_FAIL_NOTICE_AFTER|5|Failed cycles in a row before a system notice is sent to Discord"
"#|Ollama"
"OLLAMA_SCHEME|http|Protocol: http or https"
"OLLAMA_HOST||IP address or hostname of the Ollama server"
"OLLAMA_PORT|11434|Ollama port"
"OLLAMA_MODEL|qwen2.5:14b|Model (must be pulled: ollama pull NAME)"
"OLLAMA_TIMEOUT_SECONDS|300|Model response timeout"
"OLLAMA_NUM_CTX|4096|Context window"
"OLLAMA_TEMPERATURE|0.1|Temperature (low = stable verdicts)"
"OLLAMA_KEEP_ALIVE|10m|How long the model stays loaded in memory"
"OLLAMA_MAX_CALLS_PER_CYCLE|8|Hard limit of Ollama requests per cycle"
"OLLAMA_CYCLE_BUDGET_SECONDS|120|After this many seconds of analysis in a cycle, do not start new ones (log reading and alerts never wait for a slow Ollama)"
"OLLAMA_FAIL_OPEN|true|When Ollama is unavailable, report critical+ entries as a preliminary alert"
"LANGUAGE|en|Language of the descriptions generated by the model"
"ENV_CONTEXT||Description of your environment for the model (improves verdict accuracy)"
"#|Discord"
"DISCORD_WEBHOOK_URL||Webhook URL (secret)"
"DISCORD_USERNAME|LogWatch AI|Sender name"
"DISCORD_MENTION||Mention added to 5/5 alerts, e.g. <@123456789> or <@&ROLE_ID> or @here"
"ALERT_COOLDOWN_MINUTES|60|The same pattern is not reported more often than every this many minutes"
"MAX_ALERTS_PER_HOUR|20|Global safety cap on alerts per hour"
"#|Filters and learning"
"PREFILTER_MIN_LEVEL|warn|Below this level only keyword matches count: trace, debug, info, warn, error, critical"
"PREFILTER_EXTRA_KEYWORDS||Extra keywords, comma separated"
"ALERT_MIN_SEVERITY|4|Minimum severity (1-5) at which an alert verdict is really an alert"
"IGNORE_MIN_CONFIDENCE|0.7|Ignoring requires at least this model confidence"
"LEARN_REGEX_RULES|true|Let the model propose regex rules (validated)"
"VERDICT_TTL_DAYS_IGNORE|14|Days after which an ignore verdict is re-evaluated"
"VERDICT_TTL_DAYS_WATCH|3|Days after which a watch verdict is re-evaluated"
"VERDICT_TTL_DAYS_ALERT|7|Days after which an alert verdict is re-evaluated"
"SPIKE_MIN_COUNT|50|Frequency spike: minimum number of occurrences in one cycle"
"SPIKE_FACTOR|5|Frequency spike: multiple of the usual rate"
"FINGERPRINT_RETENTION_DAYS|60|Days without occurrences after which a pattern is removed"
"#|Database"
"DB_TYPE|sqlite|sqlite, postgresql or mariadb"
"SQLITE_PATH|/data/logwatch.sqlite3|SQLite file path inside the container"
"COMPOSE_PROFILES||postgres or mariadb = database started in Docker; empty = SQLite or an external database"
"DB_HOST||Database host (for a database in Docker: postgres or mariadb)"
"DB_PORT||Database port (empty = default)"
"DB_NAME|logwatch|Database name"
"DB_USER|logwatch|Database user"
"DB_PASSWORD||Database password (secret)"
"DB_URL||Optional full SQLAlchemy URL - overrides the settings above (secret)"
)
SECRET_KEYS=" ES_PASSWORD ES_API_KEY DB_PASSWORD DB_URL DISCORD_WEBHOOK_URL "

declare -A CFG DEF DESC
ENV_ORDER=()

load_spec() {
  local line key def com
  for line in "${ENV_SPEC[@]}"; do
    IFS='|' read -r key def com <<<"$line"
    if [[ $key == '#' ]]; then ENV_ORDER+=("#$def"); continue; fi
    ENV_ORDER+=("$key"); DEF[$key]=$def; DESC[$key]=$com
  done
  local tz=""
  if [[ -r /etc/timezone ]]; then tz=$(trim "$(cat /etc/timezone)"); fi
  if [[ -z $tz ]] && command -v timedatectl >/dev/null 2>&1; then
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  fi
  if [[ -n $tz ]]; then DEF[TZ]=$tz; fi
}

is_secret() { [[ $SECRET_KEYS == *" $1 "* ]]; }

env_quote() {
  local v=$1
  if [[ -z $v ]]; then return 0; fi
  if [[ $v =~ ^[A-Za-z0-9_@%+=:,./*-]+$ ]]; then
    printf '%s' "$v"
  elif [[ $v != *"'"* ]]; then
    printf "'%s'" "$v"
  else
    v=${v//\\/\\\\}; v=${v//\"/\\\"}
    printf '"%s"' "$v"
  fi
}

# real = current configuration, example = defaults only (no secrets)
render_env() {
  local mode=$1 item key v k
  printf '# File managed by setup.sh. To change the configuration run: ./setup.sh --reconfigure\n'
  printf '# Manual edits of values are preserved on updates (comments are regenerated).\n'
  printf '# Values containing $ or spaces are wrapped in single quotes - this is how docker compose reads them.\n'
  for item in "${ENV_ORDER[@]}"; do
    if [[ $item == '#'* ]]; then
      printf '\n# ======== %s ========\n' "${item#\#}"
      continue
    fi
    key=$item
    if [[ $mode == real ]]; then v=${CFG[$key]-${DEF[$key]-}}; else v=${DEF[$key]-}; fi
    if [[ $mode != real ]] && is_secret "$key"; then v=''; fi
    if [[ -n ${DESC[$key]-} ]]; then printf '# %s\n' "${DESC[$key]}"; fi
    printf '%s=%s\n' "$key" "$(env_quote "$v")"
  done
  if [[ $mode == real ]]; then
    local first=1
    for k in "${!CFG[@]}"; do
      if [[ -z ${DEF[$k]+x} ]]; then
        if (( first )); then printf '\n# ======== Additional variables (not in the template) ========\n'; first=0; fi
        printf '%s=%s\n' "$k" "$(env_quote "${CFG[$k]}")"
      fi
    done
  fi
  return 0
}

load_env_file() {
  local f=$1 line key val
  local re_sq="^'(.*)'[[:space:]]*(#.*)?\$" re_dq='^"(.*)"[[:space:]]*(#.*)?$'
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ $line =~ ^[[:space:]]*(#|$) ]]; then continue; fi
    if [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
      if [[ $val =~ $re_sq ]]; then
        val=${BASH_REMATCH[1]}
      elif [[ $val =~ $re_dq ]]; then
        val=${BASH_REMATCH[1]}; val=${val//\\\"/\"}; val=${val//\\\\/\\}
      else
        val=$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$val")
      fi
      CFG[$key]=$val
    fi
  done < "$f"
}

# ─────────────────────────────── interactive questions ───────────────────────────────
v_any()      { return 0; }
v_nonempty() { if [[ -n $1 ]]; then return 0; fi; warn "The value must not be empty"; return 1; }
v_port()     { if [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); then return 0; fi; warn "Enter a port between 1 and 65535"; return 1; }
v_int()      { if [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 )); then return 0; fi; warn "Enter an integer >= 1"; return 1; }
v_sev()      { if [[ $1 =~ ^[1-5]$ ]]; then return 0; fi; warn "Enter a number from 1 to 5"; return 1; }
v_scheme()   { if [[ $1 == http || $1 == https ]]; then return 0; fi; warn "Enter http or https"; return 1; }
v_level()    { case $1 in trace|debug|info|warn|error|critical) return 0;; esac; warn "Allowed: trace, debug, info, warn, error, critical"; return 1; }
v_host() {
  local re_url='^https?://[^/[:space:]]+/?$' re_name='^[][A-Za-z0-9._:-]+$'
  if [[ $1 =~ $re_url || $1 =~ $re_name ]]; then return 0; fi
  warn "Enter an IP address, a hostname or a URL (without a path)"; return 1
}

ask() { # ask KEY "Question" [validator]   (Enter = default value, "-" = clear)
  local key=$1 q=$2 v=${3:-v_any} cur ans
  cur=${CFG[$key]-${DEF[$key]-}}
  while true; do
    if [[ -n $cur ]]; then
      read -r -p "  $q [$cur]: " ans || die "Aborted (end of input)"
    else
      read -r -p "  $q: " ans || die "Aborted (end of input)"
    fi
    ans=$(trim "$ans"); ans=${ans//\'/’}
    if [[ -z $ans ]]; then ans=$cur; elif [[ $ans == "-" ]]; then ans=""; fi
    if "$v" "$ans"; then break; fi
  done
  CFG[$key]=$ans
}

ask_secret() { # ask_secret KEY "Question" [confirm_twice=0]   - input is not echoed
  local key=$1 q=$2 confirm_twice=${3:-0} a b hint=""
  if [[ -n ${CFG[$key]-} ]]; then hint=" [already set: Enter keeps it, '-' clears it]"; fi
  while true; do
    read -r -s -p "  $q (input is hidden)$hint: " a || die "Aborted (end of input)"; echo
    a=$(trim "$a")
    if [[ -z $a ]]; then return 0; fi
    if [[ $a == "-" ]]; then CFG[$key]=''; return 0; fi
    if [[ $a == *"'"* ]]; then warn "An apostrophe (') is not supported in secrets - please use a different value"; continue; fi
    if (( confirm_twice )); then
      read -r -s -p "  Repeat: " b || die "Aborted (end of input)"; echo
      if [[ $a != "$(trim "$b")" ]]; then warn "The values differ, please try again"; continue; fi
    fi
    CFG[$key]=$a
    ok "set (${#a} characters)"
    return 0
  done
}

confirm() { # confirm "Question" [y|n]  -> returns 0 for yes
  local q=$1 def=${2:-y} a hint
  if [[ $def == y ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  while true; do
    read -r -p "  $q $hint " a || die "Aborted (end of input)"
    a=$(trim "$a"); a=${a,,}; a=${a:-$def}
    case $a in
      y|yes) return 0;;
      n|no)  return 1;;
      *) echo "  Please answer y (yes) or n (no).";;
    esac
  done
}

ask_bool() { # ask_bool KEY "Question"
  local key=$1 q=$2 d=n
  if [[ ${CFG[$key]-${DEF[$key]-}} == true ]]; then d=y; fi
  if confirm "$q" "$d"; then CFG[$key]=true; else CFG[$key]=false; fi
}

CHOICE=0
choose() { # choose DEFAULT "option1" "option2" ...  -> CHOICE
  local def=$1 i=1 o a; shift
  for o in "$@"; do printf '    %d) %s\n' "$i" "$o"; i=$((i+1)); done
  while true; do
    read -r -p "  Choice [$def]: " a || die "Aborted (end of input)"
    a=$(trim "$a"); a=${a:-$def}
    if [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= $# )); then CHOICE=$a; return 0; fi
    warn "Enter a number from 1 to $#"
  done
}

ask_endpoint() { # ask_endpoint ES|OLLAMA "Name"
  local p=$1 name=$2 re='^(https?)://(\[[^]]+\]|[^/:]+)(:([0-9]+))?/?$'
  ask "${p}_HOST" "$name IP address or hostname (a full URL is accepted)" v_host
  if [[ ${CFG[${p}_HOST]} =~ $re ]]; then
    CFG[${p}_SCHEME]=${BASH_REMATCH[1]}
    CFG[${p}_HOST]=${BASH_REMATCH[2]}
    if [[ -n ${BASH_REMATCH[4]} ]]; then CFG[${p}_PORT]=${BASH_REMATCH[4]}; fi
  fi
  ask "${p}_SCHEME" "Protocol (http/https)" v_scheme
  ask "${p}_PORT" "Port" v_port
}

cq() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }  # escaping for a curl config file

es_probe() {
  if ! command -v curl >/dev/null 2>&1; then info "curl is not available - skipping the connection test"; return 0; fi
  local url="${CFG[ES_SCHEME]}://${CFG[ES_HOST]}:${CFG[ES_PORT]}/" code cfgtxt=""
  local -a args=(-sS -m 6 -o /dev/null -w '%{http_code}')
  if [[ ${CFG[ES_SCHEME]} == https && ( ${CFG[ES_VERIFY_CERTS]} != true || -n ${CFG[ES_CA_CERT]} ) ]]; then args+=(-k); fi
  if [[ -n ${CFG[ES_API_KEY]} ]]; then
    cfgtxt="header = \"Authorization: ApiKey $(cq "${CFG[ES_API_KEY]}")\""$'\n'
  elif [[ -n ${CFG[ES_USERNAME]} ]]; then
    cfgtxt="user = \"$(cq "${CFG[ES_USERNAME]}"):$(cq "${CFG[ES_PASSWORD]}")\""$'\n'
  fi
  info "Testing the Elasticsearch connection: $url"
  code=$(printf '%s' "$cfgtxt" | curl "${args[@]}" -K - "$url" 2>/dev/null) || code=000
  case $code in
    200)     ok "Elasticsearch is responding";;
    401|403) warn "The server responds but denies access (HTTP $code) - check the authentication settings";;
    000)     warn "Cannot connect - check the address, port and protocol (the configuration will be saved anyway)";;
    *)       warn "Unexpected HTTP response: $code";;
  esac
  return 0
}

OLLAMA_MODELS=()
ollama_probe() {
  OLLAMA_MODELS=()
  if ! command -v curl >/dev/null 2>&1; then return 0; fi
  local url="${CFG[OLLAMA_SCHEME]}://${CFG[OLLAMA_HOST]}:${CFG[OLLAMA_PORT]}" out code body
  info "Testing the Ollama connection: $url"
  out=$(curl -sS -m 8 -w $'\n%{http_code}' "$url/api/tags" 2>/dev/null) || out=$'\n000'
  code=${out##*$'\n'}; body=${out%$'\n'*}
  if [[ $code == 200 ]]; then
    mapfile -t OLLAMA_MODELS < <(grep -o '"name":"[^"]*"' <<<"$body" | cut -d'"' -f4 || true)
    ok "Ollama is responding (models: ${#OLLAMA_MODELS[@]})"
    if (( ${#OLLAMA_MODELS[@]} )); then info "Available models: $(IFS=', '; echo "${OLLAMA_MODELS[*]}")"; fi
  else
    warn "Could not connect to Ollama (HTTP $code) - the configuration will be saved anyway"
  fi
  return 0
}

re_webhook='^https://(canary\.|ptb\.)?discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9._-]+'
ask_webhook() {
  local w
  while true; do
    ask_secret DISCORD_WEBHOOK_URL "Discord webhook URL"
    w=${CFG[DISCORD_WEBHOOK_URL]}
    if [[ -z $w ]]; then
      if confirm "No webhook - alerts will only appear in the container logs. Continue?" n; then return 0; fi
      continue
    fi
    if [[ $w =~ $re_webhook ]]; then return 0; fi
    warn "This does not look like a Discord webhook (https://discord.com/api/webhooks/ID/TOKEN)"
    if confirm "Use it anyway?" n; then return 0; fi
    CFG[DISCORD_WEBHOOK_URL]=''
  done
}

DB_MODE=1
derive_db_mode() {
  local t=${CFG[DB_TYPE]-sqlite} p=${CFG[COMPOSE_PROFILES]-}
  case $t in
    postgresql) if [[ $p == *postgres* ]]; then DB_MODE=2; else DB_MODE=4; fi;;
    mariadb)    if [[ $p == *mariadb* ]];  then DB_MODE=3; else DB_MODE=5; fi;;
    *)          DB_MODE=1;;
  esac
}
db_label() {
  case $DB_MODE in
    1) echo "SQLite (${CFG[SQLITE_PATH]})";;
    2) echo "PostgreSQL in Docker (${CFG[DB_NAME]}@postgres)";;
    3) echo "MariaDB in Docker (${CFG[DB_NAME]}@mariadb)";;
    4) echo "External PostgreSQL (${CFG[DB_USER]}@${CFG[DB_HOST]}:${CFG[DB_PORT]:-5432}/${CFG[DB_NAME]})";;
    5) echo "External MariaDB (${CFG[DB_USER]}@${CFG[DB_HOST]}:${CFG[DB_PORT]:-3306}/${CFG[DB_NAME]})";;
  esac
}

ask_database() {
  derive_db_mode
  if [[ -n ${CFG[DB_URL]-} ]]; then warn "A custom DB_URL is currently set - the choice below will overwrite it"; fi
  info "The application stores state (cursor, learned filters, cooldowns). SQLite is recommended."
  choose "$DB_MODE" \
    "SQLite - a file in a Docker volume (recommended)" \
    "PostgreSQL - run in Docker" \
    "MariaDB - run in Docker" \
    "PostgreSQL - existing external server" \
    "MariaDB - existing external server"
  DB_MODE=$CHOICE
  CFG[DB_URL]=''
  case $DB_MODE in
    1) CFG[DB_TYPE]=sqlite; CFG[COMPOSE_PROFILES]=''; CFG[DB_HOST]=''; CFG[DB_PORT]='';;
    2) CFG[DB_TYPE]=postgresql; CFG[COMPOSE_PROFILES]=postgres; CFG[DB_HOST]=postgres; CFG[DB_PORT]=5432;;
    3) CFG[DB_TYPE]=mariadb; CFG[COMPOSE_PROFILES]=mariadb; CFG[DB_HOST]=mariadb; CFG[DB_PORT]=3306;;
    4) CFG[DB_TYPE]=postgresql; CFG[COMPOSE_PROFILES]='';;
    5) CFG[DB_TYPE]=mariadb; CFG[COMPOSE_PROFILES]='';;
  esac
  if (( DB_MODE >= 2 )); then
    if (( DB_MODE >= 4 )); then
      ask DB_HOST "Database server address" v_host
      if [[ -z ${CFG[DB_PORT]} || ${CFG[DB_PORT]} == 5432 || ${CFG[DB_PORT]} == 3306 ]]; then
        if (( DB_MODE == 4 )); then CFG[DB_PORT]=5432; else CFG[DB_PORT]=3306; fi
      fi
      ask DB_PORT "Database port" v_port
    fi
    ask DB_NAME "Database name" v_nonempty
    ask DB_USER "Database user" v_nonempty
    if (( DB_MODE <= 3 )); then
      info "Database password for the Docker database: press Enter on an empty value to generate a random one"
    fi
    ask_secret DB_PASSWORD "Database password" 1
    if [[ -z ${CFG[DB_PASSWORD]} ]]; then
      if (( DB_MODE <= 3 )); then
        CFG[DB_PASSWORD]=$(gen_pass)
        ok "A random password was generated (stored in .env)"
      else
        warn "The password for the external database is empty"
      fi
    fi
  fi
}

run_questions() {
  hdr "1/5  Elasticsearch"
  ask_endpoint ES "Elasticsearch"
  if [[ ${CFG[ES_SCHEME]} == https ]]; then ask_bool ES_VERIFY_CERTS "Verify the TLS certificate?"; fi
  local ad=n
  if [[ -n ${CFG[ES_USERNAME]-}${CFG[ES_API_KEY]-} ]]; then ad=y; fi
  if confirm "Does Elasticsearch require authentication?" "$ad"; then
    local m=1
    if [[ -n ${CFG[ES_API_KEY]-} ]]; then m=2; fi
    choose "$m" "Username and password" "API key"
    if (( CHOICE == 1 )); then
      ask ES_USERNAME "Username" v_nonempty
      ask_secret ES_PASSWORD "Password"
      CFG[ES_API_KEY]=''
    else
      ask_secret ES_API_KEY "API key (base64-encoded id:key)"
      CFG[ES_USERNAME]=''; CFG[ES_PASSWORD]=''
    fi
  else
    CFG[ES_USERNAME]=''; CFG[ES_PASSWORD]=''; CFG[ES_API_KEY]=''
  fi
  ask ES_INDEX "Index / data stream pattern" v_nonempty
  es_probe

  hdr "2/5  Ollama"
  ask_endpoint OLLAMA "Ollama"
  ollama_probe
  ask OLLAMA_MODEL "Model" v_nonempty
  if (( ${#OLLAMA_MODELS[@]} )); then
    local found=0 m
    for m in "${OLLAMA_MODELS[@]}"; do
      if [[ $m == "${CFG[OLLAMA_MODEL]}" || $m == "${CFG[OLLAMA_MODEL]}:latest" ]]; then found=1; fi
    done
    if (( ! found )); then warn "Model ${CFG[OLLAMA_MODEL]} is not pulled - on the Ollama server run: ollama pull ${CFG[OLLAMA_MODEL]}"; fi
  fi
  ask LANGUAGE "Language of the descriptions generated by the model (e.g. en, pl)" v_nonempty
  ask ENV_CONTEXT "Short description of your environment for the model (optional, '-' clears)"

  hdr "3/5  Discord"
  ask_webhook

  hdr "4/5  Database"
  ask_database

  hdr "5/5  Advanced settings"
  if confirm "Change advanced settings (interval, alert thresholds, filters)?" n; then
    ask POLL_INTERVAL_SECONDS "Log polling interval [s]" v_int
    ask ALERT_MIN_SEVERITY "Minimum alert severity 1-5 (higher = fewer notifications)" v_sev
    ask ALERT_COOLDOWN_MINUTES "Cooldown for the same alert [min]" v_int
    ask MAX_ALERTS_PER_HOUR "Maximum number of alerts per hour" v_int
    ask PREFILTER_MIN_LEVEL "Lowest log level passed on (trace|debug|info|warn|error|critical)" v_level
    ask OLLAMA_MAX_CALLS_PER_CYCLE "Ollama request limit per cycle" v_int
    ask OLLAMA_CYCLE_BUDGET_SECONDS "Ollama analysis time budget per cycle [s]" v_int
    ask ES_EXTRA_QUERY "Extra query_string filter for ES (optional, '-' clears)"
    ask DISCORD_MENTION "Mention for 5/5 alerts, e.g. <@ID> or @here (optional)"
    ask_bool LEARN_REGEX_RULES "Allow the model to propose regex rules?"
    ask_bool OLLAMA_FAIL_OPEN "Send a preliminary alert for critical+ entries when Ollama is unavailable?"
  fi
}

print_summary() {
  derive_db_mode
  local auth="no authentication" wh="none (logs only)"
  if [[ -n ${CFG[ES_API_KEY]} ]]; then auth="API key"; elif [[ -n ${CFG[ES_USERNAME]} ]]; then auth="user ${CFG[ES_USERNAME]}"; fi
  if [[ -n ${CFG[DISCORD_WEBHOOK_URL]} ]]; then wh="set"; fi
  hdr "Summary"
  printf '  %-18s %s\n' "Elasticsearch" "${CFG[ES_SCHEME]}://${CFG[ES_HOST]}:${CFG[ES_PORT]} ($auth), indices: ${CFG[ES_INDEX]}"
  printf '  %-18s %s\n' "Ollama" "${CFG[OLLAMA_SCHEME]}://${CFG[OLLAMA_HOST]}:${CFG[OLLAMA_PORT]}, model: ${CFG[OLLAMA_MODEL]}"
  printf '  %-18s %s\n' "Discord" "webhook $wh"
  printf '  %-18s %s\n' "Database" "$(db_label)"
  printf '  %-18s %s\n' "Alerts" "severity >= ${CFG[ALERT_MIN_SEVERITY]}, cooldown ${CFG[ALERT_COOLDOWN_MINUTES]} min, max ${CFG[MAX_ALERTS_PER_HOUR]}/h"
  printf '  %-18s %s\n' "Interval" "${CFG[POLL_INTERVAL_SECONDS]} s"
}

# ───────────────────────── embedded application files ─────────────────────────
emit_files() {
  local root=$1
  __w() { mkdir -p "$root/$(dirname "$1")"; cat > "$root/$1"; }
  __w '.dockerignore' <<'LOGWATCH_EOF'
.env
.env.*
.git
.backup
.logwatch-setup
setup.sh
__pycache__
*.pyc
data
LOGWATCH_EOF
  __w '.gitignore' <<'LOGWATCH_EOF'
.env
.backup/
__pycache__/
*.pyc
data/
LOGWATCH_EOF
  __w 'Dockerfile' <<'LOGWATCH_EOF'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /srv

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app ./app

# Non-root user + data directory for SQLite (used when DB_TYPE=sqlite)
RUN useradd --system --uid 10001 logwatch \
    && mkdir -p /data \
    && chown logwatch /data
USER logwatch
VOLUME /data

# The application touches the heartbeat file after every stage of the cycle
HEALTHCHECK --interval=60s --timeout=5s --start-period=90s --retries=3 \
  CMD python -c "import os,sys,time; sys.exit(0 if time.time()-os.path.getmtime(os.getenv('HEARTBEAT_FILE','/tmp/logwatch.heartbeat'))<1800 else 1)"

ENTRYPOINT ["python", "-m", "app.main"]
LOGWATCH_EOF
  __w 'README.md' <<'LOGWATCH_EOF'
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
LOGWATCH_EOF
  __w 'app/__init__.py' <<'LOGWATCH_EOF'

LOGWATCH_EOF
  __w 'app/analyzer.py' <<'LOGWATCH_EOF'
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
LOGWATCH_EOF
  __w 'app/cli.py' <<'LOGWATCH_EOF'
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
LOGWATCH_EOF
  __w 'app/config.py' <<'LOGWATCH_EOF'
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
LOGWATCH_EOF
  __w 'app/db.py' <<'LOGWATCH_EOF'
"""Database layer (SQLAlchemy) - SQLite / PostgreSQL / MariaDB."""
from __future__ import annotations

import logging
import os
import time
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import (JSON, BigInteger, Boolean, DateTime, Float, Integer, String, Text,
                        create_engine, event)
from sqlalchemy.engine import URL, Engine
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

from .config import Config

log = logging.getLogger(__name__)


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


class Base(DeclarativeBase):
    pass


class State(Base):
    """Simple key-value store: Elasticsearch read cursor, etc."""
    __tablename__ = "state"
    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(Text, default="")


class Fingerprint(Base):
    """Log pattern (normalized template) plus the knowledge gained about it from Ollama or the operator."""
    __tablename__ = "fingerprints"
    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    source: Mapped[str] = mapped_column(String(255), index=True)
    template: Mapped[str] = mapped_column(Text)
    max_level_rank: Mapped[int] = mapped_column(Integer, default=-1)
    # pending | ignore | watch | alert
    status: Mapped[str] = mapped_column(String(16), default="pending", index=True)
    # none | ollama | user | failopen
    verdict_source: Mapped[str] = mapped_column(String(16), default="none")
    severity: Mapped[int] = mapped_column(Integer, default=0)
    confidence: Mapped[float] = mapped_column(Float, default=0.0)
    category: Mapped[str] = mapped_column(String(128), default="")
    summary: Mapped[str] = mapped_column(Text, default="")
    recommendation: Mapped[str] = mapped_column(Text, default="")
    review_reason: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    samples: Mapped[list] = mapped_column(JSON, default=list)
    first_seen: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    last_seen: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    hits_total: Mapped[int] = mapped_column(BigInteger, default=0)
    hits_since_notify: Mapped[int] = mapped_column(BigInteger, default=0)
    ewma_rate: Mapped[float] = mapped_column(Float, default=0.0)
    last_notified: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    last_analyzed: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    expires_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    analysis_count: Mapped[int] = mapped_column(Integer, default=0)


class Rule(Base):
    """An 'ignore' regex rule proposed by Ollama (or added manually), scoped to a single source."""
    __tablename__ = "rules"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    source: Mapped[str] = mapped_column(String(255), index=True)
    pattern: Mapped[str] = mapped_column(Text)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    hits: Mapped[int] = mapped_column(BigInteger, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    created_from: Mapped[str] = mapped_column(String(32), default="")
    note: Mapped[str] = mapped_column(Text, default="")


class Notification(Base):
    __tablename__ = "notifications"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    fp_id: Mapped[str] = mapped_column(String(32), index=True)
    kind: Mapped[str] = mapped_column(String(16), default="alert")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, index=True)


def build_url(cfg: Config) -> URL | str:
    if cfg.db_url:
        return cfg.db_url
    if cfg.db_type == "sqlite":
        return URL.create("sqlite", database=cfg.sqlite_path)
    driver = "postgresql+psycopg2" if cfg.db_type == "postgresql" else "mysql+pymysql"
    query = {"charset": "utf8mb4"} if cfg.db_type == "mariadb" else {}
    return URL.create(driver, username=cfg.db_user, password=cfg.db_password or None,
                      host=cfg.db_host, port=cfg.db_port, database=cfg.db_name, query=query)


def make_engine(cfg: Config) -> Engine:
    url = build_url(cfg)
    is_sqlite = str(url).startswith("sqlite")
    if is_sqlite and not cfg.db_url:
        d = os.path.dirname(cfg.sqlite_path)
        if d:
            os.makedirs(d, exist_ok=True)
    engine = create_engine(url, pool_pre_ping=True, pool_recycle=1800,
                           connect_args={"timeout": 30} if is_sqlite else {})
    if is_sqlite:
        @event.listens_for(engine, "connect")
        def _pragmas(dbapi_conn, _):  # WAL: the CLI can read/write concurrently with the main process
            cur = dbapi_conn.cursor()
            cur.execute("PRAGMA journal_mode=WAL")
            cur.execute("PRAGMA busy_timeout=30000")
            cur.close()
    return engine


def init_db(engine: Engine, attempts: int = 30, delay: float = 2.0) -> None:
    last: Exception | None = None
    for i in range(attempts):
        try:
            Base.metadata.create_all(engine)
            return
        except Exception as e:  # the database may still be starting up
            last = e
            log.warning("Database unavailable (%d/%d): %s", i + 1, attempts, e)
            time.sleep(delay)
    raise RuntimeError(f"Could not connect to the database: {last}")


def get_state(s: Session, key: str, default: str | None = None) -> str | None:
    row = s.get(State, key)
    return row.value if row else default


def set_state(s: Session, key: str, value: str) -> None:
    row = s.get(State, key)
    if row:
        row.value = value
    else:
        s.add(State(key=key, value=value))
LOGWATCH_EOF
  __w 'app/es_client.py' <<'LOGWATCH_EOF'
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
LOGWATCH_EOF
  __w 'app/main.py' <<'LOGWATCH_EOF'
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
LOGWATCH_EOF
  __w 'app/normalize.py' <<'LOGWATCH_EOF'
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
LOGWATCH_EOF
  __w 'app/notifier.py' <<'LOGWATCH_EOF'
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
LOGWATCH_EOF
  __w 'app/pipeline.py' <<'LOGWATCH_EOF'
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
LOGWATCH_EOF
  __w 'app/prefilter.py' <<'LOGWATCH_EOF'
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
LOGWATCH_EOF
  __w 'docker-compose.yml' <<'LOGWATCH_EOF'
# Usage:
#   SQLite (default):          docker compose up -d --build
#   Bundled PostgreSQL:        COMPOSE_PROFILES=postgres  (set in .env) + DB_TYPE=postgresql + DB_HOST=postgres
#   Bundled MariaDB:           COMPOSE_PROFILES=mariadb   (set in .env) + DB_TYPE=mariadb    + DB_HOST=mariadb
#   External database:         DB_TYPE=postgresql|mariadb, DB_HOST=<address>, COMPOSE_PROFILES empty
name: logwatch-ai

services:
  logwatch:
    build: .
    image: logwatch-ai:latest
    container_name: logwatch-ai
    restart: unless-stopped
    env_file: .env
    environment:
      TZ: ${TZ:-Europe/Warsaw}
    volumes:
      - logwatch_data:/data
    depends_on:
      postgres:
        condition: service_healthy
        required: false
      mariadb:
        condition: service_healthy
        required: false
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  postgres:
    image: postgres:16-alpine
    profiles: ["postgres"]
    container_name: logwatch-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${DB_NAME:-logwatch}
      POSTGRES_USER: ${DB_USER:-logwatch}
      POSTGRES_PASSWORD: ${DB_PASSWORD:-}
      TZ: ${TZ:-Europe/Warsaw}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 20

  mariadb:
    image: mariadb:11
    profiles: ["mariadb"]
    container_name: logwatch-mariadb
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: ${DB_NAME:-logwatch}
      MARIADB_USER: ${DB_USER:-logwatch}
      MARIADB_PASSWORD: ${DB_PASSWORD:-}
      MARIADB_RANDOM_ROOT_PASSWORD: "1"
      TZ: ${TZ:-Europe/Warsaw}
    volumes:
      - mariadb_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 30

volumes:
  logwatch_data:
  postgres_data:
  mariadb_data:
LOGWATCH_EOF
  __w 'requirements.txt' <<'LOGWATCH_EOF'
httpx>=0.27,<0.29
SQLAlchemy>=2.0,<2.1
psycopg2-binary>=2.9,<3
PyMySQL>=1.1,<2
cryptography>=42
LOGWATCH_EOF
}

# ───────────────────────── migrations between versions ─────────────────────────
# Called after the files are applied and before rebuilding. $1 = previous version ("" = fresh install).
# When you change the database schema or .env, add a condition here, e.g.:
#   if [[ -n $1 ]] && version_lt "$1" "1.1.0"; then ...; fi
run_migrations() {
  local from=$1
  : "$from"
  return 0
}

# ───────────────────────────── install / update ─────────────────────────────
DIR=""; MODE=install
OLD_VERSION=""; OLD_BUILT="no"
declare -A OLDHASH
STAGED=(); ADD=(); CHG=(); LOCALMOD=(); REMOVED=()
DOCKER=(); DC=()

resolve_dir() {
  local self_dir; self_dir=$(dirname "$SELF")
  if [[ -n $DIR_ARG ]]; then
    DIR=$(abspath "$DIR_ARG")
  elif [[ -f $self_dir/$MARKER ]]; then DIR=$self_dir
  elif [[ -f $PWD/logwatch-ai/$MARKER ]]; then DIR=$PWD/logwatch-ai
  elif [[ -f $PWD/$MARKER ]]; then DIR=$PWD
  else
    hdr "Installation directory"
    local d=$PWD/logwatch-ai ans
    read -r -p "  Where should the application be installed? [$d]: " ans || die "Aborted (end of input)"
    ans=$(trim "$ans"); DIR=$(abspath "${ans:-$d}")
  fi
  if [[ -f $DIR/$MARKER ]]; then MODE=update; else MODE=install; fi
}

read_manifest() {
  OLD_VERSION=""; OLD_BUILT="no"; OLDHASH=()
  if [[ ! -f $DIR/$MARKER ]]; then return 0; fi
  local line rest
  while IFS= read -r line; do
    case $line in
      VERSION=*) OLD_VERSION=${line#VERSION=};;
      BUILT=*)   OLD_BUILT=${line#BUILT=};;
      FILE\|*)   rest=${line#FILE|}; OLDHASH[${rest#*|}]=${rest%%|*};;
    esac
  done < "$DIR/$MARKER"
}

write_manifest() { # $1 = built yes|no
  local rel
  {
    echo "# File managed by setup.sh - do not edit by hand"
    echo "VERSION=$SETUP_VERSION"
    echo "UPDATED=$(date -Iseconds)"
    echo "BUILT=$1"
    for rel in "${STAGED[@]}"; do echo "FILE|$(sha "$STAGE/$rel")|$rel"; done
  } > "$DIR/$MARKER"
}

plan_files() {
  ADD=(); CHG=(); LOCALMOD=(); REMOVED=()
  local rel nh ch
  for rel in "${STAGED[@]}"; do
    if [[ ! -e $DIR/$rel ]]; then ADD+=("$rel"); continue; fi
    nh=$(sha "$STAGE/$rel"); ch=$(sha "$DIR/$rel")
    if [[ $nh != "$ch" ]]; then
      CHG+=("$rel")
      if [[ ${OLDHASH[$rel]-} != "$ch" ]]; then LOCALMOD+=("$rel"); fi
    fi
  done
  for rel in "${!OLDHASH[@]}"; do
    if [[ -e $DIR/$rel && ! -e $STAGE/$rel ]]; then REMOVED+=("$rel"); fi
  done
}

backup_file() { # $1 = relative path, $2 = backup directory
  mkdir -p "$2/$(dirname "$1")"
  cp -p "$DIR/$1" "$2/$1"
}

apply_files() {
  local ts bdir rel env_changed=0 backed=0
  ts=$(date +%Y%m%d-%H%M%S); bdir=$DIR/.backup/$ts
  mkdir -p "$DIR"
  for rel in "${LOCALMOD[@]}"; do backup_file "$rel" "$bdir"; backed=1; done
  for rel in "${REMOVED[@]}"; do
    if [[ ! -e $bdir/$rel ]]; then backup_file "$rel" "$bdir"; backed=1; fi
    rm -f "$DIR/$rel"
  done
  for rel in "${ADD[@]}" "${CHG[@]}"; do
    mkdir -p "$DIR/$(dirname "$rel")"
    cp "$STAGE/$rel" "$DIR/$rel"
  done
  if [[ ! -f $DIR/.env ]] || ! cmp -s "$STAGE/.env.new" "$DIR/.env"; then
    if [[ -f $DIR/.env ]]; then mkdir -p "$bdir"; cp -p "$DIR/.env" "$bdir/.env"; backed=1; fi
    cp "$STAGE/.env.new" "$DIR/.env"
    env_changed=1
  fi
  chmod 600 "$DIR/.env"
  if [[ $SELF != "$DIR/setup.sh" ]]; then
    cp "$SELF" "$DIR/setup.sh"
  fi
  chmod +x "$DIR/setup.sh"
  if (( backed )); then info "Backups of replaced files: $bdir"; chmod -R go-rwx "$DIR/.backup" 2>/dev/null || true; fi
  return 0
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker was not found. Install Docker Engine with the Compose plugin: https://docs.docker.com/engine/install/"
    return 1
  fi
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif command -v sudo >/dev/null 2>&1; then
    info "The current user cannot access Docker - using sudo"
    DOCKER=(sudo docker)
    "${DOCKER[@]}" info >/dev/null 2>&1 || { err "Docker is not responding (is the service running?)"; return 1; }
  else
    err "Docker is not responding or access is denied (add your user to the docker group)"
    return 1
  fi
  if "${DOCKER[@]}" compose version >/dev/null 2>&1; then
    DC=("${DOCKER[@]}" compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    DC=(docker-compose)
  else
    err "The Docker Compose plugin (docker compose) is missing"
    return 1
  fi
  local v; v=$("${DC[@]}" version --short 2>/dev/null || true); v=${v#v}
  if [[ -n $v ]] && version_lt "$v" "2.20.0"; then
    err "Docker Compose $v is too old - version >= 2.20 is required (depends_on.required option)"
    return 1
  fi
  return 0
}

set_built() { # $1 = yes|no
  if [[ -f $DIR/$MARKER ]]; then
    sed "s/^BUILT=.*/BUILT=$1/" "$DIR/$MARKER" > "$DIR/$MARKER.tmp" && mv "$DIR/$MARKER.tmp" "$DIR/$MARKER"
  fi
}

do_build() {
  ensure_docker || return 1
  hdr "Building and starting"
  if ! ( cd "$DIR" && "${DC[@]}" up -d --build ); then
    err "Build or start failed (the files in $DIR remain ready)"
    return 1
  fi
  set_built yes
  info "Waiting for the container to start..."
  local i st=""
  for i in $(seq 1 30); do
    st=$("${DOCKER[@]}" inspect -f '{{.State.Status}}' logwatch-ai 2>/dev/null || true)
    if [[ $st == running ]]; then break; fi
    sleep 2
  done
  sleep 3
  info "Connectivity test from inside the container (this also sends a test message to Discord):"
  ( cd "$DIR" && "${DC[@]}" exec -T logwatch python -m app.cli check ) || warn "The connectivity test reported a problem - check the logs: docker compose logs logwatch"
  ( cd "$DIR" && "${DC[@]}" ps ) || true
  return 0
}

want_build() { # asks about building; returns 0 = build
  if (( NO_BUILD )); then return 1; fi
  if (( ASSUME_YES )); then return 0; fi
  echo
  confirm "Do you want to build the application? (y = build and start, n = only prepare the files)" y
}

print_next_steps() {
  hdr "Done"
  echo "  Directory:      $DIR"
  echo "  Logs:           cd $DIR && docker compose logs -f logwatch"
  echo "  CLI tool:       cd $DIR && docker compose exec logwatch python -m app.cli stats"
  echo "  Reconfigure / update:  $DIR/setup.sh [--reconfigure]"
}

print_manual_build() {
  hdr "Files prepared - not built"
  echo "  Directory:  $DIR"
  echo "  To build and start manually:"
  echo "      cd $DIR && docker compose up -d --build"
  echo "  or run again:  $DIR/setup.sh"
}

config_incomplete() { [[ -z ${CFG[ES_HOST]-} || -z ${CFG[OLLAMA_HOST]-} ]]; }

main() {
  load_spec

  if [[ -n $EXTRACT_DIR ]]; then
    mkdir -p "$EXTRACT_DIR"; emit_files "$EXTRACT_DIR"; render_env example > "$EXTRACT_DIR/.env.example"
    ok "Application sources unpacked to: $EXTRACT_DIR"
    exit 0
  fi

  printf '%s\n' "${C_B}LogWatch AI - setup v$SETUP_VERSION${C_0}"
  resolve_dir

  STAGE=$(mktemp -d)
  emit_files "$STAGE"
  render_env example > "$STAGE/.env.example"
  mapfile -t STAGED < <(cd "$STAGE" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)

  local k; declare -A OLDCFG
  if [[ -f $DIR/.env ]]; then load_env_file "$DIR/.env"; fi
  for k in "${!DEF[@]}"; do   # missing keys (e.g. new in this version) get their default values
    if [[ -z ${CFG[$k]+x} ]]; then CFG[$k]=${DEF[$k]}; fi
  done
  for k in DB_TYPE COMPOSE_PROFILES DB_HOST DB_PASSWORD; do OLDCFG[$k]=${CFG[$k]-}; done
  local had_env=0; if [[ -f $DIR/.env ]]; then had_env=1; fi

  local do_questions=0
  if [[ $MODE == update ]]; then
    read_manifest
    info "Found an installation in $DIR (version ${OLD_VERSION:-unknown}); this script: $SETUP_VERSION"
    if [[ -n $OLD_VERSION ]] && version_lt "$SETUP_VERSION" "$OLD_VERSION"; then
      warn "The installed version ($OLD_VERSION) is NEWER than this script ($SETUP_VERSION)."
      if ! confirm "Continue and overwrite the newer version with an older one?" n; then die "Aborted"; fi
    fi
    if (( RECONF )) || config_incomplete; then do_questions=1; fi
  else
    if (( had_env )); then
      info "A .env file already exists in $DIR - using it for the default values"
      read_manifest
    fi
    do_questions=1
  fi

  if (( do_questions )); then
    if [[ $MODE == install ]]; then hdr "Configuration"; fi
    info "Enter = the value in [ ], '-' clears an optional value."
    while true; do
      run_questions
      print_summary
      echo
      if confirm "Is the configuration correct?" y; then break; fi
      info "Going back to the questions (your current answers are the defaults)"
    done
    if (( had_env )) && [[ ${OLDCFG[DB_TYPE]} != "${CFG[DB_TYPE]}" || ${OLDCFG[DB_HOST]} != "${CFG[DB_HOST]}" || ${OLDCFG[COMPOSE_PROFILES]} != "${CFG[COMPOSE_PROFILES]}" ]]; then
      warn "The database was changed - the existing state (learned filters, cursor) is NOT migrated; the application will start from scratch."
    fi
    if (( had_env )) && [[ -n ${OLDCFG[DB_PASSWORD]} && ${OLDCFG[DB_PASSWORD]} != "${CFG[DB_PASSWORD]}" && ${CFG[COMPOSE_PROFILES]} != "" ]]; then
      warn "The password of a Docker database is only applied when its volume is created - changing it in .env will not change the password of an existing database."
    fi
  fi

  render_env real > "$STAGE/.env.new"
  plan_files

  local env_diff=0
  if [[ ! -f $DIR/.env ]] || ! cmp -s "$STAGE/.env.new" "$DIR/.env"; then env_diff=1; fi
  local self_diff=0
  if [[ $SELF != "$DIR/setup.sh" ]] && { [[ ! -f $DIR/setup.sh ]] || ! cmp -s "$SELF" "$DIR/setup.sh"; }; then self_diff=1; fi

  if [[ $MODE == update ]]; then
    if (( ${#ADD[@]} + ${#CHG[@]} + ${#REMOVED[@]} == 0 && env_diff == 0 && self_diff == 0 )); then
      ok "The application is up to date (version $SETUP_VERSION) - nothing to apply."
      if [[ $OLD_BUILT != yes ]] || { ensure_docker 2>/dev/null && [[ -z $( cd "$DIR" && "${DC[@]}" ps -q 2>/dev/null ) ]]; }; then
        warn "The application is not running."
        if want_build; then do_build && print_next_steps; else print_manual_build; fi
      fi
      exit 0
    fi
    hdr "Update plan"
    local r
    for r in "${ADD[@]}";     do echo "  ${C_G}+${C_0} $r (new)"; done
    for r in "${CHG[@]}";     do echo "  ${C_Y}~${C_0} $r (changed)"; done
    for r in "${REMOVED[@]}"; do echo "  ${C_R}-${C_0} $r (removed)"; done
    if (( env_diff )); then echo "  ${C_Y}~${C_0} .env (new keys or changed configuration; existing values are kept)"; fi
    if (( self_diff )); then echo "  ${C_Y}~${C_0} setup.sh (newer version of the script)"; fi
    if (( ${#LOCALMOD[@]} )); then warn "Hand-modified files will be overwritten (a copy goes to .backup/): ${LOCALMOD[*]}"; fi
    echo
    if (( ! ASSUME_YES )) && ! confirm "Apply the update?" y; then die "Aborted - nothing was changed"; fi
  fi

  apply_files
  run_migrations "$OLD_VERSION"
  write_manifest "$OLD_BUILT"
  if [[ $MODE == install ]]; then
    ok "Application structure written to $DIR"
  else
    ok "Update applied (version $SETUP_VERSION)"
  fi

  if want_build; then
    if do_build; then print_next_steps; else print_manual_build; exit 1; fi
  else
    print_manual_build
  fi
}

main "$@"
