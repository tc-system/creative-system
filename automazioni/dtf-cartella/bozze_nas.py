"""T&C Factory — bozze degli ordini dal NAS → gestionale (pagina dell'ordine aperta col QR del modulo).

Gira ogni 5 minuti sul Mac mini (utente csauto, crontab), accanto a dtf_cartella.py di cui usa
configurazione, collegamento al NAS e ricerca della cartella del cliente.

Per ogni ordine aperto del gestionale (non evaso, non archiviato, non eliminato):
  • trova la cartella del cliente (DATI/Clienti/<iniziale>/<cliente> o DATI/CrossFit/<box>, stesso
    abbinamento dei DTF: cliente collegato all'ordine, altrimenti nome dell'ordine);
  • nell'anno corrente cerca la cartella "bozze": prima in <anno>/<lavorazione> (= descrizione
    dell'ordine), poi in <anno>;
  • carica immagini e PDF (anche nelle sottocartelle) nel bucket privato "bozze" del gestionale
    e li elenca in ordini_bozze. File tolti dal NAS → tolti anche dal gestionale.
Ordini evasi/eliminati → bozze tolte dal gestionale (sul NAS non si tocca mai niente: solo lettura).
Se il NAS non è collegato non fa niente (non cancella).

Uso:  bozze_nas.py [--prova] [--ordine 00411]
  --prova   stampa cosa farebbe, senza caricare né scrivere
Database: sql/bozze-ordini.sql; link di caricamento dalla funzione file-mattino (azioni bozze-*).
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import unicodedata
import urllib.request
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dtf_cartella import (CARTELLA, DIR_DATI, _lavorazione, cartelle_clienti, leggi_config,  # noqa: E402
                          monta_nas, rpc, salta, trova_cliente)

ESTENSIONI = {'.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp',
              '.gif': 'image/gif', '.pdf': 'application/pdf'}
MAX_PESO = 50 * 1024 * 1024      # come il limite del bucket
MAX_FILE = 80                    # per ordine, i più recenti
BOZZE_DIR = re.compile(r'bozz[ae]', re.I)
STATO_BOZZE = os.path.join(DIR_DATI, 'bozze-stato.json')


def funzione(cfg, dati):
    req = urllib.request.Request(
        f"{cfg['url']}/functions/v1/file-mattino", data=json.dumps(dati).encode(),
        headers={'apikey': cfg['anon'], 'Authorization': f"Bearer {cfg['anon']}", 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.load(r)
    if not out.get('success'):
        raise RuntimeError(out.get('error') or 'file-mattino: errore')
    return out


def _sotto_bozze(d):
    if not d or not os.path.isdir(d):
        return None
    for n in sorted(os.listdir(d)):
        p = os.path.join(d, n)
        if not salta(n) and os.path.isdir(p) and BOZZE_DIR.search(n):
            return p
    return None


def cartella_bozze(o, cartelle):
    cli = trova_cliente(o, cartelle)
    if not cli:
        return None
    anno = os.path.join(cli, str(datetime.now().year))
    if not os.path.isdir(anno):
        return None
    return _sotto_bozze(_lavorazione(anno, o.get('descr') or '')) or _sotto_bozze(anno)


def files_bozze(cartella):
    """[(nome relativo, percorso, peso, mtime, tipo)] immagini e PDF, sottocartelle comprese, i più recenti prima."""
    out = []
    for radice, dirs, files in os.walk(cartella):
        dirs[:] = [d for d in dirs if not salta(d)]
        if radice.count(os.sep) - cartella.count(os.sep) > 2:
            dirs[:] = []
        for n in files:
            tipo = ESTENSIONI.get(os.path.splitext(n)[1].lower())
            if salta(n) or not tipo:
                continue
            p = os.path.join(radice, n)
            st = os.stat(p)
            if st.st_size == 0 or st.st_size > MAX_PESO:
                continue
            nome = unicodedata.normalize('NFC', os.path.relpath(p, cartella))
            out.append((nome, p, st.st_size, round(st.st_mtime, 3), tipo))
    out.sort(key=lambda x: -x[3])
    return out[:MAX_FILE]


def percorso_storage(order_id, nome):
    """<ordine>/<codice>-<nome pulito>: il codice dal nome completo, così due file uguali in sottocartelle diverse non si pestano."""
    base = unicodedata.normalize('NFD', os.path.basename(nome))
    base = ''.join(c for c in base if not unicodedata.combining(c))
    base = re.sub(r'[^A-Za-z0-9._-]+', '-', base).strip('-.') or 'bozza'
    radice, ext = os.path.splitext(base)
    codice = hashlib.sha1(nome.encode()).hexdigest()[:8]
    return f"{order_id}/{codice}-{radice[:100]}{ext.lower()}"


def carica(link, percorso, tipo):
    with open(percorso, 'rb') as f:
        dati = f.read()
    req = urllib.request.Request(link, data=dati, method='PUT',
                                 headers={'Content-Type': tipo, 'x-upsert': 'true'})
    with urllib.request.urlopen(req, timeout=300) as r:
        r.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--prova', action='store_true')
    ap.add_argument('--ordine', help='solo questo ordine')
    a = ap.parse_args()
    cfg = leggi_config()

    os.makedirs(DIR_DATI, exist_ok=True)
    blocco = open(os.path.join(DIR_DATI, 'bozze.lock'), 'w')
    try:
        fcntl.flock(blocco, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0

    if cfg.get('nas'):
        monta_nas(cfg['nas'])
    dati_root = os.path.normpath(os.path.join(cfg.get('cartella') or CARTELLA, '..', '..', '..'))
    if not os.path.isdir(os.path.join(dati_root, 'Clienti')):
        print(datetime.now().isoformat(timespec='seconds'), 'NAS non raggiungibile: niente da fare', file=sys.stderr)
        return 1

    dati = rpc(cfg, 'tc_bozze_ordini', {'p_chiave': cfg['chiave']})
    if not dati.get('success'):
        raise RuntimeError(dati.get('error'))
    try:
        with open(STATO_BOZZE) as f:
            firme = json.load(f)
    except (OSError, ValueError):
        firme = {}

    cartelle = cartelle_clienti(dati_root)
    ordini = [o for o in dati.get('ordini') or [] if not a.ordine or o['id'] == a.ordine]
    piani = []   # (ordine, cartella relativa, elenco finale, da caricare, da togliere)
    for o in ordini:
        try:
            cb = cartella_bozze(o, cartelle)
            trovati = files_bozze(cb) if cb else []
        except OSError as e:
            print(o['id'], 'cartella non letta:', e, file=sys.stderr)
            continue
        prima = {b['nome']: b for b in o.get('bozze') or []}
        elenco, su = [], []
        for nome, p, peso, mtime, tipo in trovati:
            st = percorso_storage(o['id'], nome)
            elenco.append({'nome': nome, 'percorso': st, 'peso': peso, 'mtime': mtime, 'tipo': tipo})
            b = prima.get(nome)
            if not b or b.get('percorso') != st or int(b.get('peso') or 0) != peso or abs(float(b.get('mtime') or 0) - mtime) > 0.01:
                su.append((st, p, tipo))
        nuovi = {x['percorso'] for x in elenco}
        giu = [b['percorso'] for b in prima.values() if b['percorso'] not in nuovi]
        rel = os.path.relpath(cb, dati_root) if cb else ''
        piani.append((o, rel, elenco, su, giu))

    caricati = tolti = 0
    for o, rel, elenco, su, giu in piani:
        firma = hashlib.sha1(json.dumps([rel, elenco], sort_keys=True).encode()).hexdigest()
        if not su and not giu and firme.get(o['id']) == firma:
            continue
        if a.prova:
            print(f"{o['id']} {o['nome']}: {rel or 'cartella bozze non trovata'} — {len(elenco)} file, "
                  f"da caricare {len(su)}, da togliere {len(giu)}")
            continue
        try:
            if su:
                link = funzione(cfg, {'chiave': cfg['chiave'], 'azione': 'bozze-carica', 'percorsi': [s[0] for s in su]})['link']
                for st, p, tipo in su:
                    carica(link[st], p, tipo)
                    caricati += 1
            if giu:
                funzione(cfg, {'chiave': cfg['chiave'], 'azione': 'bozze-togli', 'percorsi': giu})
                tolti += len(giu)
            r = rpc(cfg, 'tc_bozze_salva', {'p_chiave': cfg['chiave'], 'p_order_id': o['id'], 'p_cartella': rel, 'p_files': elenco})
            if not r.get('success'):
                raise RuntimeError(r.get('error'))
            firme[o['id']] = firma
        except Exception as e:   # un ordine che non va non ferma gli altri
            print(o['id'], 'non aggiornato:', type(e).__name__, str(e)[:200], file=sys.stderr)

    # Ordini chiusi: bozze tolte dal gestionale
    for c in ([] if a.ordine else dati.get('chiusi') or []):
        if a.prova:
            print(f"{c['id']} chiuso: tolgo {len(c['percorsi'])} bozze")
            continue
        try:
            funzione(cfg, {'chiave': cfg['chiave'], 'azione': 'bozze-togli', 'percorsi': c['percorsi']})
            rpc(cfg, 'tc_bozze_salva', {'p_chiave': cfg['chiave'], 'p_order_id': c['id'], 'p_cartella': '-', 'p_files': []})
            tolti += len(c['percorsi'])
            firme.pop(c['id'], None)
        except Exception as e:
            print(c['id'], 'bozze non tolte:', type(e).__name__, str(e)[:200], file=sys.stderr)

    if not a.prova:
        aperti = {o['id'] for o in dati.get('ordini') or []}
        firme = {k: v for k, v in firme.items() if k in aperti}
        with open(STATO_BOZZE + '.tmp', 'w') as f:
            json.dump(firme, f)
        os.replace(STATO_BOZZE + '.tmp', STATO_BOZZE)
    if caricati or tolti:
        print(datetime.now().isoformat(timespec='seconds'), f'bozze: {caricati} caricate, {tolti} tolte')
    return 0


if __name__ == '__main__':
    sys.exit(main())
