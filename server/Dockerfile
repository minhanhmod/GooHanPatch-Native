FROM python:3.12-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HOST=0.0.0.0 PORT=8000 COOKIE_SECURE=1 DATA_DIR=/data
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt \
    && groupadd --gid 10001 patch && useradd --uid 10001 --gid patch --home-dir /app patch \
    && mkdir -p /data && chown -R patch:patch /data /app
COPY --chown=patch:patch main.py /app/main.py
USER patch
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=3)" || exit 1
CMD ["python", "main.py"]
