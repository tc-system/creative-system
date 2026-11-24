-- ════════════════════════════════════════════════════════
-- T&C Factory — Scorte Bienjugado: colore della stampa per colore del capo + bandierine su richiesta (2026-11-24)
--
-- 1. Le grafiche FUN si stampano in più colori (file "-bianco"/"-nero"… in DTF/1. Stampa/2. Bienjugado):
--    una riga per colore della stampa, con i colori dei capi che la usano (capi). Abbinamenti dai mockup.
-- 2. Bandierine (regola 'bandiere'): una riga per bandiera selezionabile sul sito, file TIF CMYK+SPOT in
--    DTF/1. Stampa/2. Bienjugado/bandiere/spot (automazioni/shopify-mattino/bandiere_tif.py). Le scala la
--    bandiera scelta sulla riga dell'ordine (righe[].bandiere, da shopify-sync). Sono "su richiesta": se
--    un ordine la vuole e non c'è (pezzi sotto zero), il Mac mini copia il file in 1. Stampare/01 - Ordini
--    Siti una volta per ogni pezzo mancante e la riporta a zero (stampata per quell'ordine).
-- Richiede stampe-scorte.sql, -articoli, -fun, -felpe-fun. Si può rieseguire.
-- ════════════════════════════════════════════════════════

alter table stampe_scorte add column if not exists capi text[] not null default '{}';
alter table stampe_scorte drop constraint if exists stampe_scorte_regola_check;
alter table stampe_scorte add constraint stampe_scorte_regola_check check (regola in ('calzini', 'polsini', 'bandiere'));

-- ── 1. Grafiche FUN per colore della stampa ──
drop table if exists _fun;
create temp table _fun (famiglia text, colore text, capi text[], file text, pezzi int);
insert into _fun
select g.famiglia, c.colore, c.capi, case when g.file is null then null else 'DTF/1. Stampa/2. Bienjugado/fun/' || g.file || '-' || lower(c.colore) || '.tif' end, 1
  from (values ('Non posso ho padel', 'nonpossohopadel'), ('Perchè non sono rimasto a casa?', 'rimastoacasa'),
               ('Perchè non sono rimasta a casa?', 'rimastaacasa'), ('Gioco a destra ma mi adatto!', 'giocoadestra'),
               ('Gioco a sinistra ma mi adatto!', 'giocoasinistra'), ('E'' colpa sua DX', 'ècolpasua-dx'),
               ('E'' colpa sua SX', 'ècolpasua-sx')) g(famiglia, file),
       (values ('NERO', array['BIANCO', 'GIALLO FLUO']), ('BIANCO', array['NERO', 'NAVY', 'ROYAL', 'FUCSIA'])) c(colore, capi)
union all values
  ('Padel Hub', 'NERO', array['BIANCO', 'GRIGIO MELANGE', 'GRIGIO'], 'DTF/1. Stampa/2. Bienjugado/fun/padelhub-nero.tif', 2),
  ('Padel Hub', 'BIANCO', array['NERO', 'NAVY'], 'DTF/1. Stampa/2. Bienjugado/fun/padelhub-bianco.tif', 2),
  ('Padel Dad', 'NERO', array['BIANCO', 'GRIGIO MELANGE', 'GRIGIO'], 'DTF/1. Stampa/2. Bienjugado/fun/padel-dad-black.tif', 1),
  ('Padel Dad', 'BIANCO', array['NERO', 'NAVY'], 'DTF/1. Stampa/2. Bienjugado/fun/padel-dad-white.tif', 1),
  ('Padel Mom', 'NERO', array['BIANCO', 'GRIGIO MELANGE', 'GRIGIO'], 'DTF/1. Stampa/2. Bienjugado/fun/padel-mom-black.tif', 1),
  ('Padel Mom', 'BIANCO', array['NERO', 'NAVY'], 'DTF/1. Stampa/2. Bienjugado/fun/padel-mom-white.tif', 1),
  ('Por Aca No Pasa Nada', 'NERO', array['GRIGIO MELANGE', 'GRIGIO'], 'DTF/1. Stampa/2. Bienjugado/fun/nopasanada-nero.tif', 1),
  ('Por Aca No Pasa Nada', 'BIANCO', array['NAVY'], 'DTF/1. Stampa/2. Bienjugado/fun/nopasanada-bianco.tif', 1),
  ('Por Aca No Pasa Nada', 'GIALLO', array['BIANCO', 'NERO'], 'DTF/1. Stampa/2. Bienjugado/fun/nopasanada-giallo.tif', 1),
  ('Bienjugado Circle', 'BIANCO', array['NAVY', 'NERO', 'NERO/LAMPONE', 'NERO/FLUO GIALLO'], 'DTF/1. Stampa/2. Bienjugado/circle-bianco.tif', 1),
  ('Bienjugado Circle', 'NERO', array['GRIGIO MELANGE'], null, 1),
  ('Siempre Por El Centro', 'NERO', array['GRIGIO MELANGE'], null, 1),
  ('Siempre Por El Centro', 'GIALLO', array['NERO/FLUO GIALLO', 'NERO'], null, 1),
  ('Siempre Por El Centro', 'BIANCO', array['NAVY', 'NERO/LAMPONE'], null, 1);

-- prodotti e spunta presi dalla riga di prima (un colore solo); poi la riga vecchia si toglie
insert into stampe_scorte (store_id, famiglia, colore, capi, file, pezzi_file, prodotti, conteggia)
select 'bienjugado', f.famiglia, f.colore, f.capi, f.file, f.pezzi, v.prodotti, v.conteggia
  from _fun f join stampe_scorte v on v.store_id = 'bienjugado' and v.famiglia = f.famiglia and v.colore = '' and v.regola is null
on conflict (store_id, famiglia, colore) do update set capi = excluded.capi, file = coalesce(stampe_scorte.file, excluded.file),
  pezzi_file = coalesce(stampe_scorte.pezzi_file, excluded.pezzi_file), prodotti = excluded.prodotti;
delete from stampe_scorte v where v.store_id = 'bienjugado' and v.colore = '' and v.regola is null
   and exists (select 1 from _fun f where f.famiglia = v.famiglia)
   and not exists (select 1 from stampe_movimenti m where m.stampa_id = v.id);
drop table _fun;
update stampe_scorte set file = 'DTF/1. Stampa/2. Bienjugado/fun/bandeja.tif', pezzi_file = coalesce(pezzi_file, 6)
 where store_id = 'bienjugado' and famiglia = 'Bandeja' and colore = '';

-- ── 2. Bandierine ──
insert into stampe_scorte (store_id, famiglia, colore, regola, file, pezzi_file, conteggia)
select 'bienjugado', 'Bandierine', upper(n), 'bandiere', 'DTF/1. Stampa/2. Bienjugado/bandiere/spot/bandiera-' || lower(n) || '.tif', 1, true
  from unnest(array['Italia', 'Spagna', 'Argentina', 'Francia', 'Germania', 'Belgio', 'Svizzera', 'Norvegia', 'Danimarca',
                    'Svezia', 'Finlandia', 'USA', 'UK']) n
on conflict (store_id, famiglia, colore) do update set regola = 'bandiere', file = coalesce(stampe_scorte.file, excluded.file);

-- Stampa di una riga d'ordine (non articoli né bandiere): titolo tra i prodotti e
--   • con i colori dei capi (capi): il colore del capo tra le parti della variante ("Cappuccio / Nero/Lampone / M");
--   • senza: il colore della stampa tra le parti della variante, o nessun colore.
create or replace function _tc_stampa_di(p_store text, p_titolo text, p_variante text) returns uuid
language sql stable set search_path = public as $$
  with parti as (select upper(trim(x)) p from unnest(string_to_array(coalesce(p_variante, ''), ' / ')) x)
  select s.id from stampe_scorte s
   where s.store_id = p_store and s.regola is null and p_titolo = any(s.prodotti)
     and case when cardinality(s.capi) > 0 then exists (select 1 from parti where p = any(s.capi))
              else s.colore = '' or upper(s.colore) in (select p from parti) end
   order by (cardinality(s.capi) > 0 or s.colore <> '') desc
   limit 1;
$$;

-- Ordini Shopify: stampe del negozio, bandierine scelte sulle righe, articoli di tutti i negozi
create or replace function _tc_stampe_ordine() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; b record; v_id uuid; v_art uuid; v_titolo text; v_n int; v_riga text; v_fam text;
  v_stampe boolean := exists (select 1 from stampe_scorte where store_id = new.store_id and regola is distinct from 'calzini' and regola is distinct from 'polsini');
  v_nuove text := (select value->>new.store_id from app_settings where key = 'stampe_scorte_nuove');
begin
  if not v_stampe and not exists (select 1 from stampe_scorte where regola in ('calzini', 'polsini') and conteggia) then return new; end if;

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
    if v_titolo is null or v_titolo = '' then continue; end if;
    v_riga := r.pos || ':' || v_titolo;

    -- Bandierine scelte sulla riga (ogni nome = una bandiera per pezzo); una mai vista entra come "nuovo"
    if v_stampe and jsonb_typeof(r.riga->'bandiere') = 'array' then
      for b in select upper(trim(x)) nome, count(*)::int n from jsonb_array_elements_text(r.riga->'bandiere') x
                where trim(x) <> '' group by 1 loop
        select id into v_id from stampe_scorte where store_id = new.store_id and regola = 'bandiere' and colore = b.nome;
        if v_id is null then
          insert into stampe_scorte (store_id, famiglia, colore, regola, nuovo) values (new.store_id, 'Bandierine', b.nome, 'bandiere', true)
          on conflict (store_id, famiglia, colore) do nothing;
          continue;
        end if;
        if exists (select 1 from stampe_scorte where id = v_id and conteggia and new.creato_at >= conteggia_dal) then
          insert into stampe_movimenti (stampa_id, delta, motivo, ordine, numero, riga, chi)
          values (v_id, -(b.n * v_n), 'ordine', new.shopify_id, new.numero, v_riga || ':bandiera', 'Shopify')
          on conflict do nothing;
          if found then
            update stampe_scorte set quantita = quantita - b.n * v_n, aggiornato_da = 'Shopify' where id = v_id;
          end if;
        end if;
      end loop;
    end if;

    if v_titolo ilike 'Stampa Nome%' or v_titolo ilike 'Stampa Bandiera%' then continue; end if;
    v_art := _tc_articolo_shopify(v_titolo, r.riga->>'variante');
    v_id := case when v_stampe then _tc_stampa_di(new.store_id, v_titolo, r.riga->>'variante') end;
    if v_stampe and v_id is null and v_nuove is not null and v_titolo ~* v_nuove
       and not exists (select 1 from stampe_scorte where store_id = new.store_id and v_titolo = any(prodotti)) then
      -- Prodotto nuovo: la grafica è il titolo dopo l'ultimo " - "; se c'è già (un colore solo) si aggiunge a quella
      v_fam := trim(regexp_replace(v_titolo, '^.* - ', ''));
      update stampe_scorte set prodotti = prodotti || v_titolo
       where store_id = new.store_id and regola is null and lower(famiglia) = lower(v_fam);
      if not found then
        insert into stampe_scorte (store_id, famiglia, prodotti, nuovo) values (new.store_id, v_fam, array[v_titolo], true)
        on conflict (store_id, famiglia, colore) do nothing;
      end if;
      v_id := _tc_stampa_di(new.store_id, v_titolo, r.riga->>'variante');
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

-- Gestionale/Kamon: solo gli articoli (calzini, polsini)
create or replace function _tc_stampe_gestionale() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; v_ord text := 'gest:' || new.id; v_chi text := case when new.order_module->>'origine' = 'kamon' then 'Kamon' else 'Gestionale' end;
begin
  if not exists (select 1 from stampe_scorte where regola in ('calzini', 'polsini') and conteggia) then return new; end if;
  for r in
    with voluti as (
      select _tc_articolo_gestionale(x) id, sum(greatest(0, coalesce(nullif(x->>'qnt', '')::numeric, 0)))::int n
        from jsonb_array_elements(case when new.deleted_at is null and jsonb_typeof(new.order_module->'rows') = 'array'
                                       then new.order_module->'rows' else '[]'::jsonb end) x
       group by 1),
    fatti as (select stampa_id id, -sum(delta)::int n from stampe_movimenti where ordine = v_ord group by 1)
    select s.id, coalesce(v.n, 0) - coalesce(f.n, 0) diff
      from stampe_scorte s
      left join voluti v on v.id = s.id
      left join fatti f on f.id = s.id
     where s.regola in ('calzini', 'polsini') and s.conteggia and new.created_at >= s.conteggia_dal
       and coalesce(v.n, 0) <> coalesce(f.n, 0)
  loop
    insert into stampe_movimenti (stampa_id, delta, motivo, ordine, numero, riga, chi)
    values (r.id, -r.diff, case when r.diff > 0 then 'ordine' else 'annullato' end, v_ord, new.nome,
            'v' || (select count(*) + 1 from stampe_movimenti where stampa_id = r.id and ordine = v_ord), v_chi);
    update stampe_scorte set quantita = quantita - r.diff, aggiornato_da = v_chi where id = r.id;
  end loop;
  return new;
end;
$$;

-- Elenco: venduti anche delle bandierine (dalle righe sincronizzate con le bandiere)
create or replace function tc_stampe_lista(p_store text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_art boolean := exists (select 1 from stampe_scorte where store_id = p_store and regola in ('calzini', 'polsini'));
begin
  if not app_vede_scheda('tasks') then return jsonb_build_object('success', false, 'error', 'Non autorizzato'); end if;
  return jsonb_build_object('success', true,
    'dal', (select min(creato_at) from shopify_orders where store_id = p_store),
    'stampe', coalesce((
      with pagati as (
        select o.store_id, x from shopify_orders o, jsonb_array_elements(o.righe) x
         where o.annullato_at is null and o.stato_pagamento in ('PAID', 'PARTIALLY_REFUNDED')),
      venduti as (
        select _tc_stampa_di(store_id, trim(x->>'titolo'), x->>'variante') id, sum(coalesce((x->>'qnt')::int, 1)) n
          from pagati where store_id = p_store group by 1
        union all
        select s.id, sum(coalesce((p.x->>'qnt')::int, 1))
          from pagati p, jsonb_array_elements_text(case when jsonb_typeof(p.x->'bandiere') = 'array' then p.x->'bandiere' else '[]' end) b
          join stampe_scorte s on s.store_id = p_store and s.regola = 'bandiere' and s.colore = upper(trim(b))
         where p.store_id = p_store group by 1
        union all
        select _tc_articolo_shopify(trim(x->>'titolo'), x->>'variante'), sum(coalesce((x->>'qnt')::int, 1))
          from pagati where v_art group by 1
        union all
        select _tc_articolo_gestionale(x), sum(greatest(0, coalesce(nullif(x->>'qnt', '')::numeric, 0)))::int
          from orders o, jsonb_array_elements(case when jsonb_typeof(o.order_module->'rows') = 'array' then o.order_module->'rows' else '[]' end) x
         where o.deleted_at is null and v_art group by 1)
      select jsonb_agg(to_jsonb(s) || jsonb_build_object('venduti', coalesce(v.n, 0))
                       order by s.regola = 'bandiere', s.famiglia, array_position(array['XS', 'S', 'M', 'L', 'XL'], s.colore), s.colore)
        from stampe_scorte s left join (select id, sum(n) n from venduti where id is not null group by 1) v on v.id = s.id
       where s.store_id = p_store), '[]'::jsonb));
end;
$$;

-- ── Mac mini ──
-- copie: bandierine mancanti (pezzi sotto zero) da mettere in stampa, una copia del file per pezzo
create or replace function tc_stampe_ristampa_dati(p_chiave text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _tc_chiave_automazione_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  return jsonb_build_object('success', true, 'stampe', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'file', file, 'nome', famiglia || case when colore <> '' then ' ' || colore else '' end,
                                        'da_caricare', regola is distinct from 'bandiere' and soglia is not null and quantita <= soglia and ristampa_at is null,
                                        'copie', case when regola = 'bandiere' then greatest(0, -quantita) else 0 end))
      from stampe_scorte where conteggia and file is not null), '[]'::jsonb));
