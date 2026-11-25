// Relay SMTP con IP fisso (Railway, Static Outbound IP). Le funzioni Supabase escono da IP AWS condivisi che
// Aruba ogni tanto rifiuta ("550 5.1.0 ... temporaneamente rifiutata"): passano qui la mail già composta e
// questo servizio la consegna ad Aruba dal suo indirizzo fisso.
// POST /invia  Authorization: Bearer RELAY_SECRET
//   { host, port?, user, pass, from, to: string|string[], raw: base64 }  →  { ok: true } | { error }
// GET  /ip     indirizzo d'uscita (per controllo)
import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import nodemailer from 'nodemailer';

const SECRET = process.env.RELAY_SECRET || '';
if (SECRET.length < 32) { console.error('RELAY_SECRET mancante o troppo corto'); process.exit(1); }

const autorizzato = (req) => {
  const a = Buffer.from(req.headers.authorization || '');
  const b = Buffer.from(`Bearer ${SECRET}`);
  return a.length === b.length && timingSafeEqual(a, b);
};

const rispondi = (res, code, obj) => {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(obj));
};

const leggi = (req) => new Promise((ok, ko) => {
  const parti = []; let n = 0;
  req.on('data', c => { n += c.length; if (n > 40e6) { ko(new Error('Mail troppo grande')); req.destroy(); } else parti.push(c); });
  req.on('end', () => ok(Buffer.concat(parti).toString('utf8')));
  req.on('error', ko);
});

http.createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/salute') return rispondi(res, 200, { ok: true });
    if (!autorizzato(req)) return rispondi(res, 401, { error: 'Non autorizzato' });
    if (req.method === 'GET' && req.url === '/ip') {
      const ip = await fetch('https://api.ipify.org').then(r => r.text());
      return rispondi(res, 200, { ip });
    }
    if (req.method !== 'POST' || req.url !== '/invia') return rispondi(res, 404, { error: 'Non trovato' });

    const b = JSON.parse(await leggi(req));
    if (!b.host || !b.user || !b.pass || !b.from || !b.to || !b.raw) return rispondi(res, 400, { error: 'Dati mancanti' });
    if (!/(^|\.)aruba\.it$/i.test(b.host)) return rispondi(res, 400, { error: 'Server SMTP non ammesso' });

    const smtp = nodemailer.createTransport({
      host: b.host, port: b.port || 465, secure: (b.port || 465) === 465,
      auth: { user: b.user, pass: b.pass },
      connectionTimeout: 15000, greetingTimeout: 15000, socketTimeout: 60000,
    });
    const t = Date.now();
    await smtp.sendMail({ envelope: { from: b.from, to: b.to }, raw: Buffer.from(b.raw, 'base64') });
    console.log(`Inviata da ${b.from} in ${Date.now() - t} ms`);
    rispondi(res, 200, { ok: true });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error('Invio non riuscito:', msg);
    // prima_del_testo: Aruba ha rifiutato prima del testo, la mail non è partita (si può riprovare altrove)
    rispondi(res, 502, { error: msg, prima_del_testo: /^(Mail command|Invalid login|Connection|Greeting|connect|getaddrinfo)/i.test(msg) || e?.code === 'EAUTH' || e?.code === 'ECONNECTION' });
  }
}).listen(process.env.PORT || 8080, () => console.log('smtp-relay pronto'));
