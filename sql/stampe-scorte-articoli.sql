-- ════════════════════════════════════════════════════════
-- T&C Factory — Scorte di articoli: Ciucciami Il Calzino (calzini XS…XL e polsini), 2026-11-24
--
-- Le stampe di Bienjugado si scalano solo dagli ordini del loro negozio. Gli articoli (regola
-- 'calzini' / 'polsini') invece si scalano da:
--   • gli ordini pagati di TUTTI i negozi Shopify (righe "Calzini - …"/"Calzino - …" con la taglia
--     XS/S/M/L/XL nella variante; righe "Polsini - …");
--   • gli ordini del gestionale, inseriti a mano o arrivati da Kamon (righe del modulo con
--     fornitore Ciucciami / Magazzino / vuoto, descrizione o codice con CALZ/CLZ e la taglia
--     in "Tg", oppure POLSIN). L'ordine si riallinea a ogni modifica; nel cestino ridà i pezzi.
-- Come per le stampe, contano solo gli ordini creati dopo la spunta.
-- Richiede stampe-scorte.sql. Si può rieseguire. (Spunta messa il 2026-11-24 alle 9:10 circa.)
-- ════════════════════════════════════════════════════════

alter table stampe_scorte add column if not exists regola text;
alter table stampe_scorte drop constraint if exists stampe_scorte_regola_check;
alter table stampe_scorte add constraint stampe_scorte_regola_check check (regola in ('calzini', 'polsini'));

insert into stampe_scorte (store_id, famiglia, colore, regola)
select 'ciucciamilcalzino', 'Calzini', t, 'calzini' from unnest(array['XS', 'S', 'M', 'L', 'XL']) t
union all select 'ciucciamilcalzino', 'Polsini', '', 'polsini'
on conflict (store_id, famiglia, colore) do update set regola = excluded.regola;

-- Taglia XS…XL in un testo ("L", "L (42/44)", "Bianco / L"); null se non c'è
create or replace function _tc_taglia_xs_xl(p text) returns text language sql immutable as $$
  select (select upper(trim(m[1])) from regexp_matches(upper(coalesce(p, '')), '(?:^|[\s/(,])(XS|S|M|L|XL)(?=$|[\s/),])') m limit 1);
$$;

-- Articolo di una riga Shopify (qualsiasi negozio)
create or replace function _tc_articolo_shopify(p_titolo text, p_variante text) returns uuid
language sql stable set search_path = public as $$
  select s.id from stampe_scorte s
   where (s.regola = 'polsini' and p_titolo ~* '^\s*polsin')
      or (s.regola = 'calzini' and p_titolo ~* '^\s*calzin' and p_titolo !~* 'padel|antiscivolo|sportiv'
          and s.colore = _tc_taglia_xs_xl(p_variante))
   limit 1;
$$;

-- Articolo di una riga del modulo d'ordine del gestionale (anche Kamon)
create or replace function _tc_articolo_gestionale(p_riga jsonb) returns uuid
language sql stable set search_path = public as $$
  select s.id from stampe_scorte s,
         (select upper(trim(coalesce(p_riga->>'catalogo', ''))) cat,
                 upper(concat_ws(' ', p_riga->>'descrizione', p_riga->>'codice')) txt) x
   where (x.cat = '' or x.cat like 'CIUCCIAMI%' or x.cat like 'MAG%')
     and ((s.regola = 'polsini' and x.txt ~ 'POLSIN')
       or (s.regola = 'calzini' and x.txt ~ 'CALZ|CLZ' and x.txt !~ 'POLSIN' and s.colore = _tc_taglia_xs_xl(p_riga->>'tg')))
   limit 1;
$$;

-- Ordini Shopify: le stampe del negozio (come prima) e gli articoli di tutti i negozi
create or replace function _tc_stampe_ordine() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; v_id uuid; v_art uuid; v_titolo text; v_n int; v_riga text;
  v_stampe boolean := exists (select 1 from stampe_scorte where store_id = new.store_id and regola is null);
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
    if v_stampe and v_id is null and v_art is null
       and not exists (select 1 from stampe_scorte where store_id = new.store_id and v_titolo = any(prodotti)) then
      -- Prodotto che non era nell'elenco delle stampe: compare da spuntare (non si conta)
      insert into stampe_scorte (store_id, famiglia, prodotti, nuovo) values (new.store_id, v_titolo, array[v_titolo], true)
      on conflict (store_id, famiglia, colore) do nothing;
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

-- Ordini del gestionale (a mano o da Kamon): i pezzi dell'ordine si riallineano a ogni modifica.
-- Movimenti con ordine = 'gest:<id>'; nel cestino l'ordine vale zero (ridà i pezzi).
create or replace function _tc_stampe_gestionale() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; v_ord text := 'gest:' || new.id; v_chi text := case when new.order_module->>'origine' = 'kamon' then 'Kamon' else 'Gestionale' end;
begin
  if not exists (select 1 from stampe_scorte where regola is not null and conteggia) then return new; end if;
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
     where s.regola is not null and s.conteggia and new.created_at >= s.conteggia_dal
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
drop trigger if exists orders_stampe on orders;
create trigger orders_stampe after insert or update of order_module, deleted_at on orders
  for each row execute function _tc_stampe_gestionale();

-- Elenco: per gli articoli i venduti vengono da tutti i negozi e dal gestionale
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
         group by 1
        union all
        select _tc_articolo_shopify(trim(x->>'titolo'), x->>'variante'), sum(coalesce((x->>'qnt')::int, 1))
          from shopify_orders o, jsonb_array_elements(o.righe) x
         where o.annullato_at is null and o.stato_pagamento in ('PAID', 'PARTIALLY_REFUNDED')
           and exists (select 1 from stampe_scorte where store_id = p_store and regola is not null)
         group by 1
        union all
        select _tc_articolo_gestionale(x), sum(greatest(0, coalesce(nullif(x->>'qnt', '')::numeric, 0)))::int
          from orders o, jsonb_array_elements(case when jsonb_typeof(o.order_module->'rows') = 'array' then o.order_module->'rows' else '[]' end) x
         where o.deleted_at is null and exists (select 1 from stampe_scorte where store_id = p_store and regola is not null)
         group by 1)
      select jsonb_agg(to_jsonb(s) || jsonb_build_object('venduti', coalesce(v.n, 0))
                       order by s.famiglia, array_position(array['XS', 'S', 'M', 'L', 'XL'], s.colore), s.colore)
        from stampe_scorte s left join (select id, sum(n) n from venduti where id is not null group by 1) v on v.id = s.id
       where s.store_id = p_store), '[]'::jsonb));
end;
$$;

revoke execute on function _tc_taglia_xs_xl(text), _tc_articolo_shopify(text, text), _tc_articolo_gestionale(jsonb), _tc_stampe_gestionale() from public, anon, authenticated;
