-- ════════════════════════════════════════════════════════
-- T&C Factory — Bozze: niente numero d'ordine nel nome del PDF (Riccardo, 2026-11-23)
-- Il PDF si chiama col nome dell'ordine e semmai la lavorazione: «CROSSFIT MONZA - FELPE bozza.pdf».
-- Lo script salva il nome da dare al file (ordini_bozze_stato.nome_file); task e pagina dell'ordine lo mostrano.
-- Sostituisce le funzioni di sql/bozze-pdf-task.sql. Si può rieseguire.
-- ════════════════════════════════════════════════════════

alter table public.ordini_bozze_stato add column if not exists nome_file text;

drop function if exists tc_bozze_salva(text, text, text, jsonb);
drop function if exists tc_bozze_salva(text, text, text, jsonb, text);
create or replace function tc_bozze_salva(p_chiave text, p_order_id text, p_cartella text, p_files jsonb, p_suggerito text default null, p_nome_file text default null)
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
    insert into ordini_bozze_stato (order_id, cartella, suggerito, nome_file, at)
    values (p_order_id, nullif(p_cartella, ''), nullif(p_suggerito, ''), nullif(p_nome_file, ''), now())
    on conflict (order_id) do update set cartella = excluded.cartella, suggerito = excluded.suggerito, nome_file = excluded.nome_file, at = now();
  end if;
  return jsonb_build_object('success', true);
end;
$$;

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

  for r in select x.id, x.nome, x.deadline, s.suggerito, coalesce(s.nome_file, x.nome || ' bozza.pdf') nome_file from _bozze_servono z join orders x on x.id = z.id
             join ordini_bozze_stato s on s.order_id = x.id loop
    if not exists (select 1 from tasks where fonte = 'automazione' and fonte_rif->>'bozze' = r.id
                    and stato not in ('completato', 'non_completato')) then
      insert into tasks (tipo_id, titolo, descrizione, priorita, fonte, fonte_rif, riferimento, scadenza, minuti_stimati, creato_da, designato, assegnato_a)
      values (v_tipo, left('Fare la bozza: ' || coalesce(r.nome, r.id), 200),
        'Prepara un PDF con le bozze e salvalo sul NAS'
          || coalesce(' in ' || r.suggerito, ' nella cartella del cliente, anno corrente,')
          || ' col nome «' || r.nome_file || '». Il task si chiude da solo quando il Mac mini lo trova (entro 5 minuti).',
        'normale', 'automazione', jsonb_build_object('bozze', r.id, 'ordine', r.id, 'percorso', r.suggerito, 'nome_file', r.nome_file),
        jsonb_build_object('tipo', 'ordine', 'id', r.id, 'label', coalesce(r.nome, r.id)), r.deadline, 20, 'automazione', 'riccardo', 'riccardo');
      n_aperti := n_aperti + 1;
    else
      -- percorso suggerito aggiornato (es. cartella del cliente creata nel frattempo)
      update tasks set fonte_rif = fonte_rif || jsonb_build_object('percorso', r.suggerito, 'nome_file', r.nome_file),
             descrizione = 'Prepara un PDF con le bozze e salvalo sul NAS'
               || coalesce(' in ' || r.suggerito, ' nella cartella del cliente, anno corrente,')
               || ' col nome «' || r.nome_file || '». Il task si chiude da solo quando il Mac mini lo trova (entro 5 minuti).'
       where fonte = 'automazione' and fonte_rif->>'bozze' = r.id and stato not in ('completato', 'non_completato')
         and (fonte_rif->>'percorso' is distinct from r.suggerito or fonte_rif->>'nome_file' is distinct from r.nome_file);
    end if;
  end loop;

  update tasks set stato = 'completato', completato_at = now()
   where fonte = 'automazione' and fonte_rif ? 'bozze' and stato not in ('completato', 'non_completato')
     and not exists (select 1 from _bozze_servono z where z.id = tasks.fonte_rif->>'bozze');
  get diagnostics n_chiusi = row_count;
  return jsonb_build_object('success', true, 'aperti', n_aperti, 'chiusi', n_chiusi);
end;
$$;

revoke execute on function tc_bozze_salva(text, text, text, jsonb, text, text) from public, authenticated;
revoke execute on function tc_bozze_task(text) from public, authenticated;
grant execute on function tc_bozze_salva(text, text, text, jsonb, text, text) to anon;
grant execute on function tc_bozze_task(text) to anon;
