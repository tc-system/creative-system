#!/usr/bin/env python3
"""Relay mail sul Mac mini in sede.

Aruba ogni tanto rifiuta gli IP AWS da cui escono le funzioni Supabase. Le funzioni mettono la mail già
composta nella coda (sql/mail-relay.sql); questo agente la prende ogni secondo e la consegna ad Aruba
dalla connessione dell'ufficio. Usa il .env dello script del mattino (CS_SUPABASE_URL, CS_ANON_KEY,
CS_AUTOMAZIONE_KEY). Lo tiene acceso avvia.sh dal crontab di csauto.
"""
import base64, os, smtplib, socket, ssl, sys, time
from pathlib import Path
import requests

AGENTE = socket.gethostname().split('.')[0]
ENV = Path(os.environ.get('RELAY_ENV', Path.home() / 'shopify-mattino' / '.env'))


def log(testo):
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {testo}", flush=True)


def carica_env():
    if ENV.exists():
        for riga in ENV.read_text().splitlines():
            if '=' in riga and not riga.lstrip().startswith('#'):
                k, v = riga.split('=', 1)
                os.environ.setdefault(k.strip(), v.strip())
    mancanti = [k for k in ('CS_SUPABASE_URL', 'CS_ANON_KEY', 'CS_AUTOMAZIONE_KEY') if not os.environ.get(k)]
    if mancanti:
        sys.exit(f'Mancano le impostazioni: {", ".join(mancanti)}')


sessione = requests.Session()


def rpc(funzione, **parametri):
    r = sessione.post(f"{os.environ['CS_SUPABASE_URL']}/rest/v1/rpc/{funzione}",
                      headers={'apikey': os.environ['CS_ANON_KEY'], 'Content-Type': 'application/json'},
                      json={'p_chiave': os.environ['CS_AUTOMAZIONE_KEY'], **parametri}, timeout=20)
    r.raise_for_status()
    d = r.json()
    if not d.get('success'):
        raise RuntimeError(d.get('error') or 'Gestionale non raggiungibile')
    return d


def invia(m):
    """Ritorna (ok, errore, prima_del_testo)."""
    fase = 'connessione'
    try:
        s = smtplib.SMTP_SSL(m['host'], m.get('porta') or 465, timeout=30, context=ssl.create_default_context())
        try:
            fase = 'login'
            s.login(m['utente'], m['pass'])
            fase = 'mittente'
            codice, risp = s.mail(m['da'])
            if codice != 250:
                raise smtplib.SMTPSenderRefused(codice, risp, m['da'])
            fase = 'destinatari'
            for a in [x.strip() for x in m['a'].split(',') if x.strip()]:
                codice, risp = s.rcpt(a)
                if codice not in (250, 251):
                    raise smtplib.SMTPRecipientsRefused({a: (codice, risp)})
            fase = 'testo'
            codice, risp = s.data(base64.b64decode(m['raw']))
            if codice != 250:
                raise smtplib.SMTPDataError(codice, risp)
            fase = 'fine'
        finally:
            try:
                s.quit()
            except Exception:
                pass
        return True, None, None
    except Exception as e:
        if fase == 'fine':   # errore solo nel chiudere: la mail è partita
            return True, None, None
        return False, f'{type(e).__name__}: {e}'[:500], fase != 'testo'


def main():
    carica_env()
    log(f'Relay mail avviato ({AGENTE})')
    errori = 0
    while True:
        try:
            m = rpc('tc_mail_relay_prossima', p_agente=AGENTE).get('mail')
            errori = 0
        except Exception as e:
            errori += 1
            if errori in (1, 10) or errori % 300 == 0:
                log(f'Gestionale non raggiungibile: {e}')
            time.sleep(min(30, errori))
            continue
        if not m:
            time.sleep(1)
            continue
        t = time.time()
        ok, errore, prima = invia(m)
        log(f"#{m['id']} da {m['da']}: {'inviata' if ok else 'ERRORE ' + errore} ({time.time() - t:.1f}s)")
        for _ in range(5):
            try:
                rpc('tc_mail_relay_esito', p_id=m['id'], p_ok=ok, p_errore=errore, p_prima_del_testo=prima)
                break
            except Exception as e:
                log(f"Esito #{m['id']} non salvato: {e}")
                time.sleep(2)


if __name__ == '__main__':
    main()
