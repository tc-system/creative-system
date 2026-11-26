#!/bin/bash
# Dal crontab di csauto, ogni minuto: avvia il relay se non sta girando.
#   * * * * * /Users/csauto/mail-relay/avvia.sh
cd "$(dirname "$0")"
pgrep -f "mail-relay/relay.py" >/dev/null && exit 0
# Il registro non cresce all'infinito: oltre 5 MB si ricomincia
[ -f relay.log ] && [ "$(stat -f%z relay.log)" -gt 5000000 ] && mv relay.log relay.log.1
nohup /Users/csauto/shopify-mattino/.venv/bin/python -W ignore -u /Users/csauto/mail-relay/relay.py >> relay.log 2>&1 &
