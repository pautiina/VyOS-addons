
Для запуску експорту метрик VPP через кастомний скрипт, необхідно до конфігурації VyOS додати:
```
set service monitoring prometheus node-exporter collectors textfile
set service monitoring prometheus node-exporter listen-address '100.100.60.11'
set service monitoring prometheus node-exporter port '9100'
set system task-scheduler task vpp_metrics executable path '/config/scripts/vpp_metrics_v4.sh'
set system task-scheduler task vpp_metrics interval '1m'
```
Сам скрипт необхыдно покласти в:
```
/config/scripts/vpp_metrics.sh
```
Потім налаштовувати Prometheus and Grafana

# Використання основних метрик
В кастомний дашборд також додані інші метрики с іншого дашборду: https://grafana.com/grafana/dashboards/20315-vpp-performance-details/
Тому його теж необхідно налаштувати, а щоб метрики почали збиратись, необхідно в стартовий ```/config/scripts/vyos-postconfig-bootup.script``` додати скрипт з репозиторію. (на момент написання скриптів - VyOS ще не вміє через конфігурацію налаштовувати: vpp_prometheus_export
