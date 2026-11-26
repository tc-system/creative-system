"""Libreria dei file di stampa dei calzini, per le righe d'ordine arrivate SENZA il file di Customily.

Lo stesso calzino a volte arriva con `_customily-production-url` e a volte no (Instagram, Shop, carrelli
senza il personalizzatore). Il file giusto è quello che Customily ha già prodotto per lo stesso prodotto e
colore in un altro ordine: la libreria lo conserva, così il mattino lo mette al posto giusto.

Cartella (CS_LIBRERIA_CALZINI, di base ~/shopify-mattino/libreria-calzini):
  <negozio>/<chiave>.png         file presi da Customily (li scrive lo script)
  <negozio>/a-mano/<chiave>.png  file messi a mano: vincono sempre su quelli di Customily
  indice.json                    per ogni chiave: file, impronta dei pixel, ordini da cui viene, campioni

Chiave = handle del prodotto, più il colore se il prodotto ha varianti di colore (la taglia non conta):
  "calzini-alzati-e-fattura", "calzini-love__rosso".
Righe personalizzate (campi visibili come "Testo" o "Nome") non entrano mai: il file cambia da cliente a cliente.
Un file è usato solo se è 23x43. Se due ordini dello stesso prodotto danno pixel diversi vale l'ultimo
(grafica aggiornata); se cambia di continuo il prodotto è segnato "variabile" e non si usa più.

Costruzione iniziale dagli ordini passati (sul Mac in sede):
  .venv/bin/python libreria_calzini.py --giorni 400
Python 3.9: niente sintassi 3.10+.
"""
import argparse
import datetime as dt
import hashlib
import io
import json
import os
import re
import sys
import time
import unicodedata
from pathlib import Path

import requests
from PIL import Image

QUI = Path(__file__).resolve().parent
CARTELLA = Path(os.environ.get('CS_LIBRERIA_CALZINI', str(QUI / 'libreria-calzini'))).expanduser()
ATTR_FILE_STAMPA = '_customily-production-url'
RAPPORTO = 23 / 43
CAMBI_MAX = 3   # dopo tanti cambi di grafica il prodotto è "variabile" (probabilmente personalizzato)

# Opzioni della variante che NON cambiano la grafica
NOME_TAGLIA = re.compile(r'taglia|size|misura|numero|quantit|pezzi', re.I)
VALORE_TAGLIA = re.compile(r'^(x{0,3}s|m|x{0,3}l|\d+\s*x?l|\d{2}\s*[-/]\s*\d{2}.*|.*\(\d{2}\s*[-/]\s*\d{2}\).*|default title)$', re.I)
# Ciucciami vende quasi solo calzini, anche con titoli senza "Calzini" ("Se tutto passa, salutamelo")
NON_CALZINI_CIUCCIAMI = re.compile(r'stampa nome|portachiavi|gift ?card|patch|t-?shirt|personalizzazione', re.I)


def e_calzino(negozio, l):
    titolo = l.get('title') or ''
    if re.search(r'calz|sock', titolo, re.I):
        return True
    return negozio == 'ciucciamilcalzino' and not NON_CALZINI_CIUCCIAMI.search(titolo)


def personalizzata(l):
    """Campi visibili sulla riga (Testo, Nome, ...): il file è del cliente, non del prodotto."""
    return any(not a['key'].startswith('_') and (a.get('value') or '').strip() for a in l.get('customAttributes') or [])


def _slug(t):
    t = unicodedata.normalize('NFKD', t).encode('ascii', 'ignore').decode().lower()
    return re.sub(r'[^a-z0-9]+', '-', t).strip('-')


def chiave(l):
    """None se la riga non ha più il prodotto (cancellato) o la variante non si legge."""
    handle = (l.get('product') or {}).get('handle')
    if not handle:
        return None
    opzioni = (l.get('variant') or {}).get('selectedOptions')
    if opzioni is None:
        return None
    colori = [_slug(o['value']) for o in opzioni
              if not NOME_TAGLIA.search(o['name']) and not VALORE_TAGLIA.match(o['value'].strip())]
    return '__'.join([handle] + [c for c in colori if c])


def impronta(dati):
    """Impronta dei pixel (Customily cambia metadati e compressione a ogni ordine) e misure."""
    with Image.open(io.BytesIO(dati)) as im:
        return hashlib.sha256(f'{im.mode}{im.size}'.encode() + im.tobytes()).hexdigest(), im.size


