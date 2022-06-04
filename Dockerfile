FROM golang:latest AS builder

ENV DATAPLANE_MINOR 2.5.3
ENV DATAPLANE_URL https://github.com/haproxytech/dataplaneapi.git

RUN git clone "${DATAPLANE_URL}" "${GOPATH}/src/github.com/haproxytech/dataplaneapi"
RUN cd "${GOPATH}/src/github.com/haproxytech/dataplaneapi" && \
    git checkout "v${DATAPLANE_MINOR}" && \
    make build && cp build/dataplaneapi /dataplaneapi


FROM debian:buster-slim as openssl-quic

WORKDIR /app
RUN apt-get update && \
    apt-get install -y --no-install-recommends  git  make ca-certificates gcc libc6-dev liblua5.3-dev libpcre3-dev libssl-dev libsystemd-dev make wget zlib1g-dev socat 
RUN git clone https://github.com/quictls/openssl && \
   cd openssl && \
   mkdir -p /opt/quictls/ssl && \ 
    ./Configure --libdir=lib --prefix=/opt/quictls && \
   make && make install && echo /opt/quictls/lib | sudo tee -a /etc/ld.so.conf
RUN ldconfig


FROM debian:buster-slim

MAINTAINER Dinko Korunic <dkorunic@haproxy.com>

LABEL Name HAProxy
LABEL Release Community Edition
LABEL Vendor HAProxy
LABEL Version 2.6.0
LABEL RUN /usr/bin/docker -d IMAGE

ENV HAPROXY_BRANCH 2.6
ENV HAPROXY_MINOR 2.6.0
ENV HAPROXY_SHA256 90f8e608aacd513b0f542e0438fa12e7fb4622cf58bd4375f3fe0350146eaa59
ENV HAPROXY_SRC_URL http://www.haproxy.org/download

ENV HAPROXY_UID haproxy
ENV HAPROXY_GID haproxy

ENV DEBIAN_FRONTEND noninteractive

COPY --from=builder /dataplaneapi /usr/local/bin/dataplaneapi
COPY --from=openssl-quic /opt/quictls/include /opt/quictls/include
COPY --from=openssl-quic /opt/quictls/lib /opt/quictls/lib
COPY --from=openssl-quic /etc/ld.so.conf /etc/ld.so.conf

RUN apt-get update && \
    apt-get install -y --no-install-recommends procps   zlib1g "libpcre2-*" liblua5.3-0 libatomic1 tar curl socat ca-certificates && \
    apt-get install -y --no-install-recommends gcc make libc6-dev  libpcre2-dev zlib1g-dev liblua5.3-dev && \
    c_rehash && \
    curl -sfSL "${HAPROXY_SRC_URL}/${HAPROXY_BRANCH}/src/haproxy-${HAPROXY_MINOR}.tar.gz" -o haproxy.tar.gz && \
    echo "$HAPROXY_SHA256 *haproxy.tar.gz" | sha256sum -c - && \
    groupadd "$HAPROXY_GID" && \
    useradd -g "$HAPROXY_GID" "$HAPROXY_UID" && \
    mkdir -p /tmp/haproxy && \
    tar -xzf haproxy.tar.gz -C /tmp/haproxy --strip-components=1 && \
    rm -f haproxy.tar.gz && \
    make -C /tmp/haproxy -j"$(nproc)" TARGET=linux-glibc CPU=generic USE_PCRE2=1 USE_PCRE2_JIT=1 USE_OPENSSL=1 \
                            USE_TFO=1 USE_LINUX_TPROXY=1 USE_QUIC=1  USE_LUA=1 USE_GETADDRINFO=1 \
                            USE_PROMEX=1 USE_SLZ=1 \
                            SSL_INC=/opt/quictls/include \
                            SSL_LIB=/opt/quictls/lib \
                            LDFLAGS="-Wl,-rpath,/opt/quictls/lib" \
                            all && \
    make -C /tmp/haproxy TARGET=linux-glibc install-bin install-man && \
    ln -s /usr/local/sbin/haproxy /usr/sbin/haproxy && \
    mkdir -p /var/lib/haproxy && \
    chown "$HAPROXY_UID:$HAPROXY_GID" /var/lib/haproxy && \
    mkdir -p /usr/local/etc/haproxy && \
    ln -s /usr/local/etc/haproxy /etc/haproxy && \
    cp -R /tmp/haproxy/examples/errorfiles /usr/local/etc/haproxy/errors && \
    rm -rf /tmp/haproxy && \
    apt-get purge -y --auto-remove gcc make libc6-dev libssl-dev libpcre2-dev zlib1g-dev liblua5.3-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    chmod +x /usr/local/bin/dataplaneapi && \
    ln -s /usr/local/bin/dataplaneapi /usr/bin/dataplaneapi && \
    touch /usr/local/etc/haproxy/dataplaneapi.hcl && \
    chown "$HAPROXY_UID:$HAPROXY_GID" /usr/local/etc/haproxy/dataplaneapi.hcl

COPY haproxy.cfg /usr/local/etc/haproxy
COPY docker-entrypoint.sh /

STOPSIGNAL SIGUSR1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["haproxy", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]