# Linux x86_64 environment for OpenWrt SDK (matches published *Linux-x86_64*.tar.zst SDKs).
# Build: docker compose build
# Run with repo + SDK tree mounted; see docker-compose.yml and docs/minimal-build-sdk.md

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
	build-essential \
	ccache \
	ecj \
	fastjar \
	file \
	g++ \
	gawk \
	gettext \
	git \
	java-propose-classpath \
	libelf-dev \
	libncurses5-dev \
	libncursesw5-dev \
	libreadline-dev \
	libsqlite3-dev \
	libssl-dev \
	perl \
	python3 \
	rsync \
	unzip \
	wget \
	xsltproc \
	zlib1g-dev \
	zstd \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /openwrt-sdk
