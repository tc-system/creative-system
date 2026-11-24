-- T&C Factory — Scorte Bienjugado: le stampe fluo (giallo/rosa) si gestiscono a parte, non si contano (utente 2026-11-24).
-- Restano solo le stampe bianche e nere; i capi con la stampa fluo (felpe Nero/Lampone e Nero/Fluo Giallo) escono dal conteggio.
-- File nuovi da vettoriale (automazioni/shopify-mattino/ai_tif.py): fun/siempre-bianco.tif, fun/siempre-nero.tif, circle-nero.tif.
delete from stampe_scorte where store_id = 'bienjugado' and regola is null and colore = 'GIALLO'
  and famiglia in ('Por Aca No Pasa Nada', 'Siempre Por El Centro');
update stampe_scorte set capi = array['NAVY', 'NERO'] where store_id = 'bienjugado' and famiglia = 'Bienjugado Circle' and colore = 'BIANCO';
update stampe_scorte set file = coalesce(file, 'DTF/1. Stampa/2. Bienjugado/circle-nero.tif')
 where store_id = 'bienjugado' and famiglia = 'Bienjugado Circle' and colore = 'NERO';
update stampe_scorte set capi = array['NAVY'], file = coalesce(file, 'DTF/1. Stampa/2. Bienjugado/fun/siempre-bianco.tif')
 where store_id = 'bienjugado' and famiglia = 'Siempre Por El Centro' and colore = 'BIANCO';
update stampe_scorte set file = coalesce(file, 'DTF/1. Stampa/2. Bienjugado/fun/siempre-nero.tif')
 where store_id = 'bienjugado' and famiglia = 'Siempre Por El Centro' and colore = 'NERO';
