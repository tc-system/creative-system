-- T&C Factory — Scorte Bienjugado: anche le Felpe FUN (utente 2026-11-24; i calzini FUN no).
-- La felpa usa la stessa grafica della t-shirt dove c'è (stessa riga); le grafiche solo-felpa sono righe nuove.
-- Le felpe nuove entrano da sole come le t-shirt. Si può rieseguire.
insert into app_settings (key, value) values ('stampe_scorte_nuove', '{"bienjugado": "^(T-Shirt Fun|Felpa Unisex - Fun)"}')
on conflict (key) do update set value = excluded.value;

insert into stampe_scorte (store_id, famiglia, colore, prodotti, conteggia) values
  ('bienjugado', 'Bienjugado Circle', '', array['Felpa Unisex - Fun - Bienjugado Circle'], true),
  ('bienjugado', 'Siempre Por El Centro', '', array['Felpa Unisex - Fun - Siempre Por El Centro'], true)
on conflict (store_id, famiglia, colore) do nothing;

update stampe_scorte s set prodotti = s.prodotti || f.titolo
  from (values ('Bandeja', 'Felpa Unisex - Fun - Bandeja'), ('Padel Dad', 'Felpa Unisex - Fun - Padel Dad'),
               ('Padel Hub', 'Felpa Unisex - Fun - Padel Hub'), ('Padel Mom', 'Felpa Unisex - Fun - Padel Mom')) f(famiglia, titolo)
 where s.store_id = 'bienjugado' and s.famiglia = f.famiglia and s.colore = '' and not f.titolo = any(s.prodotti);
