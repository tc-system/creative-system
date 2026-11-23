"""T&C Factory — PDF → TIF per il DTF, come i fogli di Box Factory Lab (shopify-mattino/dtf.py):
  • CMYK Coated FOGRA39 a 300 dpi, misura della pagina del PDF;
  • neri SEMPRE C0 M0 Y0 K100 (richiesta utente 2026-11-23); bordi e sfumature neutre col nero solo in K;
  • canale extra SPOT1 salvato come Photoshop (tinta piatta, inchiostro = 0): la forma di tutto quello
    che è stampato (il fondo trasparente resta senza bianco), ridotta di RIDUZIONE pixel (0, 1, 2 o 3).
    Il RIP del DTF legge il bianco solo dai TIF uguali a quelli salvati da Photoshop: il file si scrive
    a mano con la stessa struttura di un TIF salvato da Photoshop 2026 (tag, strisce, risorse, miniatura,
    IPTC, Exif, XMP; modello in modello_photoshop.json). 2026-11-23: con tifffile il RIP non vedeva lo SPOT.
Una pagina → <nome>.tif; più pagine → <nome> - pag 1.tif, <nome> - pag 2.tif…
I file si scrivono prima come .part e poi si rinominano: nella cartella non resta mai un TIF a metà.

Gira nel suo ambiente (venv con pymupdf, numpy, pillow), chiamato da dtf_cartella.py.
Uso:  dtf_tiff.py PDF RIDUZIONE --icc fogra39.icc
Stampa in JSON i nomi dei TIF scritti.
"""
import argparse
import json
import os
import sys

import numpy as np
import pymupdf
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
MODELLO = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'modello_photoshop.json')


def _blocco(rid, dati):
    return b'8BIM' + rid.to_bytes(2, 'big') + b'\x00\x00' + len(dati).to_bytes(4, 'big') + dati + b'\x00' * (len(dati) % 2)


def miniatura(rgb):
    """Risorsa 040C: anteprima JPEG come la scrive Photoshop (lato lungo 160 px)."""
    import io
    im = Image.fromarray(rgb)
    im.thumbnail((160, 160))
    buf = io.BytesIO()
    im.save(buf, 'JPEG', quality=80)
    jpg = buf.getvalue()
    w, h = im.size
    wb = (w * 24 + 31) // 32 * 4
    return (b''.join(x.to_bytes(4, 'big') for x in (1, w, h, wb, wb * h, len(jpg)))
            + (24).to_bytes(2, 'big') + (1).to_bytes(2, 'big') + jpg)


def risorse_photoshop(modello, larghezza, altezza, nome, rgb):
    """Tutte le risorse di un TIF salvato da Photoshop 2026 (CMYK + tinta piatta SPOT1), nello stesso ordine,
    prese dal modello (modello_photoshop.json, estratto da un TIF salvato da Photoshop il 2026-11-23);
    si rifanno solo le sezioni (misure e nome) e la miniatura."""
    out = []
    for rid, tipo, dati in modello['risorse']:
        rid = int(rid, 16)
        if tipo == 'MINIATURA':
            d = miniatura(rgb)
        elif tipo == 'SLICES':
            resto = bytes.fromhex(dati).replace(b'\xff\xffWW', larghezza.to_bytes(4, 'big')).replace(b'\xff\xffHH', altezza.to_bytes(4, 'big'))
            d = ((6).to_bytes(4, 'big') + b'\x00' * 8 + altezza.to_bytes(4, 'big') + larghezza.to_bytes(4, 'big')
                 + len(nome).to_bytes(4, 'big') + nome.encode('utf-16-be') + resto)
        else:
            d = bytes.fromhex(dati)
        out.append(_blocco(rid, d))
    return b''.join(out)


