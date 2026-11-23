-- ════════════════════════════════════════════════════════
-- T&C Factory — Assistente: consumi di Claude Haiku (2026-11-23)
--
--   • assistente_consumi: una riga per ogni domanda che l'assistente non capiva da solo
--     ed è passata a Haiku (chi l'ha fatta, token, costo). La scrive solo la funzione assistente.
--   • cervello_costo_giorni ora somma anche l'assistente: la pagina Costi lo conta in "API Claude".
-- Si può rieseguire.
-- ════════════════════════════════════════════════════════

create table if not exists assistente_consumi (
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  utente        text not null,
  domanda       text not null default '',
  tipo          text,
  modello       text not null,
  input         int not null default 0,
  output        int not null default 0,
  cache_letti   int not null default 0,
  cache_scritti int not null default 0,
  costo_usd     numeric(10,5) not null default 0
);
create index if not exists assistente_consumi_at_idx on assistente_consumi (at desc);
create index if not exists assistente_consumi_utente_idx on assistente_consumi (utente, at desc);
alter table assistente_consumi enable row level security;
drop policy if exists "Admin legge consumi assistente" on assistente_consumi;
create policy "Admin legge consumi assistente" on assistente_consumi for select to authenticated using (app_is_admin());
revoke all on assistente_consumi from anon, authenticated;
grant select on assistente_consumi to authenticated;

-- Spesa di Claude per giorno (ora di Roma): cervello senza le prove dei modelli + assistente
create or replace view cervello_costo_giorni with (security_invoker = true) as
  select giorno, sum(usd) as usd, sum(chiamate)::bigint as chiamate from (
    select (at at time zone 'Europe/Rome')::date as giorno, costo_usd as usd, 1 as chiamate from cervello_consumi where not prova
    union all
    select (at at time zone 'Europe/Rome')::date, costo_usd, 1 from assistente_consumi
  ) t group by giorno;
