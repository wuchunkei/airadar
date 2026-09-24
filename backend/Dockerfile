FROM python:3.11-slim

WORKDIR /srv
COPY requirements.txt .
# timezonefinder alone is a ~50 MB download; pip's 15 s default read timeout
# gives up on a slow link, so wait longer and retry.
RUN pip install --no-cache-dir --default-timeout=120 --retries 10 -r requirements.txt

COPY app /srv/app

ENV PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
