FROM grafana/beyla:1.8

COPY beyla.yaml /etc/beyla/beyla.yaml

ENV BEYLA_CONFIG_PATH=/etc/beyla/beyla.yaml

ENTRYPOINT ["beyla"]
