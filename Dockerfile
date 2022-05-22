FROM debian

ENV SCRAPE_INTERVAL=10

# Installation, expose 2137 port, run in daemonless mode
RUN apt-get update && \
    apt-get install -yq nginx docker.io curl openssh-server sshpass rsync && \
    rm -f /var/www/html/index.nginx-debian.html && \
    ssh-keygen -b 2048 -t rsa -f ~/.ssh/id_rsa -q -N "" && \
    mkdir /var/run/sshd && \
    sed -i 's/^#PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd

COPY ./config/docker-entrypoint.sh /docker-entrypoint.sh
COPY ./config/nginx.conf /etc/nginx/nginx.conf

EXPOSE 2137
EXPOSE 22

CMD ["/docker-entrypoint.sh"]
