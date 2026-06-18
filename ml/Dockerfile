FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir --upgrade pip

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY anomaly_detector.py .

RUN useradd -m -u 1001 appuser
RUN mkdir -p /models && chown appuser:appuser /models /app
USER appuser

EXPOSE 8090

VOLUME ["/models"]

CMD ["gunicorn", "--workers=1", "--bind=0.0.0.0:8090", "--timeout=60", "anomaly_detector:app"]
