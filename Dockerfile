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