def xmp(larghezza, altezza, adesso):
    import uuid
    quando = adesso.strftime('%Y-%m-%dT%H:%M:%S') + adesso.strftime('%z')[:3] + ':' + adesso.strftime('%z')[3:]
    iid, did = uuid.uuid4(), uuid.uuid4()
    testo = f"""<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 10.0-c000 79.4332aae, 2026/08/17-13:39:43        ">
   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
            xmlns:stEvt="http://ns.adobe.com/xap/1.0/sType/ResourceEvent#"
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            xmlns:exif="http://ns.adobe.com/exif/1.0/">
         <xmp:CreatorTool>{SOFTWARE}</xmp:CreatorTool>
         <xmp:ModifyDate>{quando}</xmp:ModifyDate>
         <xmp:CreateDate>{quando}</xmp:CreateDate>
         <xmp:MetadataDate>{quando}</xmp:MetadataDate>
         <dc:format>image/tiff</dc:format>
         <photoshop:ColorMode>4</photoshop:ColorMode>
         <photoshop:ICCProfile>Coated FOGRA39 (ISO 12647-2:2004)</photoshop:ICCProfile>
         <xmpMM:InstanceID>xmp.iid:{iid}</xmpMM:InstanceID>
         <xmpMM:DocumentID>xmp.did:{did}</xmpMM:DocumentID>
         <xmpMM:OriginalDocumentID>xmp.did:{did}</xmpMM:OriginalDocumentID>
         <xmpMM:History>
            <rdf:Seq>
               <rdf:li rdf:parseType="Resource">
                  <stEvt:action>saved</stEvt:action>
                  <stEvt:instanceID>xmp.iid:{iid}</stEvt:instanceID>
                  <stEvt:when>{quando}</stEvt:when>
                  <stEvt:softwareAgent>{SOFTWARE}</stEvt:softwareAgent>
                  <stEvt:changed>/</stEvt:changed>
               </rdf:li>
            </rdf:Seq>
         </xmpMM:History>
         <tiff:ImageWidth>{larghezza}</tiff:ImageWidth>
         <tiff:ImageLength>{altezza}</tiff:ImageLength>
         <tiff:BitsPerSample>
            <rdf:Seq>
               <rdf:li>8</rdf:li>
               <rdf:li>8</rdf:li>
               <rdf:li>8</rdf:li>
               <rdf:li>8</rdf:li>
               <rdf:li>8</rdf:li>
            </rdf:Seq>
         </tiff:BitsPerSample>
         <tiff:Compression>8</tiff:Compression>
         <tiff:PhotometricInterpretation>5</tiff:PhotometricInterpretation>
         <tiff:Orientation>1</tiff:Orientation>
         <tiff:SamplesPerPixel>5</tiff:SamplesPerPixel>
         <tiff:PlanarConfiguration>1</tiff:PlanarConfiguration>
         <tiff:XResolution>3000000/10000</tiff:XResolution>
         <tiff:YResolution>3000000/10000</tiff:YResolution>
         <tiff:ResolutionUnit>2</tiff:ResolutionUnit>
         <exif:ColorSpace>65535</exif:ColorSpace>
         <exif:PixelXDimension>{larghezza}</exif:PixelXDimension>
         <exif:PixelYDimension>{altezza}</exif:PixelYDimension>
      </rdf:Description>
   </rdf:RDF>
</x:xmpmeta>
"""
    return (testo + (' ' * 99 + '\n') * 20 + '<?xpacket end="w"?>').encode('utf-8')


