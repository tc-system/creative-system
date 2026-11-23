// T&C Factory — Assistente: le domande che il gestionale non capisce da solo (2026-11-23)
//
// Sistema misto: il browser (js/assistente.js) risolve gratis le frasi che conosce; solo le altre
// arrivano qui. Claude Haiku 5.5 non risponde con i dati: traduce la frase in una richiesta
// strutturata (promemoria, ordini…) che il browser esegue sui dati già caricati.
// Così a Claude va solo la frase, mai ordini o clienti. Costo: frazioni di centesimo a domanda,
// registrato in assistente_consumi (pagina Costi del Centro di controllo).
//
// Deploy: supabase functions deploy assistente --no-verify-jwt (il token si verifica qui dentro)

import { createClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk';
import { consumoChiamata } from '../_shared/prezzi.ts';

const MODELLO = 'claude-haiku-5-5';
const MAX_AL_GIORNO = 300;   // tetto per persona: evita spese impreviste se qualcosa va in loop

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const fail = (error: string, status = 400) => reply({ success: false, error }, status);

const str = { type: 'string' };
const SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['tipo', 'promemoria', 'ordini', 'risposta'],
  properties: {
    tipo: { type: 'string', enum: ['promemoria', 'elenco_promemoria', 'ordini', 'fuori_ambito'] },
    promemoria: {
      type: 'object',
      additionalProperties: false,
      required: ['testo', 'quando', 'destinatario'],
      properties: { testo: str, quando: str, destinatario: str },
    },
    ordini: {
      type: 'object',
      additionalProperties: false,
      required: ['operazione', 'stato', 'scadenza_entro', 'cerca'],
      properties: {
        operazione: { type: 'string', enum: ['conta', 'elenco', 'piu_vecchio', 'piu_recente', 'apri'] },
        stato: { type: 'string', enum: ['da_evadere', 'in_lavorazione', 'pronti', 'in_ritardo', 'in_scadenza', 'da_riscuotere', 'evasi', 'archiviati', 'tutti'] },
        scadenza_entro: str,
        cerca: str,
      },
    },
    risposta: str,
  },
};

const SYSTEM = `Sei l'assistente del gestionale di un laboratorio di stampa su abbigliamento (magliette, felpe, DTF).
Chi ti scrive è una persona dello staff, in italiano, a voce o per iscritto: le frasi possono essere sgrammaticate,
trascritte male dal riconoscimento vocale o contenere imprecazioni (ignorale).
Non hai accesso ai dati: traduci la richiesta in una delle azioni qui sotto, che il gestionale esegue.

tipo:
- "promemoria": la persona vuole che le si ricordi qualcosa (o che lo si ricordi a un collega).
  promemoria.testo: cosa ricordare, breve, prima lettera maiuscola, senza la data/ora.
  promemoria.quando: data e ora locali "AAAA-MM-GGTHH:MM" calcolate da "Adesso". Se manca l'ora usa 09:00;
    "pomeriggio" 15:00, "sera" 19:00, "mattina" 09:00; "alle 3" in orario di lavoro è 15:00. Se manca del tutto
    quando, lascia "" (il gestionale lo chiederà).
  promemoria.destinatario: il nickname del collega tra quelli elencati, oppure "" se è per sé.
- "elenco_promemoria": vuole vedere i suoi promemoria programmati.
- "ordini": domanda sugli ordini dei clienti.
  ordini.operazione: conta (quanti), elenco (quali, mostrami), piu_vecchio, piu_recente, apri (un ordine preciso).
  ordini.stato: da_evadere (ancora da fare/spedire/consegnare, il valore normale quando non specificato),
    in_lavorazione (in produzione), pronti (pronti da evadere/spedire), in_ritardo (scadenza passata),
    in_scadenza (scadono entro una data), da_riscuotere (spediti ma non pagati), evasi (spediti/consegnati),
    archiviati (chiusi e pagati), tutti (anche quelli chiusi, es. "quanti ordini ha fatto X in tutto").
  ordini.scadenza_entro: solo per in_scadenza, data "AAAA-MM-GG" calcolata da "Adesso" (se non detta: tra 7 giorni); altrimenti "".
  ordini.cerca: nome del cliente, nome dell'ordine o numero dell'ordine se nominato, così come detto; altrimenti "".
- "fuori_ambito": tutto il resto (saluti, domande su soldi/incassi, prodotti, magazzino, cose generali).
  risposta: una frase breve e cordiale che dice che per ora sai creare promemoria e rispondere sugli ordini.
I campi non usati restano stringhe vuote (e per "ordini" usa operazione "elenco" e stato "da_evadere").
"risposta" è "" tranne per fuori_ambito.`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('Metodo non consentito', 405);
  if (!Deno.env.get('ANTHROPIC_API_KEY')) return fail('Manca la chiave ANTHROPIC_API_KEY su Supabase', 500);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ── Chi sta chiamando? Serve un account dello staff ──
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: caller } = await db.auth.getUser(token);
  if (!caller?.user) return fail('Accesso richiesto', 401);
  const { data: me } = await db.from('app_users').select('nickname').eq('auth_id', caller.user.id).maybeSingle();
  if (!me?.nickname) return fail('Accesso richiesto', 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return fail('Richiesta non valida'); }
  const domanda = String(body.domanda || '').trim().slice(0, 300);
  const adesso = String(body.adesso || '').slice(0, 60);
  const utenti = (Array.isArray(body.utenti) ? body.utenti : []).map(String).slice(0, 50);
  if (!domanda) return fail('Domanda vuota');

  const oggi = new Date(); oggi.setUTCHours(0, 0, 0, 0);
  const { count } = await db.from('assistente_consumi').select('id', { count: 'exact', head: true })
    .eq('utente', me.nickname).gte('at', oggi.toISOString());
  if ((count || 0) >= MAX_AL_GIORNO) return fail('Hai raggiunto il limite di domande di oggi', 429);

  try {
    const res = await new Anthropic().messages.create({
      model: MODELLO,
      max_tokens: 4000,
      output_config: { effort: 'low', format: { type: 'json_schema', schema: SCHEMA } },
      system: SYSTEM,
      messages: [{ role: 'user', content: `Adesso: ${adesso}\nColleghi: ${utenti.join(', ') || '—'}\nChi scrive: ${me.nickname}\n\nRichiesta: ${domanda}` }],
    } as Anthropic.MessageCreateParamsNonStreaming);

    const uso = consumoChiamata(res.model || MODELLO, res.usage, MODELLO);
    if (res.stop_reason === 'refusal' || res.stop_reason === 'max_tokens') {
      await db.from('assistente_consumi').insert({ ...uso, utente: me.nickname, domanda, tipo: 'errore' });
      return fail('Non sono riuscito a capire la richiesta', 422);
    }
    const text = res.content.flatMap(b => b.type === 'text' ? [b.text] : []).join('');
    const dati = JSON.parse(text);
    await db.from('assistente_consumi').insert({ ...uso, utente: me.nickname, domanda, tipo: dati?.tipo || null });
    return reply({ success: true, dati, costo_usd: uso.costo_usd });
  } catch (e) {
    console.error('Assistente', e instanceof Error ? e.message : e);
    return fail('Assistente non disponibile in questo momento', 502);
  }
});
