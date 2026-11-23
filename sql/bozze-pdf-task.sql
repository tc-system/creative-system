-- ════════════════════════════════════════════════════════
-- T&C Factory — Bozze come PDF + task "Fare la bozza" (coda BOZZE del Centro di controllo)
--
-- Regola (decisa da Riccardo il 2026-11-23): niente cartella "bozze". Per ogni ordine UN PDF con dentro le
-- bozze, nella cartella del cliente sul NAS, anno corrente (anche nella sottocartella della lavorazione),
-- col numero d'ordine e "bozza" nel nome:  <cliente>/<anno>/00411 bozza.pdf
-- Il Mac mini (automazioni/dtf-cartella/bozze_nas.py) lo trova, lo carica con le anteprime delle pagine
-- (JPG, per vederle subito sull'iPad) e indica dove andrebbe salvato se manca (percorso suggerito).
-- Task: ordine aperto, non neutro, lavorazione non ancora Pronto e nessuna bozza → "Fare la bozza: <ordine>"
-- (Lavorazione grafica, assegnati a riccardo: il piano riscrive il designato, scadenza = scadenza dell'ordine). Si chiude da solo quando la bozza
-- c'è o l'ordine non ne ha più bisogno (Pronto, neutro, evaso, eliminato).
-- Richiede sql/bozze-ordini.sql. Si può rieseguire.
-- ════════════════════════════════════════════════════════

alter table public.ordini_bozze add column if not exists pagine jsonb not null default '[]';   -- anteprime JPG nel bucket
alter table public.ordini_bozze_stato add column if not exists suggerito text;                 -- dove salvare il PDF se manca

drop function if exists tc_bozze_salva(text, text, text, jsonb);
create or replace function tc_bozze_salva(p_chiave text, p_order_id text, p_cartella text, p_files jsonb, p_suggerito text default null)
returns jsonb security definer set search_path = public language plpgsql as $$
begin
  if not _tc_chiave_automazione_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  delete from ordini_bozze b where b.order_id = p_order_id
     and b.nome not in (select f->>'nome' from jsonb_array_elements(coalesce(p_files, '[]'::jsonb)) f);
  insert into ordini_bozze (order_id, nome, percorso, peso, mtime, tipo, pagine, aggiornato)
  select p_order_id, f->>'nome', f->>'percorso', coalesce((f->>'peso')::bigint, 0), coalesce((f->>'mtime')::double precision, 0),
         coalesce(f->>'tipo', ''), coalesce(f->'pagine', '[]'::jsonb), now()
    from jsonb_array_elements(coalesce(p_files, '[]'::jsonb)) f
  on conflict (order_id, nome) do update set percorso = excluded.percorso, peso = excluded.peso, mtime = excluded.mtime,
         tipo = excluded.tipo, pagine = excluded.pagine,
         aggiornato = case when ordini_bozze.mtime = excluded.mtime and ordini_bozze.peso = excluded.peso
                           then ordini_bozze.aggiornato else now() end;
  if p_cartella = '-' then
    delete from ordini_bozze_stato where order_id = p_order_id;   -- ordine chiuso: si toglie tutto
  else
    insert into ordini_bozze_stato (order_id, cartella, suggerito, at) values (p_order_id, nullif(p_cartella, ''), nullif(p_suggerito, ''), now())
    on conflict (order_id) do update set cartella = excluded.cartella, suggerito = excluded.suggerito, at = now();
  end if;
  return jsonb_build_object('success', true);
end;
$$;

-- Task "Fare la bozza": aperti per gli ordini che ne hanno bisogno, chiusi per gli altri. Lo chiama lo script
-- a fine giro (ogni 5 minuti), così si aggiornano anche quando l'ordine cambia (es. segnato Pronto).
create or replace function tc_bozze_task(p_chiave text)
returns jsonb security definer set search_path = public language plpgsql as $$
declare
  v_tipo uuid := (select id from task_tipi where nome = 'Lavorazione grafica' limit 1);
  r record; n_aperti int := 0; n_chiusi int := 0;
begin
  if not _tc_chiave_automazione_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  create temp table if not exists _bozze_servono (id text primary key) on commit drop;
  truncate _bozze_servono;
  insert into _bozze_servono
  select o.id from orders o join ordini_bozze_stato s on s.order_id = o.id
   where o.deleted_at is null and not coalesce(o.archived, false)
     and not coalesce((o.stages->'spedito'->>'done')::boolean, false)
     and not coalesce((o.stages->'ordineStampato'->>'done')::boolean, false)
     and not coalesce((o.order_module->>'neutro')::boolean, false)
     and not exists (select 1 from ordini_bozze b where b.order_id = o.id);

  for r in select x.id, x.nome, x.deadline, s.suggerito from _bozze_servono z join orders x on x.id = z.id
             join ordini_bozze_stato s on s.order_id = x.id loop
    if not exists (select 1 from tasks where fonte = 'automazione' and fonte_rif->>'bozze' = r.id
                    and stato not in ('completato', 'non_completato')) then
      insert into tasks (tipo_id, titolo, descrizione, priorita, fonte, fonte_rif, riferimento, scadenza, minuti_stimati, creato_da, designato, assegnato_a)
      values (v_tipo, left('Fare la bozza: ' || coalesce(r.nome, r.id), 200),
        'Prepara un PDF con le bozze e salvalo sul NAS'
          || coalesce(' in ' || r.suggerito, ' nella cartella del cliente, anno corrente,')
          || ' col nome «' || r.id || ' bozza.pdf». Il task si chiude da solo quando il Mac mini lo trova (entro 5 minuti).',
        'normale', 'automazione', jsonb_build_object('bozze', r.id, 'ordine', r.id, 'percorso', r.suggerito),
        jsonb_build_object('tipo', 'ordine', 'id', r.id, 'label', coalesce(r.nome, r.id)), r.deadline, 20, 'automazione', 'riccardo', 'riccardo');
      n_aperti := n_aperti + 1;
    else
      -- percorso suggerito aggiornato (es. cartella del cliente creata nel frattempo)
      update tasks set fonte_rif = fonte_rif || jsonb_build_object('percorso', r.suggerito)
       where fonte = 'automazione' and fonte_rif->>'bozze' = r.id and stato not in ('completato', 'non_completato')
         and fonte_rif->>'percorso' is distinct from r.suggerito;
    end if;
  end loop;

  update tasks set stato = 'completato', completato_at = now()
   where fonte = 'automazione' and fonte_rif ? 'bozze' and stato not in ('completato', 'non_completato')
     and not exists (select 1 from _bozze_servono z where z.id = tasks.fonte_rif->>'bozze');
  get diagnostics n_chiusi = row_count;
  return jsonb_build_object('success', true, 'aperti', n_aperti, 'chiusi', n_chiusi);
end;
$$;

revoke execute on function tc_bozze_salva(text, text, text, jsonb, text) from public, authenticated;
revoke execute on function tc_bozze_task(text) from public, authenticated;
grant execute on function tc_bozze_salva(text, text, text, jsonb, text) to anon;
grant execute on function tc_bozze_task(text) to anon;

-- Elenco per lo script, con le anteprime già caricate (per non rifarle e per toglierle quando servono)
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
        'bozze', coalesce((select jsonb_agg(jsonb_build_object('nome', b.nome, 'percorso', b.percorso, 'peso', b.peso, 'mtime', b.mtime, 'pagine', b.pagine))
                             from ordini_bozze b where b.order_id = o.id), '[]'::jsonb)))
        from orders o left join clients c on c.id = o.client_id
       where o.deleted_at is null and not coalesce(o.archived, false)
         and not coalesce((o.stages->'spedito'->>'done')::boolean, false)), '[]'::jsonb),
    'chiusi', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.order_id, 'percorsi', x.percorsi))
        from (select b.order_id, jsonb_agg(p) percorsi
                from ordini_bozze b, lateral (select b.percorso p union all select jsonb_array_elements_text(b.pagine)) pp
               where not exists (select 1 from orders o where o.id = b.order_id and o.deleted_at is null
                                   and not coalesce(o.archived, false)
                                   and not coalesce((o.stages->'spedito'->>'done')::boolean, false))
               group by b.order_id) x), '[]'::jsonb));
end;
$$;

-- Task già aperti prima della correzione: assegnati a riccardo
update tasks set assegnato_a = 'riccardo', designato = 'riccardo'
 where fonte = 'automazione' and fonte_rif ? 'bozze' and stato not in ('completato', 'non_completato') and assegnato_a is null;
