"""T&C Factory — bozze degli ordini dal NAS → gestionale (pagina dell'ordine aperta col QR del modulo).

Gira ogni 5 minuti sul Mac mini (utente csauto, crontab), accanto a dtf_cartella.py di cui usa
configurazione, collegamento al NAS e ricerca della cartella del cliente.

Regola (Riccardo, 2026-11-23): per ogni ordine UN PDF con dentro le bozze, nella cartella del cliente,
anno corrente (va bene anche in una sottocartella, es. quella della lavorazione), con "bozza" e il nome
dell'ordine nel nome, e semmai la lavorazione (= descrizione dell'ordine). Niente numero d'ordine:
    <cliente>/<anno>/CROSSFIT MONZA bozza.pdf
    <cliente>/<anno>/CROSSFIT MONZA - FELPE bozza.pdf     (cliente con più ordini nello stesso anno)
Abbinamento tra gli ordini aperti dello stesso cliente: una bozza che nomina (nel nome o nella sottocartella)
le parole della lavorazione di un ordine va a quell'ordine; quella che non nomina nessuna lavorazione va agli
ordini del cliente che non hanno una bozza loro.
Per ogni ordine aperto del gestionale (non evaso, non archiviato, non eliminato):
  • trova la cartella del cliente (DATI/Clienti/<iniziale>/<cliente> o DATI/CrossFit/<box>, stesso
    abbinamento dei DTF: cliente collegato all'ordine, altrimenti nome dell'ordine);
  • cerca nell'anno corrente i PDF con "bozz" nel nome (non nelle cartelle dtf/tif) e li abbina come sopra;
  • carica nel bucket privato "bozze" le anteprime JPG delle pagine e un PDF leggero fatto da quelle
    (bozze_anteprime.py, venv con pymupdf; gli originali di Illustrator pesano decine di MB) e li elenca in ordini_bozze; se mancano salva dove andrebbero (percorso suggerito per il task).
A fine giro tc_bozze_task apre/chiude i task "Fare la bozza" (coda BOZZE del Centro di controllo).
Ordini evasi/eliminati → bozze tolte dal gestionale. Sul NAS solo lettura. NAS non collegato → non fa niente.

Uso:  bozze_nas.py [--prova] [--ordine 00411]
  --prova   stampa cosa farebbe, senza caricare né scrivere
Database: sql/bozze-ordini.sql, sql/bozze-pdf-task.sql; link di caricamento dalla funzione file-mattino.
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import unicodedata
import urllib.request
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dtf_cartella import (CARTELLA, DIR_DATI, GENERICHE, _lavorazione, cartelle_clienti,  # noqa: E402
                          leggi_config, monta_nas, rpc, salta, tokens, trova_cliente)

MAX_PESO = 2 * 1024 ** 3          # originali anche pesanti: nel gestionale va il PDF leggero fatto dalle anteprime
VENV_PY = os.path.join(DIR_DATI, 'venv', 'bin', 'python')
ANTEPRIME = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'bozze_anteprime.py')
NON_QUI = re.compile(r'dtf|^tiff?$|stampato|pdf originali', re.I)   # cartelle dei file di stampa: le bozze non stanno lì
STATO_BOZZE = os.path.join(DIR_DATI, 'bozze-stato.json')
VERSIONE = 3   # cambia → tutti gli ordini si risalvano (3: niente numero d'ordine, nome + lavorazione)
NON_CONTANO = GENERICHE | {'bozza', 'bozze', 'definitiva', 'definitivo', 'finale', 'versione', 'merch', 'abbigliamento'}


def funzione(cfg, dati):
    req = urllib.request.Request(
        f"{cfg['url']}/functions/v1/file-mattino", data=json.dumps(dati).encode(),
        headers={'apikey': cfg['anon'], 'Authorization': f"Bearer {cfg['anon']}", 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.load(r)
    if not out.get('success'):
        raise RuntimeError(out.get('error') or 'file-mattino: errore')
    return out


def bozze_pdf(anno):
    """PDF con "bozz" nel nome nella cartella dell'anno (sottocartelle comprese, max 3 livelli, no dtf/tif)."""
    if not os.path.isdir(anno):
        return []
    out = []
    for radice, dirs, files in os.walk(anno):
        dirs[:] = [d for d in dirs if not salta(d) and not NON_QUI.search(d)]
        if radice.count(os.sep) - anno.count(os.sep) >= 3:
            dirs[:] = []
        for n in files:
            if salta(n) or not n.lower().endswith('.pdf') or not re.search(r'bozz', n, re.I):
                continue
            p = os.path.join(radice, n)
            st = os.stat(p)
            if 0 < st.st_size <= MAX_PESO:
                out.append((unicodedata.normalize('NFC', os.path.relpath(p, anno)), p, st.st_size, round(st.st_mtime, 3)))
    out.sort(key=lambda x: -x[3])
    return out


