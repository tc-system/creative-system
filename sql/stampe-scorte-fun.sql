-- ════════════════════════════════════════════════════════
-- T&C Factory — Scorte Bienjugado: SOLO le stampe delle T-Shirt FUN (decisione utente 2026-11-24)
--
-- Una riga per grafica, valida per uomo e donna e per cotone e quick dry (stessa stampa).
-- Tutto il resto dell'elenco di Bienjugado è tolto. Una T-Shirt Fun nuova che arriva da un ordine
-- entra da sola come "nuovo" (regola in app_settings 'stampe_scorte_nuove': negozio → regex del titolo);
-- se la grafica c'è già (stesso nome dopo "T-Shirt Fun [Donna] - ") si aggiunge a quella.
-- Richiede stampe-scorte.sql e stampe-scorte-articoli.sql. Si può rieseguire.
-- ════════════════════════════════════════════════════════

insert into app_settings (key, value) values ('stampe_scorte_nuove', '{"bienjugado": "^T-Shirt Fun"}')
on conflict (key) do update set value = excluded.value;

-- Elenco nuovo (le righe tolte non avevano spunte né dati)
delete from stampe_scorte where store_id = 'bienjugado' and regola is null
  and famiglia not in ('Padel Hub', 'Por Aca No Pasa Nada', 'Padel Dad', 'Padel Mom', 'Bandeja', 'Non posso ho padel',
                       'Perchè non sono rimasto a casa?', 'Perchè non sono rimasta a casa?', 'Gioco a destra ma mi adatto!',
                       'Gioco a sinistra ma mi adatto!', 'E'' colpa sua DX', 'E'' colpa sua SX');

insert into stampe_scorte (store_id, famiglia, colore, prodotti, file) values
  ('bienjugado', 'Padel Hub', '', array['T-Shirt Fun - Padel Hub'], null),
  ('bienjugado', 'Por Aca No Pasa Nada', '', array['T-Shirt Fun - Por Aca, No Pasa Nada', 'T-Shirt Fun Donna - Por Aca No Pasa Nada'], null),
  ('bienjugado', 'Padel Dad', '', array['T-Shirt Fun - Padel Dad'], null),
  ('bienjugado', 'Padel Mom', '', array['T-Shirt Fun Donna - Padel Mom'], null),
  ('bienjugado', 'Bandeja', '', array['T-Shirt Fun Donna - Bandeja'], 'Bienjugado/lavorazione/dtf/Bienjugado/fun/bandeja.tif'),
  ('bienjugado', 'Non posso ho padel', '', array['T-Shirt Fun - Non posso ho padel', 'T-Shirt Fun Donna - Non posso ho padel'], null),
  ('bienjugado', 'Perchè non sono rimasto a casa?', '', array['T-Shirt Fun - Perchè non sono rimasto a casa?'], null),
  ('bienjugado', 'Perchè non sono rimasta a casa?', '', array['T-Shirt Fun Donna - Perchè non sono rimasta a casa?'], null),
  ('bienjugado', 'Gioco a destra ma mi adatto!', '', array['T-Shirt Fun - Gioco a destra ma mi adatto!', 'T-Shirt Fun Donna - Gioco a destra ma mi adatto!'], null),
  ('bienjugado', 'Gioco a sinistra ma mi adatto!', '', array['T-Shirt Fun - Gioco a sinistra ma mi adatto!', 'T-Shirt Fun Donna - Gioco a sinistra ma mi adatto!'], null),
  ('bienjugado', 'E'' colpa sua DX', '', array['T-Shirt Fun - E'' colpa sua DX', 'T-Shirt Fun Donna - E'' colpa sua DX'], null),
  ('bienjugado', 'E'' colpa sua SX', '', array['T-Shirt Fun - E'' colpa sua SX', 'T-Shirt Fun Donna - E'' colpa sua SX'], null)
on conflict (store_id, famiglia, colore) do update set prodotti = excluded.prodotti;

-- Ordini Shopify: stampe del negozio, articoli di tutti i negozi; i prodotti nuovi entrano solo se
-- rispettano la regola del negozio (stampe_scorte_nuove)
create or replace function _tc_stampe_ordine() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; v_id uuid; v_art uuid; v_titolo text; v_n int; v_riga text; v_fam text;
  v_stampe boolean := exists (select 1 from stampe_scorte where store_id = new.store_id and regola is null);
  v_nuove text := (select value->>new.store_id from app_settings where key = 'stampe_scorte_nuove');
begin
  if not v_stampe and not exists (select 1 from stampe_scorte where regola is not null and conteggia) then return new; end if;

  if new.annullato_at is not null then
    for r in select m.* from stampe_movimenti m
              where m.ordine = new.shopify_id and m.motivo = 'ordine'
                and not exists (select 1 from stampe_movimenti a where a.stampa_id = m.stampa_id and a.ordine = m.ordine
                                   and a.riga = m.riga and a.motivo = 'annullato') loop
      insert into stampe_movimenti (stampa_id, delta, motivo, ordine, numero, riga, chi)
      values (r.stampa_id, -r.delta, 'annullato', r.ordine, new.numero, r.riga, 'Shopify');
      update stampe_scorte set quantita = quantita - r.delta, aggiornato_da = 'Shopify' where id = r.stampa_id;
    end loop;
    return new;
  end if;

  if new.stato_pagamento not in ('PAID', 'PARTIALLY_REFUNDED') then return new; end if;

  for r in select x.value riga, x.ordinality pos from jsonb_array_elements(new.righe) with ordinality x loop
    v_titolo := trim(r.riga->>'titolo');
    v_n := coalesce((r.riga->>'qnt')::int, 1);
    if v_titolo is null or v_titolo = '' or v_titolo ilike 'Stampa Nome%' or v_titolo ilike 'Stampa Bandiera%' then continue; end if;
    v_riga := r.pos || ':' || v_titolo;
    v_art := _tc_articolo_shopify(v_titolo, r.riga->>'variante');
    v_id := case when v_stampe then _tc_stampa_di(new.store_id, v_titolo, r.riga->>'variante') end;
    if v_stampe and v_id is null and v_nuove is not null and v_titolo ~* v_nuove
       and not exists (select 1 from stampe_scorte where store_id = new.store_id and v_titolo = any(prodotti)) then
      -- Prodotto nuovo: la grafica è il titolo dopo l'ultimo " - "; se c'è già si aggiunge a quella
      v_fam := trim(regexp_replace(v_titolo, '^.* - ', ''));
      update stampe_scorte set prodotti = prodotti || v_titolo
       where store_id = new.store_id and regola is null and lower(famiglia) = lower(v_fam) and colore = ''
      returning id into v_id;
      if v_id is null then
        insert into stampe_scorte (store_id, famiglia, prodotti, nuovo) values (new.store_id, v_fam, array[v_titolo], true)
        on conflict (store_id, famiglia, colore) do nothing;
      end if;
    end if;
    for v_id in select unnest(array[v_id, v_art]) loop
      continue when v_id is null;
      if exists (select 1 from stampe_scorte where id = v_id and conteggia and new.creato_at >= conteggia_dal) then
        insert into stampe_movimenti (stampa_id, delta, motivo, ordine, numero, riga, chi)
        values (v_id, -v_n, 'ordine', new.shopify_id, new.numero, v_riga, 'Shopify')
        on conflict do nothing;
        if found then
          update stampe_scorte set quantita = quantita - v_n, aggiornato_da = 'Shopify' where id = v_id;
        end if;
      end if;
    end loop;
  end loop;
  return new;
end;
$$;
