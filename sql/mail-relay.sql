-- ════════════════════════════════════════════════════════
-- Invio mail dal Mac mini in sede (relay)
-- Aruba ogni tanto rifiuta gli IP AWS condivisi da cui escono le funzioni Supabase ("550 5.1.0 ...
-- temporaneamente rifiutata"). Le funzioni mettono qui la mail già composta; l'agente sul Mac mini
-- (automazioni/mail-relay/relay.py) la prende e la consegna ad Aruba dalla connessione dell'ufficio.
-- Se l'agente non si è fatto vivo da 15 secondi, o non prende la mail in tempo, le funzioni inviano direttamente.
-- Password e testo si cancellano appena l'invio è finito (o annullato).
-- L'agente usa la chiave dello script del mattino (Vault 'automazione_mattino_key').
-- Richiede automazione-mattino.sql (_tc_mattino_chiave_ok). Si può rieseguire.
-- ════════════════════════════════════════════════════════

create table if not exists public.mail_relay_coda (
  id              bigint generated always as identity primary key,
  creato_at       timestamptz not null default now(),
  stato           text not null default 'attesa' check (stato in ('attesa', 'presa', 'inviata', 'errore', 'annullata')),
  host            text not null,
  porta           int  not null default 465,
  utente          text not null,
  pass            text,
  da              text not null,
  a               text not null,
  raw             text,             -- mail composta, base64
  errore          text,
  prima_del_testo boolean,          -- errore arrivato prima del testo: la mail non è partita, si può ripiegare
  agente          text,
  presa_at        timestamptz,
  finita_at       timestamptz
);
alter table public.mail_relay_coda enable row level security;
revoke all on public.mail_relay_coda from anon, authenticated;

create table if not exists public.mail_relay_agenti (
  nome     text primary key,
  visto_at timestamptz not null default now()
);
alter table public.mail_relay_agenti enable row level security;
revoke all on public.mail_relay_agenti from anon, authenticated;

-- Dall'agente: segna che è vivo e prende la mail più vecchia in attesa
create or replace function tc_mail_relay_prossima(p_chiave text, p_agente text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.mail_relay_coda;
begin
  if not _tc_mattino_chiave_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  insert into mail_relay_agenti (nome, visto_at) values (p_agente, now())
  on conflict (nome) do update set visto_at = now();
  -- Pulizia: niente password in giro, righe vecchie via dopo una settimana
  update mail_relay_coda set stato = 'annullata', pass = null, raw = null, finita_at = now()
   where stato = 'attesa' and creato_at < now() - interval '2 minutes';
  update mail_relay_coda set stato = 'errore', errore = 'Interrotto: il Mac mini non ha risposto', pass = null, raw = null, finita_at = now()
   where stato = 'presa' and presa_at < now() - interval '5 minutes';
  delete from mail_relay_coda where creato_at < now() - interval '7 days';

  select * into r from mail_relay_coda where stato = 'attesa' order by creato_at limit 1 for update skip locked;
  if not found then return jsonb_build_object('success', true, 'mail', null); end if;
  update mail_relay_coda set stato = 'presa', presa_at = now(), agente = p_agente where id = r.id returning * into r;
  return jsonb_build_object('success', true, 'mail', jsonb_build_object(
    'id', r.id, 'host', r.host, 'porta', r.porta, 'utente', r.utente, 'pass', r.pass, 'da', r.da, 'a', r.a, 'raw', r.raw));
end;
$$;

create or replace function tc_mail_relay_esito(p_chiave text, p_id bigint, p_ok boolean, p_errore text default null, p_prima_del_testo boolean default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _tc_mattino_chiave_ok(p_chiave) then return jsonb_build_object('success', false, 'error', 'Chiave non valida'); end if;
  update mail_relay_coda
     set stato = case when p_ok then 'inviata' else 'errore' end, errore = p_errore, prima_del_testo = p_prima_del_testo,
         pass = null, raw = null, finita_at = now()
   where id = p_id and stato = 'presa';
  return jsonb_build_object('success', true);
end;
$$;

revoke execute on function tc_mail_relay_prossima(text, text), tc_mail_relay_esito(text, bigint, boolean, text, boolean) from public, authenticated;
grant  execute on function tc_mail_relay_prossima(text, text), tc_mail_relay_esito(text, bigint, boolean, text, boolean) to anon;
