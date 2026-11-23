-- Tutti possono eliminare (con la X, previa conferma) i task che vedono
drop policy if exists "Task eliminabili" on tasks;
create policy "Task eliminabili" on tasks for delete to authenticated
  using (app_is_admin() or assegnato_a = app_nickname() or (assegnato_a is null and app_is_staff()));
