FROM python:3.11-slim

# gcc only to build the Umetrip signer; removed again to keep the image small
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY vendor/fuck-ume-trip /srv/vendor/fuck-ume-trip
RUN gcc -shared -fPIC -o /srv/vendor/fuck-ume-trip/umetrip/libumetrip.so \
        /srv/vendor/fuck-ume-trip/umetrip/UMETrip.c \
    && apt-get purge -y gcc libc6-dev && apt-get autoremove -y

COPY app /srv/app

ENV PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