class Libreria:
    def __init__(self, cartella=CARTELLA):
        self.cartella = Path(cartella)
        self.indice_file = self.cartella / 'indice.json'
        try:
            self.indice = json.loads(self.indice_file.read_text())
        except (OSError, ValueError):
            self.indice = {}
        self.cambiata = False
        # Solo dove la cartella c'è (Mac in sede): sul server la libreria è spenta
        self.attiva = self.cartella.is_dir()

    def file(self, negozio, l):
        """Il file per questa riga: prima quello messo a mano, poi quello preso da Customily. None se non c'è."""
        k = chiave(l)
        if not k:
            return None
        a_mano = self.cartella / negozio / 'a-mano'
        for est in ('.png', '.jpg', '.jpeg', '.tif', '.tiff'):
            if (a_mano / f'{k}{est}').is_file():
                return a_mano / f'{k}{est}'
        v = self.indice.get(negozio, {}).get(k)
        if v and v.get('stato') == 'ok' and (self.cartella / v['file']).is_file():
            return self.cartella / v['file']
        return None

    def nome_a_mano(self, negozio, l):
        k = chiave(l)
        return f'{negozio}/a-mano/{k}.png' if k else None

    def registra(self, negozio, l, ordine, data, dati):
        """Un file di Customily appena scaricato per una riga: entra in libreria se serve. Ritorna True se ha cambiato qualcosa."""
        if not self.attiva or not e_calzino(negozio, l) or personalizzata(l):
            return False
        k = chiave(l)
        if not k:
            return False
        voci = self.indice.setdefault(negozio, {})
        v = voci.get(k)
        if v and (v.get('stato') == 'variabile' or ordine in v.get('ordini', [])):
            return False
        imp, (w, h) = impronta(dati)
        if abs(w / h - RAPPORTO) > 0.01:
            return False
        if v and v['impronta'] == imp:
            v['campioni'] += 1
            v['ordini'] = (v['ordini'] + [ordine])[-5:]
            self.cambiata = True
            return True
        rel = f'{negozio}/{k}.png'
        if v:   # grafica diversa: vale quella dell'ordine più recente, ma se cambia troppo spesso il prodotto non si usa
            v['cambi'] = v.get('cambi', 0) + 1
            self.cambiata = True
            if v['cambi'] >= CAMBI_MAX:
                v['stato'] = 'variabile'
                (self.cartella / rel).unlink(missing_ok=True)
                return True
            if data < v.get('data', ''):   # ordine più vecchio (costruzione dagli ordini passati): resta la grafica nuova
                v['campioni'] = 2   # non serve cercare altri campioni vecchi
                return True
        dest = self.cartella / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix('.part')
        tmp.write_bytes(dati)
        tmp.replace(dest)
        voci[k] = {'file': rel, 'impronta': imp, 'titolo': l.get('title'), 'variante': l.get('variantTitle'),
                   'ordini': [ordine], 'data': data, 'campioni': 1, 'cambi': (v or {}).get('cambi', 0), 'stato': 'ok'}
        self.cambiata = True
        return True

    def bisogno(self, negozio, l, ordine):
        """Conviene scaricare il file di questa riga? (chiave nuova o con un solo campione)"""
        if not e_calzino(negozio, l) or personalizzata(l):
            return False
        k = chiave(l)
        if not k:
            return False
        v = self.indice.get(negozio, {}).get(k)
        return not v or (v.get('stato') == 'ok' and v.get('campioni', 0) < 2 and ordine not in v.get('ordini', []))

    def salva(self):
        if not self.cambiata:
            return
        self.cartella.mkdir(parents=True, exist_ok=True)
        tmp = self.indice_file.with_suffix('.part')
        tmp.write_text(json.dumps(self.indice, ensure_ascii=False, indent=1, sort_keys=True))
        tmp.replace(self.indice_file)
        self.cambiata = False


ORDINI_PASSATI = '''query($c:String,$q:String){orders(first:40, after:$c, query:$q, sortKey:CREATED_AT, reverse:true){
 pageInfo{hasNextPage endCursor}
 nodes{name createdAt lineItems(first:100){nodes{title variantTitle customAttributes{key value}
  variant{selectedOptions{name value}} product{handle}}}}}}'''


def costruisci(shopify, negozio, giorni, lib, scrivi=print):
    """Scorre gli ordini degli ultimi `giorni` giorni (dal più recente) e riempie la libreria."""
    dal = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=giorni)).strftime('%Y-%m-%dT%H:%M:%SZ')
    c, ordini, scaricati, errori = None, 0, 0, 0
    while True:
        d = shopify.chiama(ORDINI_PASSATI, c=c, q=f'created_at:>={dal}')['orders']
        for o in d['nodes']:
            ordini += 1
            for l in o['lineItems']['nodes']:
                url = next((a['value'] for a in l['customAttributes'] if a['key'] == ATTR_FILE_STAMPA), None)
                if not url or not lib.bisogno(negozio, l, o['name']):
                    continue
                try:
                    r = requests.get(url, timeout=120)
                    r.raise_for_status()
                    lib.registra(negozio, l, o['name'], o['createdAt'], r.content)
                    scaricati += 1
                except Exception as e:
                    errori += 1
                    scrivi(f"  {o['name']} {l['title']}: {type(e).__name__} {str(e)[:80]}")
            if ordini % 200 == 0:
                lib.salva()
                scrivi(f'  {negozio}: {ordini} ordini letti, {scaricati} file scaricati, {len(lib.indice.get(negozio, {}))} chiavi')
        if not d['pageInfo']['hasNextPage']:
            break
        c = d['pageInfo']['endCursor']
    lib.salva()
    scrivi(f'{negozio}: {ordini} ordini, {scaricati} file scaricati, {errori} errori, {len(lib.indice.get(negozio, {}))} chiavi')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--giorni', type=int, default=400)
    ap.add_argument('--negozi', default='ciucciamilcalzino,boxfactorylab,bienjugado')
    ap.add_argument('--env', type=Path, default=QUI / '.env')
    args = ap.parse_args()
    sys.argv = sys.argv[:1]
    import mattino
    mattino.carica_env(args.env)
    negozi = {n['id']: n for n in mattino.dati_gestionale()['negozi']}
    CARTELLA.mkdir(parents=True, exist_ok=True)
    lib = Libreria()
    for nid in args.negozi.split(','):
        inizio = time.time()
        costruisci(mattino.Shopify(negozi[nid]), nid, args.giorni, lib, lambda t: print(t, flush=True))
        print(f'{nid}: {time.time() - inizio:.0f} s', flush=True)


if __name__ == '__main__':
    main()
