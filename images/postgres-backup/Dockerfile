FROM docker.io/library/postgres@sha256:f7d23353e1b15400d22ebe31189f4d314b87a4c129cc400c8c2d8d4ca127bf81

ARG MC_VERSION="RELEASE.2025-08-13T08-35-41Z"
ARG MC_SHA256="01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891"

RUN set -eux; \
    GH_HOST="github.com"; \
    MC_URL="https://${GH_HOST}/minio/mc/releases/download/${MC_VERSION}/mc.linux-amd64.${MC_VERSION}"; \
    wget -q "${MC_URL}" -O /tmp/mc; \
    echo "${MC_SHA256}  /tmp/mc" | sha256sum -c -; \
    install -m 0755 /tmp/mc /usr/local/bin/mc; \
    rm -f /tmp/mc; \
    mc --version

COPY backup.sh /usr/local/bin/novabank-postgres-backup

RUN chmod 0555 /usr/local/bin/novabank-postgres-backup

USER postgres

ENTRYPOINT ["/usr/local/bin/novabank-postgres-backup"]