def parole(testo, togli=()):
    return {t for t in tokens(testo) if len(t) >= 3 and not t.isdigit() and t not in NON_CONTANO and t not in togli}


def abbina_bozze(ordini, pdf):
    """{id ordine: [pdf]} tra gli ordini aperti di uno stesso cliente: la bozza va all'ordine di cui nomina più parole
    della lavorazione; quelle che non ne nominano nessuna vanno agli ordini rimasti senza bozza."""
    nomi = set().union(*(set(tokens(o.get('nome'))) | set(tokens(o.get('cliente'))) for o in ordini))
    lav = {o['id']: parole(o.get('descr'), nomi) for o in ordini}
    per = {o['id']: [] for o in ordini}
    generiche = []
    for f in pdf:
        w = parole(f[0], nomi)
        punti = {i: len(w & l) for i, l in lav.items()}
        best = max(punti.values(), default=0)
        if best:
            for i, n in punti.items():
                if n == best:
                    per[i].append(f)
        else:
            generiche.append(f)
    return {i: v or generiche for i, v in per.items()}


def nome_file(o):
    """Nome da dare al PDF: «<nome ordine> bozza.pdf», con la lavorazione se c'è."""
    nome = re.sub(r'\s+', ' ', (o.get('nome') or '').replace('/', '-')).strip()
    descr = re.sub(r'\s+', ' ', (o.get('descr') or '').replace('/', '-')).strip()
    return f"{nome}{' - ' + descr if descr else ''} bozza.pdf"


def dove_salvare(o, cli, dati_root):
    """Cartella in cui salvare il PDF se manca (relativa a DATI): anno del cliente, o la sua lavorazione se c'è già."""
    anno = str(datetime.now().year)
    if cli:
        base = os.path.join(cli, anno)
        return os.path.relpath(_lavorazione(base, o.get('descr') or '') or base, dati_root)
    nome = re.sub(r'\s+', ' ', (o.get('cliente') or o.get('nome') or '').replace('/', '-')).strip()
    if not nome:
        return None
    if 'crossfit' in tokens(nome):   # box: CrossFit/<nome senza "crossfit">
        box = ' '.join(w for w in nome.split() if tokens(w) != ['crossfit']) or nome
        return os.path.join('CrossFit', box.title() if box.isupper() else box, anno)
    nome = nome.title() if nome.isupper() else nome
    return os.path.join('Clienti', nome[0].upper(), nome, anno)


def percorso_storage(order_id, nome):
    """<ordine>/<codice>-<nome pulito>.pdf: il codice dal nome completo, così due file uguali in sottocartelle diverse non si pestano."""
    base = unicodedata.normalize('NFD', os.path.basename(nome))
    base = ''.join(c for c in base if not unicodedata.combining(c))
    base = re.sub(r'[^A-Za-z0-9._-]+', '-', base).strip('-.') or 'bozza'
    radice, ext = os.path.splitext(base)
    codice = hashlib.sha1(nome.encode()).hexdigest()[:8]
    return f"{order_id}/{codice}-{radice[:100]}{ext.lower()}"


