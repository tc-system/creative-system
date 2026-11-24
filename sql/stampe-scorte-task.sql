-- T&C Factory — Scorte stampe spostate da Brand ai Task (coda SCORTE): le vede chi ha la scheda Task
drop policy if exists "Brand legge scorte" on stampe_scorte;
drop policy if exists "Brand legge movimenti" on stampe_movimenti;
drop policy if exists "Task legge scorte" on stampe_scorte;
drop policy if exists "Task legge movimenti" on stampe_movimenti;
create policy "Task legge scorte" on stampe_scorte for select to authenticated using (app_vede_scheda('tasks'));
create policy "Task legge movimenti" on stampe_movimenti for select to authenticated using (app_vede_scheda('tasks'));

-- Le RPC dell'elenco: stesso controllo, scheda Task al posto di Brand
do $$
declare f record; def text;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('tc_stampe_lista', 'tc_stampe_conteggia', 'tc_stampe_salva') loop
    def := replace(pg_get_functiondef(f.oid), 'app_vede_scheda(''comunicazione'')', 'app_vede_scheda(''tasks'')');
    execute def;
  end loop;
end $$;
