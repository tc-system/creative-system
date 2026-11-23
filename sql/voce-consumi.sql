-- ════════════════════════════════════════════════════════
-- T&C Factory — Voce dell'assistente: caratteri letti da Google Text-to-Speech (2026-11-23)
--   Una riga per ogni risposta letta. Serve a controllare la quota gratuita mensile di Google.
--   La scrive solo la funzione voce. Si può rieseguire.
-- ════════════════════════════════════════════════════════

create table if not exists voce_consumi (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  utente    text not null,
  caratteri int not null default 0,
  voce      text
);
create index if not exists voce_consumi_at_idx on voce_consumi (at desc);
alter table voce_consumi enable row level security;
drop policy if exists "Admin legge consumi voce" on voce_consumi;
create policy "Admin legge consumi voce" on voce_consumi for select to authenticated using (app_is_admin());
revoke all on voce_consumi from anon, authenticated;
grant select on voce_consumi to authenticated;
