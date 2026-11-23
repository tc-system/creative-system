"""T&C Factory — PDF → TIF per il DTF, come i fogli di Box Factory Lab (shopify-mattino/dtf.py):
  • CMYK Coated FOGRA39 a 300 dpi, misura della pagina del PDF;
  • neri SEMPRE C0 M0 Y0 K100 (richiesta utente 2026-11-23); bordi e sfumature neutre col nero solo in K;
  • canale extra SPOT1 salvato come Photoshop (tinta piatta, inchiostro = 0): la forma di tutto quello
    che è stampato (il fondo trasparente resta senza bianco), ridotta di RIDUZIONE pixel (0, 1, 2 o 3).
    Il RIP del DTF lo legge come canale del bianco solo se il file è uguale a quelli salvati da Photoshop
    (2026-11-23: i TIF senza queste informazioni non davano il bianco): stesse risorse Photoshop
    (nome, identificatori dei canali, risoluzione, versione), Software, predictor, orientamento e XMP.
Una pagina → <nome>.tif; più pagine → <nome> - pag 1.tif, <nome> - pag 2.tif…
I file si scrivono prima come .part e poi si rinominano: nella cartella non resta mai un TIF a metà.

Gira nel suo ambiente (venv con pymupdf, numpy, pillow, tifffile), chiamato da dtf_cartella.py.
Uso:  dtf_tiff.py PDF RIDUZIONE --icc fogra39.icc
Stampa in JSON i nomi dei TIF scritti.
"""
import argparse
import json
import os
import sys

import numpy as np
import pymupdf
import tifffile
from PIL import Image, ImageFilter

DPI = 300
SOGLIA_NERO = 0.12      # come box-factory-dtf/libreria.py
SOGLIA_NEUTRO = 0.07


def neri_k100(cmyk):
    """Neri solo in K: il nero pieno (anche ricco o quasi nero) diventa 0/0/0/100 e ogni pixel neutro che
    contiene nero (bordi tra il nero e un grigio, sfumature) diventa solo K con la stessa densità.
    I grigi fatti senza nero e i colori non si toccano."""
    f = cmyk.astype(np.float32) / 255
    k = 1 - f[..., 3]
    rgb = np.stack([(1 - f[..., 0]) * k, (1 - f[..., 1]) * k, (1 - f[..., 2]) * k], -1)
    neutro = rgb.max(-1) - rgb.min(-1) < SOGLIA_NEUTRO
    luce = rgb.mean(-1)
    solo_k = neutro & ((cmyk[..., 3] >= 8) | (rgb.max(-1) < SOGLIA_NERO))
    out = cmyk.copy()
    densita = np.clip((1 - luce) / (1 - SOGLIA_NERO), 0, 1)
    out[..., :3][solo_k] = 0
    out[..., 3][solo_k] = np.round(densita[solo_k] * 255).astype(np.uint8)
    return out


SOFTWARE = 'Adobe Photoshop 27.11 (Macintosh)'


def risorse_photoshop():
    """Risorse come le scrive Photoshop per un TIF CMYK con un canale tinta piatta "SPOT1" (rosso, 100%)."""
    def blocco(rid, dati):
        return b'8BIM' + rid.to_bytes(2, 'big') + b'\x00\x00' + len(dati).to_bytes(4, 'big') + dati + b'\x00' * (len(dati) % 2)
    ris = (DPI << 16).to_bytes(4, 'big') + b'\x00\x01\x00\x02'          # 300 dpi, mostrati in cm
    return b''.join([
        blocco(0x03ED, ris + ris),
        blocco(0x03EE, b'\x05SPOT1'),
        blocco(0x0415, (6).to_bytes(4, 'big') + 'SPOT1\x00'.encode('utf-16-be')),
        blocco(0x0435, b'\x00\x00\x00\x01' + b'\x00\x00' + b'\xff\xff\x00\x00\x00\x00\x00\x00' + b'\x00\x64' + b'\x02'),
        blocco(0x041D, (2).to_bytes(4, 'big')),                          # identificatore del canale
        blocco(0x0414, (2).to_bytes(4, 'big')),
        blocco(0x0421, bytes.fromhex('00000001010000000f00410064006f00620065002000500068006f0074006f00730068006f007000000014'
                                     '00410064006f00620065002000500068006f0074006f00730068006f00700020003200300032003600000001')),
    ])


def xmp(larghezza, altezza):
    return f"""<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
 xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmlns:tiff="http://ns.adobe.com/tiff/1.0/">
<xmp:CreatorTool>{SOFTWARE}</xmp:CreatorTool><dc:format>image/tiff</dc:format>
<photoshop:ColorMode>4</photoshop:ColorMode><photoshop:ICCProfile>Coated FOGRA39 (ISO 12647-2:2004)</photoshop:ICCProfile>
<tiff:ImageWidth>{larghezza}</tiff:ImageWidth><tiff:ImageLength>{altezza}</tiff:ImageLength>
<tiff:PhotometricInterpretation>5</tiff:PhotometricInterpretation><tiff:SamplesPerPixel>5</tiff:SamplesPerPixel>
</rdf:Description></rdf:RDF></x:xmpmeta>
<?xpacket end="w"?>""".encode('utf-8')


def pagina_in_tif(pagina, dest, riduzione, icc):
    # MuPDF converte in CMYK col suo profilo di default (Coated FOGRA39); i colori sono già
    # composti sul bianco (premoltiplicati), come un TIF unito in Photoshop
    pix = pagina.get_pixmap(dpi=DPI, colorspace=pymupdf.csCMYK, alpha=True)
    a = np.frombuffer(pix.samples, np.uint8).reshape(pix.height, pix.width, pix.n)
    cmyk, alfa = neri_k100(np.ascontiguousarray(a[..., :4])), a[..., 4]
    if alfa.max() == 0:
        raise ValueError('pagina vuota')
    spot = alfa if riduzione <= 0 else np.asarray(Image.fromarray(alfa).filter(ImageFilter.MinFilter(2 * riduzione + 1)))
    dati = np.dstack([cmyk, 255 - spot])
    tmp = dest + '.part'
    x = xmp(dati.shape[1], dati.shape[0])
    tifffile.imwrite(tmp, dati, photometric='separated', extrasamples=[0], compression='zlib', predictor=True,
                     resolution=(DPI, DPI), resolutionunit='INCH', iccprofile=icc, metadata=None,
                     software=SOFTWARE, datetime=True,
                     extratags=[(274, 3, 1, 1, True), (700, 1, len(x), x, True),
                                (34377, 7, None, risorse_photoshop(), True)])
    os.replace(tmp, dest)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('pdf')
    ap.add_argument('riduzione', type=int, choices=[0, 1, 2, 3])
    ap.add_argument('--icc', required=True, help='profilo Coated FOGRA39 da incorporare')
    a = ap.parse_args()
    icc = open(a.icc, 'rb').read()
    cartella, nome = os.path.split(a.pdf)
    radice = os.path.splitext(nome)[0].rstrip()
    doc = pymupdf.open(a.pdf)
    if doc.needs_pass:
        raise SystemExit('PDF protetto da password')
    if not doc.page_count:
        raise SystemExit('PDF senza pagine')
    scritti = []
    for i, pagina in enumerate(doc):
        n = f'{radice}.tif' if doc.page_count == 1 else f'{radice} - pag {i + 1}.tif'
        pagina_in_tif(pagina, os.path.join(cartella, n), a.riduzione, icc)
        scritti.append(n)
    print(json.dumps(scritti, ensure_ascii=False))


if __name__ == '__main__':
    sys.exit(main())