def anteprime(pdf, cartella):
    r = subprocess.run([VENV_PY, '-I', ANTEPRIME, pdf, cartella], capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise RuntimeError('anteprime: ' + (r.stderr or '').strip()[-200:])
    return json.loads(r.stdout)


def carica(link, percorso, tipo):
    with open(percorso, 'rb') as f:
        dati = f.read()
    req = urllib.request.Request(link, data=dati, method='PUT', headers={'Content-Type': tipo, 'x-upsert': 'true'})
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
    anno = str(datetime.now().year)
    caricati = tolti = 0
    # Cartella del cliente di ogni ordine aperto, poi le bozze abbinate tra gli ordini dello stesso cliente
    ordini = dati.get('ordini') or []
    cli_di, gruppi = {}, {}
    for o in ordini:
        cli = trova_cliente(o, cartelle)
        cli_di[o['id']] = cli
        if cli:
            gruppi.setdefault(cli, []).append(o)
    bozze_di = {}
    for cli, gruppo in gruppi.items():
        try:
            bozze_di.update(abbina_bozze(gruppo, bozze_pdf(os.path.join(cli, anno))))
        except OSError as e:
            print(cli, 'cartella non letta:', e, file=sys.stderr)
            for o in gruppo:
                bozze_di[o['id']] = None
    for o in ordini:
        if a.ordine and o['id'] != a.ordine:
            continue
        cli = cli_di[o['id']]
        trovati = bozze_di.get(o['id'], [])
        if trovati is None:
            continue
        suggerito = dove_salvare(o, cli, dati_root)
        cartella = os.path.relpath(os.path.join(cli, anno), dati_root) if cli else ''
        prima = {b['nome']: b for b in o.get('bozze') or []}
        elenco, nuovi = [], []
        for nome, p, peso, mtime in trovati:
            st = percorso_storage(o['id'], nome)
            b = prima.get(nome)
            uguale = b and b.get('percorso') == st and int(b.get('peso') or 0) == peso and abs(float(b.get('mtime') or 0) - mtime) < 0.01
            elenco.append({'nome': nome, 'percorso': st, 'peso': peso, 'mtime': mtime, 'tipo': 'application/pdf',
                           'pagine': (b.get('pagine') or []) if uguale else []})
            if not uguale:
                nuovi.append((elenco[-1], p))
        firma = hashlib.sha1(json.dumps([VERSIONE, cartella, suggerito, nome_file(o), [(x['nome'], x['peso'], x['mtime']) for x in elenco]],
                                        sort_keys=True).encode()).hexdigest()
        if not nuovi and firme.get(o['id']) == firma and len(elenco) == len(prima):
            continue
        if a.prova:
            print(f"{o['id']} {o['nome']}: {len(elenco)} bozze ({len(nuovi)} da caricare) {[x['nome'] for x in elenco]}"
                  + ('' if elenco else f" — da salvare in {suggerito or '?'} come «{nome_file(o)}»"))
            continue
        try:
            with tempfile.TemporaryDirectory() as tmp:
                su = []
                for i, (x, p) in enumerate(nuovi):
                    ant = anteprime(p, os.path.join(tmp, str(i)))
                    radice = x['percorso'][:-4]
                    x['pagine'] = [f'{radice}-p{k + 1}.jpg' for k in range(len(ant['pagine']))]
                    su += [(x['percorso'], ant['pdf'], 'application/pdf')] + [(s, j, 'image/jpeg') for s, j in zip(x['pagine'], ant['pagine'])]
                if su:
                    link = funzione(cfg, {'chiave': cfg['chiave'], 'azione': 'bozze-carica', 'percorsi': [s[0] for s in su]})['link']
                    for st, p, tipo in su:
                        carica(link[st], p, tipo)
                        caricati += 1
            restano = {s for x in elenco for s in [x['percorso'], *x['pagine']]}
            giu = [s for b in prima.values() for s in [b['percorso'], *(b.get('pagine') or [])] if s not in restano]
            if giu:
                funzione(cfg, {'chiave': cfg['chiave'], 'azione': 'bozze-togli', 'percorsi': giu})
                tolti += len(giu)
            r = rpc(cfg, 'tc_bozze_salva', {'p_chiave': cfg['chiave'], 'p_order_id': o['id'], 'p_cartella': cartella,
                                            'p_files': elenco, 'p_suggerito': suggerito, 'p_nome_file': nome_file(o)})
            if not r.get('success'):
                raise RuntimeError(r.get('error'))
            firme[o['id']] = firma
        except Exception as e:   # un ordine che non va non ferma gli altri
            print(o['id'], 'non aggiornato:', type(e).__name__, str(e)[:200], file=sys.stderr)

    # Ordini chiusi: bozze tolte dal gestionale
    for c in ([] if a.ordine else dati.get('chiusi') or []):
        if a.prova:
            print(f"{c['id']} chiuso: tolgo {len(c['percorsi'])} file")
            continue
        try:
            funzione(cfg, {'chiave': cfg['chiave'], 'azione': 'bozze-togli', 'percorsi': c['percorsi']})
            rpc(cfg, 'tc_bozze_salva', {'p_chiave': cfg['chiave'], 'p_order_id': c['id'], 'p_cartella': '-', 'p_files': []})
            tolti += len(c['percorsi'])
            firme.pop(c['id'], None)
        except Exception as e:
            print(c['id'], 'bozze non tolte:', type(e).__name__, str(e)[:200], file=sys.stderr)

    if a.prova:
        return 0
    aperti = {o['id'] for o in dati.get('ordini') or []}
    firme = {k: v for k, v in firme.items() if k in aperti}
    with open(STATO_BOZZE + '.tmp', 'w') as f:
        json.dump(firme, f)
    os.replace(STATO_BOZZE + '.tmp', STATO_BOZZE)
    t = rpc(cfg, 'tc_bozze_task', {'p_chiave': cfg['chiave']})
    if caricati or tolti or t.get('aperti') or t.get('chiusi'):
        print(datetime.now().isoformat(timespec='seconds'),
              f"bozze: {caricati} file caricati, {tolti} tolti; task {t.get('aperti', 0)} aperti, {t.get('chiusi', 0)} chiusi")
    return 0


if __name__ == '__main__':
    sys.exit(main())
