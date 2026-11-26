-- ════════════════════════════════════════════════════════
-- T&C Factory — DTF Conto terzi: si conta quando è stampato (dal 2026-11-26)
-- Il Mac mini copia i file da Drive in 1. Stampare/1 - <cliente> e li registra (copiato_at) SENZA contarli.
-- Quando in sede il file va in 1 - <cliente>/stampato, il Mac mini chiama tc_dtf_ct_stampati: il file
-- entra nel calendario del conto terzi di quel giorno (dtf_entries) e su Drive va in STAMPATO.
-- Richiede sql/dtf-ct-drive.sql e sql/dtf-ct-copia.sql. Si può rieseguire.
-- ════════════════════════════════════════════════════════

-- File già conosciuti: 'copiato' = già copiato sul NAS (non si ricopia); 'contato' resta per gli script vecchi
create or replace function tc_dtf_ct_dati(p_chiave text)
returns jsonb security definer set search_path = public language plpgsql as $$
begin
  if not _tc_chiave_automazione_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  return jsonb_build_object('success', true,
    'lavorativo', tc_giorno_lavorativo(tc_oggi()),
    'clienti', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'drive_url', c.drive_url, 'giorni', c.giorni))
       from dtf_clients c where coalesce(c.drive_url, '') <> ''), '[]'::jsonb),
    'files', coalesce((select jsonb_object_agg(f.drive_id, jsonb_build_object('size', f.size, 'modificato', f.modificato,
       'copiato', f.copiato_at is not null or f.stampato_giorno is not null,
       'contato', f.copiato_at is not null or f.stampato_giorno is not null)) from dtf_ct_files f), '{}'::jsonb));
end;
$$;

-- File copiati sul NAS: solo registrati, non contati (una versione nuova dello stesso file si riconta da stampata)
-- p_files: [{ drive_id, nome, percorso, size, modificato, item }]
create or replace function tc_dtf_ct_copiati(p_chiave text, p_client uuid, p_files jsonb)
returns jsonb security definer set search_path = public language plpgsql as $$
declare x jsonb; v_old dtf_ct_files; v_metri numeric := 0; n int := 0;
begin
  if not _tc_chiave_automazione_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  if not exists (select 1 from dtf_clients where id = p_client) then return jsonb_build_object('success', false, 'error', 'Cliente non trovato'); end if;
  for x in select * from jsonb_array_elements(coalesce(p_files, '[]'::jsonb)) loop
    select * into v_old from dtf_ct_files where drive_id = x->>'drive_id';
    continue when found and (v_old.copiato_at is not null or v_old.stampato_giorno is not null)
                 and v_old.size is not distinct from (x->>'size')::bigint
                 and v_old.modificato is not distinct from (x->>'modificato')::timestamptz;
    insert into dtf_ct_files (client_id, drive_id, nome, percorso, size, modificato, item, metri, stampato_giorno, copiato_at)
    values (p_client, x->>'drive_id', x->>'nome', x->>'percorso', (x->>'size')::bigint, (x->>'modificato')::timestamptz,
            coalesce(x->'item', '{}'::jsonb), nullif(x->'item'->>'metri', '')::numeric, null, now())
    on conflict (drive_id) do update set nome = excluded.nome, percorso = excluded.percorso, size = excluded.size,
      modificato = excluded.modificato, item = excluded.item, metri = excluded.metri, stampato_giorno = null,
      copiato_at = now(), visto_at = now();
    v_metri := v_metri + coalesce(nullif(x->'item'->>'metri', '')::numeric, 0);
    n := n + 1;
  end loop;
  return jsonb_build_object('success', true, 'copiati', n, 'metri', round(v_metri, 2));
end;
$$;
revoke execute on function tc_dtf_ct_copiati(text, uuid, jsonb) from public;
grant execute on function tc_dtf_ct_copiati(text, uuid, jsonb) to anon, authenticated;

-- File spostati in 1 - <cliente>/stampato: si contano nel calendario di oggi, una volta sola
-- p_drive_ids: ["<drive_id>", …]
create or replace function tc_dtf_ct_stampati(p_chiave text, p_client uuid, p_drive_ids jsonb)
returns jsonb security definer set search_path = public language plpgsql as $$
declare v_oggi date := tc_oggi(); v_metri numeric := 0; v_nomi text[] := '{}'; v_items jsonb := '[]'; n int := 0; f dtf_ct_files;
begin
  if not _tc_chiave_automazione_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  for f in update dtf_ct_files set stampato_giorno = v_oggi
           where client_id = p_client and stampato_giorno is null
             and drive_id in (select jsonb_array_elements_text(coalesce(p_drive_ids, '[]'::jsonb)))
           returning * loop
    v_metri := v_metri + coalesce(f.metri, 0);
    v_nomi := v_nomi || f.nome;
    v_items := v_items || jsonb_build_array(coalesce(f.item, '{}'::jsonb));
    n := n + 1;
  end loop;
  if n > 0 then
    insert into dtf_entries (client_id, giorno, metri, dettaglio, files, updated_by, updated_at)
    values (p_client, v_oggi, round(v_metri, 2), array_to_string(v_nomi, E'\n'), v_items, 'automazione', now())
    on conflict (client_id, giorno) do update set
      metri = round(coalesce(dtf_entries.metri, 0) + excluded.metri, 2),
      dettaglio = concat_ws(E'\n', nullif(dtf_entries.dettaglio, ''), excluded.dettaglio),
      files = coalesce(dtf_entries.files, '[]'::jsonb) || excluded.files,
      updated_by = excluded.updated_by, updated_at = now();
  end if;
  return jsonb_build_object('success', true, 'contati', n, 'metri', round(v_metri, 2));
end;
$$;
revoke execute on function tc_dtf_ct_stampati(text, uuid, jsonb) from public;
grant execute on function tc_dtf_ct_stampati(text, uuid, jsonb) to anon, authenticated;
