FROM python:3.12-slim

# ffmpeg für die Umwandlung nach M4A, Deno als JavaScript-Laufzeit für yt-dlp (YouTube)
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

ENV CACHE_DIR=/cache PORT=8080 PYTHONUNBUFFERED=1
VOLUME /cache
EXPOSE 8080
HEALTHCHECK --interval=60s --timeout=5s CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/')" || exit 1
CMD ["python", "app.py"]
