FROM bash:5 as prefetch

ARG DUMB_INIT_VERSION=1.2.5

RUN set -ex \
 && apk --no-cache add \
      curl \
 && curl -sSfLo /dumb-init "https://github.com/Yelp/dumb-init/releases/download/v${DUMB_INIT_VERSION}/dumb-init_${DUMB_INIT_VERSION}_x86_64" \
 && chmod 0755 /dumb-init


FROM bash:5

RUN set -ex \
 && apk --no-cache add \
      coreutils \
      curl \
      grep \
      openssh \
      rsync

COPY --from=prefetch  /dumb-init            /usr/local/bin/
COPY                  docker-entrypoint.sh  /usr/local/bin/

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
