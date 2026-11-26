-- ════════════════════════════════════════════════════════
-- T&C Factory — Scorte delle stampe dei negozi (prima Bienjugado), 2026-11-24
--
-- Una stampa = famiglia di prodotti (es. "Short Uomo") + colore della stampa (opzione
-- "Colore Stampa"/"Stampa" della variante; '' se il prodotto non ce l'ha).
-- Si contano solo quelle con la spunta (conteggia): ogni ordine pagato creato DOPO la spunta
-- scala i pezzi (trigger su shopify_orders, una volta sola per riga); un ordine annullato li ridà.
-- Quando i pezzi scendono alla soglia, il Mac mini (automazioni/dtf-cartella) copia il file
-- della stampa dal NAS in "1. Stampare/1 - Ordini sito" e segna ristampa_at; si azzera da
-- solo quando i pezzi tornano sopra la soglia (correzione o ristampa arrivata).
-- Gestione: Task → coda SCORTE → <negozio> (js/scorte-stampe.js).
-- Si può rieseguire.
-- ════════════════════════════════════════════════════════

create table if not exists stampe_scorte (
  id             uuid primary key default gen_random_uuid(),
  store_id       text not null references shopify_stores(id) on delete cascade,
  famiglia       text not null,
  colore         text not null default '',
  prodotti       text[] not null default '{}',   -- titoli Shopify dei prodotti che usano questa stampa
  conteggia      boolean not null default false,
  conteggia_dal  timestamptz,                    -- ordini creati da qui in poi scalano i pezzi
  quantita       int not null default 0,
  soglia         int,                            -- null = nessun caricamento automatico
  pezzi_file     int,                            -- pezzi che escono stampando il file una volta
  file           text,                           -- percorso dentro DATI sul NAS (es. Bienjugado/lavorazione/dtf/…/bj-bianco.tif)
  file_ok        boolean,                        -- il Mac mini lo trova sul NAS? null = non ancora controllato
  ristampa_at    timestamptz,                    -- file caricato in 1. Stampare, in attesa della ristampa
  nuovo          boolean not null default false, -- comparso da un ordine, non era nell'elenco
  aggiornato_at  timestamptz not null default now(),
  aggiornato_da  text,
  unique (store_id, famiglia, colore)
);
create index if not exists stampe_scorte_prodotti_idx on stampe_scorte using gin (prodotti);

create table if not exists stampe_movimenti (
  id        bigint generated always as identity primary key,
  stampa_id uuid not null references stampe_scorte(id) on delete cascade,
  delta     int not null,
  motivo    text not null check (motivo in ('ordine', 'annullato', 'correzione', 'ristampa')),
  ordine    text,          -- shopify_orders.shopify_id
  numero    text,          -- #1043, per leggerlo
  riga      text,          -- posizione:titolo della riga dell'ordine
  chi       text,
  at        timestamptz not null default now()
);
create unique index if not exists stampe_movimenti_riga_uq on stampe_movimenti (stampa_id, ordine, riga, motivo) where ordine is not null;
create index if not exists stampe_movimenti_stampa_idx on stampe_movimenti (stampa_id, at desc);

alter table stampe_scorte enable row level security;
alter table stampe_movimenti enable row level security;
drop policy if exists "Task legge scorte" on stampe_scorte;
create policy "Task legge scorte" on stampe_scorte for select to authenticated using (app_vede_scheda('tasks'));
drop policy if exists "Task legge movimenti" on stampe_movimenti;
create policy "Task legge movimenti" on stampe_movimenti for select to authenticated using (app_vede_scheda('tasks'));
revoke all on stampe_scorte, stampe_movimenti from anon, authenticated;
grant select on stampe_scorte, stampe_movimenti to authenticated;

-- Pezzi sopra la soglia: il file si potrà ricaricare alla prossima discesa
create or replace function _tc_stampe_prima() returns trigger language plpgsql as $$
begin
  if new.soglia is null or new.quantita > new.soglia then new.ristampa_at := null; end if;
  if new.conteggia and new.conteggia_dal is null then new.conteggia_dal := now(); end if;
  if not new.conteggia then new.conteggia_dal := null; end if;
  if new.file is distinct from old.file then new.file_ok := null; end if;
  new.aggiornato_at := now();
  return new;
end;
$$;
drop trigger if exists stampe_scorte_prima on stampe_scorte;
create trigger stampe_scorte_prima before update on stampe_scorte for each row execute function _tc_stampe_prima();

-- La stampa di una riga d'ordine: titolo tra i prodotti e, se la stampa ha un colore,
-- quel colore tra le parti della variante ("L / FLUO LAMPONE")
create or replace function _tc_stampa_di(p_store text, p_titolo text, p_variante text) returns uuid
language sql stable set search_path = public as $$
  select s.id from stampe_scorte s
   where s.store_id = p_store and p_titolo = any(s.prodotti)
     and (s.colore = '' or upper(s.colore) in (select upper(trim(x)) from unnest(string_to_array(coalesce(p_variante, ''), '/')) x))
   order by (s.colore <> '') desc
   limit 1;
$$;

-- Ordini pagati scalano le stampe con la spunta; annullati le ridanno
create or replace function _tc_stampe_ordine() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; v_id uuid; v_titolo text; v_n int; v_riga text;
begin
  if not exists (select 1 from stampe_scorte where store_id = new.store_id) then return new; end if;

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
    v_id := _tc_stampa_di(new.store_id, v_titolo, r.riga->>'variante');
    if v_id is null then
      -- Prodotto che non era nell'elenco: compare da spuntare (non si conta)
      if not exists (select 1 from stampe_scorte where store_id = new.store_id and v_titolo = any(prodotti)) then
        insert into stampe_scorte (store_id, famiglia, prodotti, nuovo) values (new.store_id, v_titolo, array[v_titolo], true)
        on conflict (store_id, famiglia, colore) do nothing;
      end if;
      continue;
    end if;
    v_riga := r.pos || ':' || v_titolo;
    if exists (select 1 from stampe_scorte where id = v_id and conteggia and new.creato_at >= conteggia_dal) then
      insert into stampe_movimenti (stampa_id, delta, motivo, ordine, numero, riga, chi)
      values (v_id, -v_n, 'ordine', new.shopify_id, new.numero, v_riga, 'Shopify')
      on conflict do nothing;
      if found then
        update stampe_scorte set quantita = quantita - v_n, aggiornato_da = 'Shopify' where id = v_id;
      end if;
    end if;
  end loop;
  return new;
end;
$$;
drop trigger if exists shopify_orders_stampe on shopify_orders;
create trigger shopify_orders_stampe after insert or update of righe, stato_pagamento, annullato_at on shopify_orders
  for each row execute function _tc_stampe_ordine();

-- ── Gestionale ──

-- Elenco con i pezzi venduti dal primo ordine importato (aiuta a scegliere cosa contare)
create or replace function tc_stampe_lista(p_store text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not app_vede_scheda('tasks') then return jsonb_build_object('success', false, 'error', 'Non autorizzato'); end if;
  return jsonb_build_object('success', true,
    'dal', (select min(creato_at) from shopify_orders where store_id = p_store),
    'stampe', coalesce((
      with venduti as (
        select _tc_stampa_di(o.store_id, trim(x->>'titolo'), x->>'variante') id, sum(coalesce((x->>'qnt')::int, 1)) n
          from shopify_orders o, jsonb_array_elements(o.righe) x
         where o.store_id = p_store and o.annullato_at is null and o.stato_pagamento in ('PAID', 'PARTIALLY_REFUNDED')
         group by 1)
      select jsonb_agg(to_jsonb(s) || jsonb_build_object('venduti', coalesce(v.n, 0)) order by s.famiglia, s.colore)
        from stampe_scorte s left join venduti v on v.id = s.id
       where s.store_id = p_store), '[]'::jsonb));
end;
$$;

-- Spunta di una famiglia intera (tutti i colori)
create or replace function tc_stampe_conteggia(p_store text, p_famiglia text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not app_vede_scheda('tasks') then return jsonb_build_object('success', false, 'error', 'Non autorizzato'); end if;
  update stampe_scorte set conteggia = p_on, nuovo = false, aggiornato_da = app_nickname()
   where store_id = p_store and famiglia = p_famiglia;
  return jsonb_build_object('success', true);
end;
$$;

-- Campi di una stampa: quantita (registrata come correzione), aggiungi (ristampa arrivata: +pezzi),
-- soglia, pezzi_file, file. Un campo assente resta com'è; null svuota soglia/pezzi_file/file.
create or replace function tc_stampe_salva(p_id uuid, p_campi jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s stampe_scorte; v_q int; v_chi text := app_nickname();
begin
  if not app_vede_scheda('tasks') then return jsonb_build_object('success', false, 'error', 'Non autorizzato'); end if;
  select * into s from stampe_scorte where id = p_id for update;
  if not found then return jsonb_build_object('success', false, 'error', 'Stampa non trovata'); end if;
  v_q := s.quantita;
  if p_campi ? 'quantita' and (p_campi->>'quantita')::int <> s.quantita then
    insert into stampe_movimenti (stampa_id, delta, motivo, chi) values (p_id, (p_campi->>'quantita')::int - s.quantita, 'correzione', v_chi);
    v_q := (p_campi->>'quantita')::int;
  end if;
  if coalesce((p_campi->>'aggiungi')::int, 0) <> 0 then
    insert into stampe_movimenti (stampa_id, delta, motivo, chi) values (p_id, (p_campi->>'aggiungi')::int, 'ristampa', v_chi);
    v_q := v_q + (p_campi->>'aggiungi')::int;
  end if;
  update stampe_scorte set
    quantita   = v_q,
    soglia     = case when p_campi ? 'soglia' then nullif(p_campi->>'soglia', '')::int else soglia end,
    pezzi_file = case when p_campi ? 'pezzi_file' then nullif(p_campi->>'pezzi_file', '')::int else pezzi_file end,
    file       = case when p_campi ? 'file' then nullif(trim(p_campi->>'file'), '') else file end,
    nuovo = false, aggiornato_da = v_chi
  where id = p_id returning * into s;
  return jsonb_build_object('success', true, 'stampa', to_jsonb(s));
end;
$$;

-- ── Mac mini (chiave delle automazioni) ──

-- Stampe contate con un file: da controllare sul NAS; da_caricare = scese alla soglia e non ancora caricate
create or replace function tc_stampe_ristampa_dati(p_chiave text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _tc_chiave_automazione_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  return jsonb_build_object('success', true, 'stampe', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'file', file, 'nome', famiglia || case when colore <> '' then ' ' || colore else '' end,
                                        'da_caricare', soglia is not null and quantita <= soglia and ristampa_at is null))
      from stampe_scorte where conteggia and file is not null), '[]'::jsonb));
end;
$$;

-- p_caricati: file copiati in 1. Stampare; p_controllati: {id: true/false} trovato sul NAS
create or replace function tc_stampe_ristampa_salva(p_chiave text, p_caricati uuid[], p_controllati jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _tc_chiave_automazione_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  update stampe_scorte s set file_ok = (p_controllati->>s.id::text)::boolean
   where p_controllati ? s.id::text and s.file_ok is distinct from (p_controllati->>s.id::text)::boolean;
  update stampe_scorte set ristampa_at = now(), aggiornato_da = 'Mac mini' where id = any(coalesce(p_caricati, '{}'));
  return jsonb_build_object('success', true);
end;
$$;

revoke execute on function _tc_stampa_di(text, text, text), _tc_stampe_ordine(), _tc_stampe_prima() from public, anon, authenticated;
revoke execute on function tc_stampe_lista(text), tc_stampe_conteggia(text, text, boolean), tc_stampe_salva(uuid, jsonb) from public, anon;
grant execute on function tc_stampe_lista(text), tc_stampe_conteggia(text, text, boolean), tc_stampe_salva(uuid, jsonb) to authenticated;
revoke execute on function tc_stampe_ristampa_dati(text), tc_stampe_ristampa_salva(text, uuid[], jsonb) from public;
grant execute on function tc_stampe_ristampa_dati(text), tc_stampe_ristampa_salva(text, uuid[], jsonb) to anon, authenticated;
