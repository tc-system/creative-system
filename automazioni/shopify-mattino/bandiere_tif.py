"""Bandierine di Bienjugado in TIF CMYK FOGRA39 + SPOT, una per file (per le scorte, Task → coda SCORTE).

Le bandiere sono quelle selezionabili sul sito (campo "Scegli la bandiera" di Globo Product Options).
Partono dalle PNG di Live Printing della libreria DTF di Box Factory Lab e diventano tutte rettangoli
uguali da 6,4 x 4 cm, come le bandiere di Bienjugado: si adattano al rettangolo; quelle quadrate con lo
stesso colore ai due lati (Svizzera) si allungano col colore del bordo, senza deformare la croce.

Uso (Mac mini, venv di shopify-mattino):
  python bandiere_tif.py --libreria "/Users/Shared/Creative System/Box Factory Lab DTF" --uscita <cartella> [--uscita <altra>]
"""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms

import dtf

BANDIERE = {
    'italia': 'IT', 'spagna': 'ES', 'argentina': 'AR', 'francia': 'FR', 'germania': 'DE', 'belgio': 'BE',
    'svizzera': 'CH', 'norvegia': 'NO', 'danimarca': 'DK', 'svezia': 'SE', 'finlandia': 'FI', 'usa': 'US', 'uk': 'GB',
}
LARGO_CM, ALTO_CM = 6.4, 4.0


def rettangolo(im):
    """La bandiera nel rettangolo 6,4 x 4; se il rapporto è lontano (oltre 20%) e i lati sono dello stesso colore, si allunga col bordo."""
    w, h = round(LARGO_CM / 2.54 * dtf.DPI), round(ALTO_CM / 2.54 * dtf.DPI)
    r = im.width / im.height
    sx, dx = im.getpixel((1, im.height // 2)), im.getpixel((im.width - 2, im.height // 2))
    if abs(r / (w / h) - 1) <= 0.2 or sx != dx:
        return im.resize((w, h), Image.LANCZOS)
    s = h / im.height
    dentro = im.resize((round(im.width * s), h), Image.LANCZOS)
    fondo = Image.new('RGBA', (w, h), sx)
    fondo.paste(dentro, ((w - dentro.width) // 2, 0))
    return fondo


def tif(png, uscita, fogra, icc):
    im = rettangolo(Image.open(png).convert('RGBA'))
    t = ImageCms.buildTransform(ImageCms.createProfile('sRGB'), fogra, 'RGB', 'CMYK',
                                renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC,
                                flags=ImageCms.Flags.BLACKPOINTCOMPENSATION)
    cmyk = dtf.neri_k100(np.asarray(ImageCms.applyTransform(im.convert('RGB'), t)))
    alfa = np.asarray(im)[..., 3]
    dtf.scrivi_foglio(uscita, cmyk, alfa, icc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--libreria', type=Path, required=True)
    ap.add_argument('--uscita', type=Path, action='append', required=True)
    a = ap.parse_args()
    lib = dtf.Libreria(a.libreria)
    fogra = lib.fogra()
    for nome, codice in BANDIERE.items():
        for cartella in a.uscita:
            cartella.mkdir(parents=True, exist_ok=True)
            tif(a.libreria / 'bandiere' / f'{codice}.png', cartella / f'bandiera-{nome}.tif', fogra, lib.icc)
        print('ok', nome)


if __name__ == '__main__':
    main()