def scrivi_tif_photoshop(dest, dati, icc, nome, rgb_anteprima):
    """TIF little-endian scritto come Photoshop 2026: stessi tag nello stesso ordine, strisce da ~1 MB
    compresse ZIP con predictor orizzontale, IPTC, Exif, XMP e risorse Photoshop (canale SPOT1)."""
    import datetime
    import struct
    import zlib
    altezza, larghezza, n = dati.shape
    adesso = datetime.datetime.now().astimezone()
    modello = json.load(open(MODELLO))
    righe = max(1, 1048576 // (larghezza * n))
    strisce = []
    for y in range(0, altezza, righe):
        blocco = dati[y:y + righe].copy()
        blocco[:, 1:] = (dati[y:y + righe, 1:].astype(np.int16) - dati[y:y + righe, :-1]).astype(np.uint8)
        strisce.append(zlib.compress(blocco.tobytes(), 6))
    corto = lambda v: 3 if v < 65536 else 4                          # SHORT o LONG come Photoshop
    SHORT, LONG, RAT, ASCII, BYTE, UNDEF = 3, 4, 5, 2, 1, 7
    tag = [
        (254, LONG, [0]), (256, corto(larghezza), [larghezza]), (257, corto(altezza), [altezza]),
        (258, SHORT, [8] * n), (259, SHORT, [8]), (262, SHORT, [5]), (273, LONG, None), (274, SHORT, [1]),
        (277, SHORT, [n]), (278, corto(righe), [righe]), (279, LONG, [len(x) for x in strisce]),
        (282, RAT, [(DPI * 10000, 10000)]), (283, RAT, [(DPI * 10000, 10000)]), (284, SHORT, [1]), (296, SHORT, [2]),
        (305, ASCII, (SOFTWARE + '\x00').encode()), (306, ASCII, (adesso.strftime('%Y:%m:%d %H:%M:%S') + '\x00').encode()),
        (317, SHORT, [2]), (338, SHORT, [0]), (700, BYTE, xmp(larghezza, altezza, adesso)),
        (33723, UNDEF, bytes.fromhex(modello['iptc'])),
        (34377, BYTE, risorse_photoshop(modello, larghezza, altezza, nome, rgb_anteprima)),
        (34665, LONG, None), (34675, UNDEF, icc),
    ]
    exif = [(40961, SHORT, [65535]), (40962, corto(larghezza), [larghezza]), (40963, corto(altezza), [altezza])]

    def valore(tipo, v):
        if isinstance(v, bytes):
            return v
        f = {SHORT: '<H', LONG: '<I'}
        if tipo == RAT:
            return b''.join(struct.pack('<II', *x) for x in v)
        return b''.join(struct.pack(f[tipo], x) for x in v)

    ifd_len = 2 + 12 * len(tag) + 4
    exif_len = 2 + 12 * len(exif) + 4
    pos = 8 + ifd_len + exif_len
    esterni, voci = [], {}
    offset_exif = 8 + ifd_len

    def metti(tabella):
        nonlocal pos
        for code, tipo, v in tabella:
            if v is None:
                continue
            b = valore(tipo, v)
            if len(b) > 4:
                pos += pos % 2
                voci[code] = (len(b) // {SHORT: 2, LONG: 4, RAT: 8}.get(tipo, 1), pos, b)
                esterni.append((pos, b))
                pos += len(b)
            else:
                voci[code] = (len(b) // {SHORT: 2, LONG: 4, RAT: 8}.get(tipo, 1), None, b.ljust(4, b'\x00'))
    metti(tag)
    metti(exif)
    offsets = []
    for st in strisce:
        pos += pos % 2
        offsets.append(pos)
        esterni.append((pos, st))
        pos += len(st)
    b = valore(LONG, offsets)
    if len(b) > 4:
        voci[273] = (len(offsets), pos, b)
        esterni.append((pos, b))
        pos += len(b)
    else:
        voci[273] = (1, None, b)
    voci[34665] = (1, None, struct.pack('<I', offset_exif))

    def ifd(tabella):
        out = struct.pack('<H', len(tabella))
        for code, tipo, _ in tabella:
            cnt, off, b = voci[code]
            out += struct.pack('<HHI', code, tipo, cnt) + (struct.pack('<I', off) if off is not None else b)
        return out + b'\x00\x00\x00\x00'
    tmp = dest + '.part'
    with open(tmp, 'wb') as f:
        f.write(b'II*\x00' + struct.pack('<I', 8) + ifd(tag) + ifd(exif))
        for o, b in esterni:
            f.seek(o)
            f.write(b)
    os.replace(tmp, dest)


def pagina_in_tif(pagina, dest, riduzione, icc):
    # MuPDF converte in CMYK col suo profilo di default (Coated FOGRA39); i colori sono già
    # composti sul bianco (premoltiplicati), come un TIF unito in Photoshop
    pix = pagina.get_pixmap(dpi=DPI, colorspace=pymupdf.csCMYK, alpha=True)
    a = np.frombuffer(pix.samples, np.uint8).reshape(pix.height, pix.width, pix.n)
    cmyk, alfa = neri_k100(np.ascontiguousarray(a[..., :4])), a[..., 4]
    if alfa.max() == 0:
        raise ValueError('pagina vuota')
    spot = alfa if riduzione <= 0 else np.asarray(Image.fromarray(alfa).filter(ImageFilter.MinFilter(2 * riduzione + 1)))
    dati = np.ascontiguousarray(np.dstack([cmyk, 255 - spot]))
    f = cmyk.astype(np.float32) / 255
    rgb = (np.stack([(1 - f[..., i]) * (1 - f[..., 3]) for i in range(3)], -1) * 255).astype(np.uint8)
    scrivi_tif_photoshop(dest, dati, icc, os.path.splitext(os.path.basename(dest))[0], rgb)


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
