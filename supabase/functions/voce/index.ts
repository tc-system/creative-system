// T&C Factory — Voce dell'assistente con Google Text-to-Speech (2026-11-23)
//
// Il browser manda la frase da leggere, qui diventa un MP3 con una voce italiana naturale.
// Serve il secret GOOGLE_TTS_KEY (chiave API di Google Cloud con "Cloud Text-to-Speech API" attiva).
// Senza chiave risponde 503 e il browser usa la sua voce. I caratteri letti finiscono in
// voce_consumi (sql/voce-consumi.sql) per controllare la quota gratuita di Google.
//
// Deploy: supabase functions deploy voce --no-verify-jwt (il token si verifica qui dentro)

import { createClient } from 'npm:@supabase/supabase-js@2';

// Prima la voce migliore; se Google non la trova si prova la successiva
const VOCI = ['it-IT-Chirp3-HD-Aoede', 'it-IT-Neural2-A', 'it-IT-Wavenet-A'];
const MAX_CARATTERI = 600;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const fail = (error: string, status = 400) => reply({ success: false, error }, status);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('Metodo non consentito', 405);
  const chiave = Deno.env.get('GOOGLE_TTS_KEY');
  if (!chiave) return fail('Voce Google non ancora attivata', 503);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: caller } = await db.auth.getUser(token);
  if (!caller?.user) return fail('Accesso richiesto', 401);
  const { data: me } = await db.from('app_users').select('nickname').eq('auth_id', caller.user.id).maybeSingle();
  if (!me?.nickname) return fail('Accesso richiesto', 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return fail('Richiesta non valida'); }
  const testo = String(body.testo || '').replace(/\s+/g, ' ').trim().slice(0, MAX_CARATTERI);
  if (!testo) return fail('Testo vuoto');

  let ultimoErrore = '';
  for (const voce of VOCI) {
    const res = await fetch(`https://texttospeech.googleapis.com/v1/text:synthesize?key=${encodeURIComponent(chiave)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        input: { text: testo },
        voice: { languageCode: 'it-IT', name: voce },
        audioConfig: { audioEncoding: 'MP3' },
      }),
    });
    const dati = await res.json().catch(() => ({}));
    if (res.ok && dati.audioContent) {
      await db.from('voce_consumi').insert({ utente: me.nickname, caratteri: testo.length, voce });
      return reply({ success: true, audio: dati.audioContent, voce });
    }
    ultimoErrore = dati?.error?.message || `Errore ${res.status}`;
    // Chiave sbagliata o API non attiva: inutile provare le altre voci
    if (res.status === 401 || res.status === 403) break;
  }
  console.error('Voce Google', ultimoErrore);
  return fail('Voce Google non disponibile: ' + ultimoErrore, 502);
});
