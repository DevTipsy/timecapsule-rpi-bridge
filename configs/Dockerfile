FROM debian:bookworm-slim

RUN apt update && apt install -y --no-install-recommends \
        git ca-certificates build-essential \
        libfuse-dev libreadline-dev libgcrypt20-dev \
        dpkg lsb-release \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

CMD ["/app/entrypoint.sh"]
