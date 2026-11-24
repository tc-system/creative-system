"""Da un file .ai (compatibile PDF) a TIF CMYK FOGRA39 + SPOT a 300 dpi, come i fogli DTF di dtf.py.

Si rende la prima pagina con trasparenza (PyMuPDF), si ritaglia sul disegno, si converte in CMYK FOGRA39
(neri a K100) e si scrive con lo SPOT = forma ridotta di 1 px. Serve per le grafiche che hanno solo il
vettoriale (es. Bienjugado "Siempre Por El Centro").

Uso (Mac mini, venv di TC DTF che ha pymupdf):
  python ai_tif.py --libreria "/Users/Shared/Creative System/Box Factory Lab DTF" file.ai uscita.tif [file2.ai uscita2.tif ...]
"""
import argparse
import sys
from pathlib import Path

import fitz
import numpy as np
from PIL import Image, ImageCms

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dtf  # noqa: E402


def converti(ai, uscita, fogra, icc):
    pag = fitz.open(ai)[0]
    pix = pag.get_pixmap(dpi=dtf.DPI, alpha=True)
    im = Image.frombytes('RGBA', (pix.width, pix.height), pix.samples)
    box = im.getchannel('A').getbbox()
    if not box:
        raise SystemExit(f'{ai}: pagina vuota')
    im = im.crop(box)
    t = ImageCms.buildTransform(ImageCms.createProfile('sRGB'), fogra, 'RGB', 'CMYK',
                                renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC,
                                flags=ImageCms.Flags.BLACKPOINTCOMPENSATION)
    cmyk = dtf.neri_k100(np.asarray(ImageCms.applyTransform(im.convert('RGB'), t)))
    alfa = np.asarray(im)[..., 3]
    Path(uscita).parent.mkdir(parents=True, exist_ok=True)
    dtf.scrivi_foglio(Path(uscita), cmyk, alfa, icc)
    print(f'ok {Path(uscita).name}: {im.width / dtf.DPI * 2.54:.1f} x {im.height / dtf.DPI * 2.54:.1f} cm')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--libreria', type=Path, required=True)
    ap.add_argument('coppie', nargs='+')
    a = ap.parse_args()
    if len(a.coppie) % 2:
        raise SystemExit('servono coppie file.ai uscita.tif')
    lib = dtf.Libreria(a.libreria)
    fogra = lib.fogra()
    for ai, out in zip(a.coppie[::2], a.coppie[1::2]):
        converti(ai, out, fogra, lib.icc)


if __name__ == '__main__':
    main()