end;
$$;

-- p_caricati: file copiati alla soglia; p_controllati: {id: trovato}; p_coperti: {id: n} bandierine messe in stampa
drop function if exists tc_stampe_ristampa_salva(text, uuid[], jsonb);
create or replace function tc_stampe_ristampa_salva(p_chiave text, p_caricati uuid[], p_controllati jsonb, p_coperti jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare k text;
begin
  if not _tc_chiave_automazione_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  update stampe_scorte s set file_ok = (p_controllati->>s.id::text)::boolean
   where p_controllati ? s.id::text and s.file_ok is distinct from (p_controllati->>s.id::text)::boolean;
  update stampe_scorte set ristampa_at = now(), aggiornato_da = 'Mac mini' where id = any(coalesce(p_caricati, '{}'));
  for k in select jsonb_object_keys(coalesce(p_coperti, '{}')) loop
    insert into stampe_movimenti (stampa_id, delta, motivo, chi) values (k::uuid, (p_coperti->>k)::int, 'ristampa', 'Mac mini (in stampa)');
    update stampe_scorte set quantita = quantita + (p_coperti->>k)::int, aggiornato_da = 'Mac mini' where id = k::uuid;
  end loop;
  return jsonb_build_object('success', true);
end;
$$;
revoke execute on function tc_stampe_ristampa_salva(text, uuid[], jsonb, jsonb) from public;
grant execute on function tc_stampe_ristampa_salva(text, uuid[], jsonb, jsonb) to anon, authenticated;
