# Grafana with the Azure Monitor managed Prometheus data source baked in. The
# cluster's egress firewall does not allow grafana.com, so nothing is downloaded
# at runtime: the plugin version is pinned here and the image is pinned by digest
# in gitops/.
FROM grafana/grafana:12.4.9
ARG AZURE_PROMETHEUS_PLUGIN_VERSION=1.0.9
# The image runs as grafana (uid 472); create the plugin directory as root and
# hand it over, then install as grafana so the files are owned correctly.
USER root
RUN mkdir -p /var/lib/grafana-plugins && chown 472:0 /var/lib/grafana-plugins
USER 472
RUN grafana cli --pluginsDir /var/lib/grafana-plugins plugins install \
      grafana-azureprometheus-datasource "${AZURE_PROMETHEUS_PLUGIN_VERSION}"
ENV GF_PATHS_PLUGINS=/var/lib/grafana-plugins
