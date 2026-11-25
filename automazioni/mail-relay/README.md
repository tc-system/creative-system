# Relay mail (Mac mini in sede)

Aruba ogni tanto rifiuta gli IP AWS da cui escono le funzioni Supabase (`550 5.1.0 … temporaneamente rifiutata`).
Le funzioni (`supabase/functions/_shared/mail.ts`) mettono la mail già composta in `mail_relay_coda`
(`sql/mail-relay.sql`); `relay.py` sul Mac mini la prende ogni secondo e la consegna ad Aruba dalla connessione
dell'ufficio. Se l'agente non si fa vivo da 15 s o non prende la mail entro 6 s, le funzioni inviano direttamente
(con 3 riprove). Password e testo si cancellano dalla coda appena l'invio finisce.

- Sul Mac mini: `/Users/csauto/mail-relay/` (utente csauto), usa `.env` e `.venv` di `~/shopify-mattino`.
- Acceso dal crontab di csauto: `* * * * * /Users/csauto/mail-relay/avvia.sh` (lo riavvia se si ferma).
- Registro: `~/mail-relay/relay.log`.
- Aggiornare: `scp -i ~/.ssh/csauto_macmini relay.py avvia.sh csauto@192.168.1.13:mail-relay/`, poi `pkill -f mail-relay/relay.py` (il cron lo riavvia entro un minuto).
