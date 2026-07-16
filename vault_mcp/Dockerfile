ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:bookworm
FROM ${BUILD_FROM}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends git jq curl ca-certificates gnupg openssh-client \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-cache npm-pakkerne så opstart ikke afhænger af npm-registry.
# PINNEDE versioner: --stateful/--sessionTimeout kræver supergateway >= 3.4,
# og deterministiske builds gør fejlsøgning mulig. Bump bevidst, ikke implicit.
RUN npm install -g supergateway@3.4.3 @bitbonsai/mcpvault@0.11.0 \
    && npm cache clean --force

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
