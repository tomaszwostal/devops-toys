FROM ubuntu:jammy

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    flex \
    bison \
    libssl-dev \
    libelf-dev \
    python3 \
    dwarves \
    bc \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir /build
RUN git config --system --add safe.directory /build
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
WORKDIR /build

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sh"]
