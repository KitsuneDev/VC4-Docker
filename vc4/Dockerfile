FROM rust:1-alpine AS helpers

WORKDIR /src/helpers
RUN apk add --no-cache musl-dev
COPY helpers/Cargo.toml ./Cargo.toml
COPY helpers/vc4-room-auth/Cargo.toml ./vc4-room-auth/Cargo.toml
COPY helpers/vc4-syslog-watch/Cargo.toml ./vc4-syslog-watch/Cargo.toml
COPY helpers/vc4-room-auth/src ./vc4-room-auth/src
COPY helpers/vc4-syslog-watch/src ./vc4-syslog-watch/src
RUN cargo build --release --target x86_64-unknown-linux-musl -p vc4-room-auth -p vc4-syslog-watch

FROM rockylinux/rockylinux:9.3


ENV container=docker

RUN dnf -y update && \
    dnf -y install \
    python3 \
    python3-pip \
    expect \
    sudo \
    unzip \
    procps-ng \
    findutils \
    expect \
    bash \
    libatomic  \
    'dnf-command(config-manager)' && \
    dnf clean all

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install the systemctl replacement early because the vendor installer calls systemctl.
RUN pip3 install --no-cache-dir docker-systemctl-replacement && \
    cp -f /usr/local/bin/systemctl3.py /usr/local/bin/docker-systemctl && \
    ln -sf /usr/local/bin/docker-systemctl /usr/bin/systemctl && \
    mkdir -p /run/systemd/system /var/log && \
    touch /var/log/systemctl.log

WORKDIR /home/crestron

COPY installer/vc4.zip /home/crestron/vc4.zip
COPY install-vc4-rocky9.exp /usr/local/bin/install-vc4-rocky9.exp


RUN sed -i 's/\r$//' /usr/local/bin/install-vc4-rocky9.exp && \
    unzip -q /home/crestron/vc4.zip -d /home/crestron && \
    find /home/crestron -type f -name '*.sh' -exec sed -i 's/\r$//' {} + && \
    find /home/crestron -type f -name '*.sh' -exec chmod +x {} + && \
    installer="$(find /home/crestron -maxdepth 6 -type f \( -name 'install-vc4.sh' -o -name 'installVC4.sh' \) | head -n 1)" && \
    test -f "$installer" || { echo "Could not find VC4 installer"; find /home/crestron -maxdepth 6 -type f | sort; exit 127; } && \
    echo "Found installer: $installer" && \
    cd "$(dirname "$installer")" && \
    expect /usr/local/bin/install-vc4-rocky9.exp 2>&1 | tee /var/log/vc4-install-build.log && \
    ln -sf /usr/local/bin/docker-systemctl /usr/bin/systemctl && \
    systemctl enable mariadb.service || systemctl enable mysql.service || true && \
    systemctl enable redis.service || systemctl enable redis-server.service || true && \
    systemctl enable httpd.service || true && \
    systemctl enable virtualcontrol.service || true && \
    dnf clean all

RUN mkdir -p /usr/local/libexec

COPY --from=helpers /src/helpers/target/x86_64-unknown-linux-musl/release/vc4-room-auth /usr/local/bin/vc4-room-auth
COPY --from=helpers /src/helpers/target/x86_64-unknown-linux-musl/release/vc4-syslog-watch /usr/local/bin/vc4-syslog-watch
COPY vc4-entrypoint.sh /usr/local/sbin/vc4-entrypoint.sh
COPY vc4-container-restart.sh /usr/local/sbin/vc4-container-restart.sh
COPY vc4-container-restart-launch.sh /usr/local/sbin/vc4-container-restart-launch.sh
COPY vc4-systemctl-shim /usr/local/sbin/vc4-systemctl-shim
COPY vc4-eepromapp-shim /usr/local/sbin/vc4-eepromapp-shim
COPY vc4-pam-file-auth.sh /usr/local/sbin/vc4-pam-file-auth.sh
COPY vc4-restart-service.cgi /usr/local/libexec/vc4-restart-service.cgi
RUN chmod +x \
    /usr/local/sbin/vc4-entrypoint.sh \
    /usr/local/sbin/vc4-container-restart.sh \
    /usr/local/sbin/vc4-container-restart-launch.sh \
    /usr/local/sbin/vc4-systemctl-shim \
    /usr/local/sbin/vc4-eepromapp-shim \
    /usr/local/sbin/vc4-pam-file-auth.sh \
    /usr/local/libexec/vc4-restart-service.cgi

RUN printf 'apache ALL=(root) NOPASSWD: /usr/local/sbin/vc4-container-restart-launch.sh\nvirtualcontroluser ALL=(root) NOPASSWD: /usr/local/sbin/vc4-container-restart-launch.sh\n' > /etc/sudoers.d/vc4-container-restart && \
    chmod 0440 /etc/sudoers.d/vc4-container-restart

RUN dnf -y install libatomic && \
    ldconfig && \
    cat > /usr/local/bin/cgconfigparser <<'EOF' && \
    #!/usr/bin/env bash
    echo "[container] ignoring legacy $(basename "$0") call: $*" >&2
exit 0
EOF
RUN chmod +x /usr/local/bin/cgconfigparser && \
    ln -sf /usr/local/bin/cgconfigparser /usr/bin/cgconfigparser && \
    ln -sf /usr/local/bin/cgconfigparser /usr/sbin/cgconfigparser && \
    ln -sf /usr/local/bin/cgconfigparser /usr/bin/cgclassify && \
    ln -sf /usr/local/bin/cgconfigparser /usr/sbin/cgclassify && \
    command -v cgconfigparser && \
    command -v cgclassify && \
    ldconfig -p | grep -F libatomic

RUN dnf -y install mod_ssl mod_authnz_pam && \
    dnf clean all && \
    mkdir -p /etc/pki/tls/certs /etc/pki/tls/private && \
    if [[ ! -s /etc/pki/tls/certs/localhost.crt || ! -s /etc/pki/tls/private/localhost.key ]]; then \
      openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -subj '/CN=localhost' \
        -keyout /etc/pki/tls/private/localhost.key \
        -out /etc/pki/tls/certs/localhost.crt; \
    fi && \
    if ! grep -q '^LoadModule authnz_pam_module' /etc/httpd/conf.modules.d/55-authnz_pam.conf; then \
      echo 'LoadModule authnz_pam_module modules/mod_authnz_pam.so' >> /etc/httpd/conf.modules.d/55-authnz_pam.conf; \
    fi

EXPOSE 80 443 843 41794/tcp 41794/udp 41796 49200

CMD ["/usr/local/sbin/vc4-entrypoint.sh"]
