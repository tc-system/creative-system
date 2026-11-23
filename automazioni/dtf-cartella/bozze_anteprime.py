"""Anteprime JPG delle pagine di un PDF di bozze (per vederle subito sull'iPad nella pagina dell'ordine).
Gira nel venv di TC DTF (pymupdf), chiamato da bozze_nas.py.

Uso:  bozze_anteprime.py <pdf> <cartella uscita>
  → JPG delle pagine (p1.jpg, p2.jpg, …) e "leggero.pdf" fatto da quelle immagini: i PDF di Illustrator
    pesano decine di MB, quello leggero pochi MB e si apre subito sul telefono.
  Stampa {"pagine": [...], "pdf": "<percorso leggero.pdf>"}.
"""
import json
import os
import sys

import fitz  # pymupdf

MAX_PAGINE = 20
LATO = 1600   # pixel del lato lungo


def main(pdf, uscita):
    os.makedirs(uscita, exist_ok=True)
    out = []
    leggero = fitz.open()
    with fitz.open(pdf) as doc:
        for i, pagina in enumerate(doc):
            if i >= MAX_PAGINE:
                break
            r = pagina.rect
            zoom = LATO / max(r.width, r.height, 1)
            pix = pagina.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
            p = os.path.join(uscita, f'p{i + 1}.jpg')
            pix.save(p, jpg_quality=82)
            out.append(p)
            nuova = leggero.new_page(width=r.width, height=r.height)
            nuova.insert_image(nuova.rect, filename=p)
    dest = os.path.join(uscita, 'leggero.pdf')
    leggero.save(dest, deflate=True)
    leggero.close()
    print(json.dumps({'pagine': out, 'pdf': dest}))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
