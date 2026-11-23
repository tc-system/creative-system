-- ════════════════════════════════════════════════════════
-- T&C Factory — Bozze degli ordini dal NAS (pagina dell'ordine aperta col QR del modulo)
--
-- Il Mac mini (automazioni/dtf-cartella/bozze_nas.py, ogni 5 minuti) cerca per ogni ordine aperto
-- la cartella "bozze" dell'anno corrente nella cartella del cliente sul NAS
-- (DATI/Clienti/<iniziale>/<cliente>/<anno>/bozze o DATI/CrossFit/<box>/<anno>/bozze; se c'è la
-- sottocartella della lavorazione = descrizione dell'ordine, prima <anno>/<lavorazione>/bozze),
-- carica immagini e PDF nel bucket privato "bozze" (link di caricamento dalla funzione file-mattino)
-- e le elenca qui. Quando l'ordine è evaso o eliminato le toglie.
-- Leggere: chiunque sia registrato (staff). Scrivere: solo lo script, con la chiave delle automazioni.
-- Si può rieseguire.
-- ════════════════════════════════════════════════════════

create table if not exists public.ordini_bozze (
  order_id   text not null,
  nome       text not null,              -- percorso del file dentro la cartella bozze (es. "felpa fronte.jpg")
  percorso   text not null,              -- nel bucket bozze: <order_id>/<codice>-<nome pulito>
  peso       bigint not null default 0,
  mtime      double precision not null default 0,
  tipo       text not null default '',
  aggiornato timestamptz not null default now(),
  primary key (order_id, nome)
);

-- Una riga per ordine controllato: dove ha cercato (null = cartella bozze non trovata)
create table if not exists public.ordini_bozze_stato (
  order_id   text primary key,
  cartella   text,
  at         timestamptz not null default now()
);

alter table public.ordini_bozze enable row level security;
alter table public.ordini_bozze_stato enable row level security;
drop policy if exists ordini_bozze_legge on public.ordini_bozze;
create policy ordini_bozze_legge on public.ordini_bozze for select to authenticated using (app_is_staff());
drop policy if exists ordini_bozze_stato_legge on public.ordini_bozze_stato;
create policy ordini_bozze_stato_legge on public.ordini_bozze_stato for select to authenticated using (app_is_staff());
revoke all on public.ordini_bozze, public.ordini_bozze_stato from anon, authenticated;
grant select on public.ordini_bozze, public.ordini_bozze_stato to authenticated;

-- File: bucket privato, lo legge lo staff con link firmati; scrivono solo la funzione file-mattino
insert into storage.buckets (id, name, public, file_size_limit)
values ('bozze', 'bozze', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = 52428800;
drop policy if exists "Bozze si leggono" on storage.objects;
create policy "Bozze si leggono" on storage.objects for select to authenticated
  using (bucket_id = 'bozze' and app_is_staff());

-- Per lo script: ordini aperti (non evasi, non archiviati, non eliminati) con nome, descrizione e cliente,
-- le bozze che hanno già, e gli ordini chiusi che hanno ancora bozze da togliere
create or replace function tc_bozze_ordini(p_chiave text)
returns jsonb security definer set search_path = public language plpgsql as $$
begin
  if not _tc_chiave_automazione_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  return jsonb_build_object('success', true,
    'ordini', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id, 'nome', o.nome, 'descr', coalesce(o.order_module->>'descrizione', ''),
        'cliente', nullif(trim(concat_ws(' ', nullif(c.ragione_sociale, ''),
                     case when coalesce(c.ragione_sociale, '') = '' then concat_ws(' ', c.nome, c.cognome) end)), ''),
        'bozze', coalesce((select jsonb_agg(jsonb_build_object('nome', b.nome, 'percorso', b.percorso, 'peso', b.peso, 'mtime', b.mtime))
                             from ordini_bozze b where b.order_id = o.id), '[]'::jsonb)))
        from orders o left join clients c on c.id = o.client_id
       where o.deleted_at is null and not coalesce(o.archived, false)
         and not coalesce((o.stages->'spedito'->>'done')::boolean, false)), '[]'::jsonb),
    'chiusi', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.order_id, 'percorsi', x.percorsi))
        from (select b.order_id, jsonb_agg(b.percorso) percorsi from ordini_bozze b
               where not exists (select 1 from orders o where o.id = b.order_id and o.deleted_at is null
                                   and not coalesce(o.archived, false)
                                   and not coalesce((o.stages->'spedito'->>'done')::boolean, false))
               group by b.order_id) x), '[]'::jsonb));
end;
$$;

-- Per lo script: elenco completo delle bozze di un ordine (sostituisce quello di prima) e cartella usata
create or replace function tc_bozze_salva(p_chiave text, p_order_id text, p_cartella text, p_files jsonb)
returns jsonb security definer set search_path = public language plpgsql as $$
begin
  if not _tc_chiave_automazione_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  delete from ordini_bozze b where b.order_id = p_order_id
     and b.nome not in (select f->>'nome' from jsonb_array_elements(coalesce(p_files, '[]'::jsonb)) f);
  insert into ordini_bozze (order_id, nome, percorso, peso, mtime, tipo, aggiornato)
  select p_order_id, f->>'nome', f->>'percorso', coalesce((f->>'peso')::bigint, 0), coalesce((f->>'mtime')::double precision, 0),
         coalesce(f->>'tipo', ''), now()
    from jsonb_array_elements(coalesce(p_files, '[]'::jsonb)) f
  on conflict (order_id, nome) do update set percorso = excluded.percorso, peso = excluded.peso, mtime = excluded.mtime,
         tipo = excluded.tipo, aggiornato = case when ordini_bozze.mtime = excluded.mtime and ordini_bozze.peso = excluded.peso
                                                 then ordini_bozze.aggiornato else now() end;
  if p_cartella = '-' then
    delete from ordini_bozze_stato where order_id = p_order_id;   -- ordine chiuso: si toglie tutto
  else
    insert into ordini_bozze_stato (order_id, cartella, at) values (p_order_id, nullif(p_cartella, ''), now())
    on conflict (order_id) do update set cartella = excluded.cartella, at = now();
  end if;
  return jsonb_build_object('success', true);
end;
$$;

revoke execute on function tc_bozze_ordini(text) from public, authenticated;
revoke execute on function tc_bozze_salva(text, text, text, jsonb) from public, authenticated;
grant execute on function tc_bozze_ordini(text) to anon;
grant execute on function tc_bozze_salva(text, text, text, jsonb) to anon;
