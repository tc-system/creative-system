/**
 * T&C Factory — Scorte delle stampe dei negozi (Task → coda SCORTE → Bienjugado)
 *
 *  Elenco delle stampe per famiglia di prodotti (es. "Short Uomo") con i colori della stampa.
 *  La spunta sulla famiglia dice di contarla: da lì ogni ordine pagato scala i pezzi da solo
 *  (trigger su shopify_orders, sql/stampe-scorte.sql). Qui si correggono pezzi, soglia, pezzi per file
 *  e il file sul NAS: scesi alla soglia, il Mac mini copia il file in "1. Stampare/01 - Ordini Siti".
 */

const ScorteStampe = {
  negozio: null,
  stampe: null,     // righe di stampe_scorte + venduti
  dal: null,        // primo ordine importato (per "venduti")
  cerca: '',
  filtro: 'tutte',  // tutte | contate | nuove
  errore: null,
  caricatoAt: 0,
  inCarico: false,
  contate: null,    // { store_id, quantita, soglia } di tutte le scorte contate con la soglia (numero della coda)
};

// Negozi con le scorte delle stampe (le chip della coda SCORTE)
// Ciucciami: articoli (calzini per taglia, polsini) scalati da tutti i siti e dagli ordini del gestionale/Kamon
const SCORTE_NEGOZI = [{ id: 'bienjugado' }, { id: 'ciucciamilcalzino' }];

// Articoli (non stampe): calzini e polsini di Ciucciami, senza file. Le bandierine sono stampe "su richiesta".
const scorteArticolo = (r) => r.regola === 'calzini' || r.regola === 'polsini';

const SCORTE_FILTRI = { tutte: 'Tutte', contate: 'Da contare', nuove: 'Nuove' };

async function scorteCarica(negozio) {
  ScorteStampe.negozio = negozio;
  ScorteStampe.inCarico = true;
  const [{ data, error }] = await Promise.all([supabaseClient.rpc('tc_stampe_lista', { p_store: negozio }), scorteContaCarica()]);
  ScorteStampe.inCarico = false;
  ScorteStampe.caricatoAt = Date.now();
  if (ScorteStampe.negozio !== negozio) return;
  if (error || !data?.success) {
    ScorteStampe.errore = error?.message || data?.error || 'Elenco non letto';
    ScorteStampe.stampe = [];
  } else {
    ScorteStampe.errore = null;
    ScorteStampe.stampe = data.stampe;
    ScorteStampe.dal = data.dal;
  }
  // Nei task si ridisegna la pagina intera: cambia anche il numero della coda
  if (typeof ctrlAperto === 'function' && ctrlAperto()) refreshControlPage(); else scorteRender();
}

// Scorte contate con la soglia, di tutti i negozi (per i numeri della coda e dei negozi)
async function scorteContaCarica() {
  const { data } = await supabaseClient.from('stampe_scorte').select('id, store_id, quantita, soglia').eq('conteggia', true).not('soglia', 'is', null);
  if (data) ScorteStampe.contate = data;
}

// Scorte contate scese alla soglia (il numero sulla coda SCORTE), di un negozio o di tutti; la prima volta carica l'elenco
function scorteSottoSoglia(negozio = null) {
  if (ScorteStampe.stampe === null && !ScorteStampe.inCarico && typeof supabaseClient !== 'undefined') scorteCarica(ScorteStampe.negozio || SCORTE_NEGOZI[0].id);
  // Il negozio aperto conta dall'elenco (appena salvato), gli altri dall'ultimo conteggio
  const aperto = ScorteStampe.stampe ? ScorteStampe.negozio : null;
  return (ScorteStampe.contate || []).filter(r => r.store_id !== aperto && (!negozio || r.store_id === negozio) && r.quantita <= r.soglia).length
    + (aperto && (!negozio || negozio === aperto) ? ScorteStampe.stampe.filter(scorteSotto).length : 0);
}

// Famiglie in ordine alfabetico, con i loro colori
function scorteFamiglie() {
  const m = new Map();
  for (const s of ScorteStampe.stampe || []) {
    if (!m.has(s.famiglia)) m.set(s.famiglia, []);
    m.get(s.famiglia).push(s);
  }
  return [...m].map(([nome, righe]) => ({
    nome, righe,
    conteggia: righe.some(r => r.conteggia),
    nuovo: righe.some(r => r.nuovo),
    articolo: righe.some(scorteArticolo),
    venduti: righe.reduce((t, r) => t + (r.venduti || 0), 0),
    sotto: righe.filter(scorteSotto).length,
  }));
}

const scorteSotto = (r) => r.conteggia && r.soglia != null && r.quantita <= r.soglia;

function renderScorteStampe(negozio) {
  if (ScorteStampe.negozio !== negozio || ScorteStampe.stampe === null) {
    if (ScorteStampe.negozio !== negozio) ScorteStampe.stampe = null;
    if (!ScorteStampe.inCarico || ScorteStampe.negozio !== negozio) scorteCarica(negozio);
    return `<div id="scorte-root"><div class="empty-list">Caricamento…</div></div>`;
  }
  // Riaperta dopo un po': rilegge i pezzi scalati dagli ordini, intanto mostra quelli che ha
  if (!ScorteStampe.inCarico && Date.now() - ScorteStampe.caricatoAt > 60000) scorteCarica(negozio);
  return `<div class="scorte" id="scorte-root">${scorteHtml()}</div>`;
}

function scorteRender() {
  const root = document.getElementById('scorte-root');
  if (!root) return;
  root.classList.add('scorte');
  const fuoco = document.activeElement?.id;
  root.innerHTML = scorteHtml();
  if (fuoco) document.getElementById(fuoco)?.focus();
}

function scorteHtml() {
  if (ScorteStampe.errore) return `<div class="empty-list">${escapeHtml(ScorteStampe.errore)}</div>`;
  const tutte = scorteFamiglie();
  const q = ScorteStampe.cerca.trim().toLowerCase();
  const fam = tutte.filter(f => (!q || f.nome.toLowerCase().includes(q) || f.righe.some(r => r.colore.toLowerCase().includes(q)))
    && (ScorteStampe.filtro !== 'contate' || f.conteggia) && (ScorteStampe.filtro !== 'nuove' || f.nuovo));
  const contate = tutte.filter(f => f.conteggia).length;
  const sotto = tutte.reduce((t, f) => t + f.sotto, 0);
  const articoli = tutte.some(f => f.articolo);
  const dal = ScorteStampe.dal ? new Date(ScorteStampe.dal).toLocaleDateString('it-IT', { day: 'numeric', month: 'short', year: 'numeric' }) : null;
  return `
    <div class="scorte-testa">
      <div class="search-box"><input type="text" id="scorte-cerca" placeholder="Cerca prodotto o colore" value="${escapeHtml(ScorteStampe.cerca)}"
        oninput="ScorteStampe.cerca = this.value; scorteRender()" aria-label="Cerca prodotto o colore"></div>
      <div class="scorte-filtri" role="tablist" aria-label="Filtro">
        ${Object.entries(SCORTE_FILTRI).map(([k, v]) => `<button type="button" role="tab" aria-selected="${ScorteStampe.filtro === k}"
          class="chip-btn ${ScorteStampe.filtro === k ? 'is-on' : ''}" onclick="ScorteStampe.filtro = '${k}'; scorteRender()">${v}</button>`).join('')}
      </div>
    </div>
    <p class="scorte-info">${contate} su ${tutte.length} da contare${sotto ? ` · <b class="scorte-rosso">${sotto} sotto soglia</b>` : ''}${dal ? ` · venduti dal ${dal}` : ''}.
      ${articoli ? 'Spunta gli articoli da contare: da quel momento li scalano gli ordini pagati di tutti i siti e gli ordini del gestionale (anche da Kamon).'
                 : 'Spunta le stampe da contare: da quel momento ogni ordine pagato scala i pezzi.'}</p>
    <div class="scorte-tabella" role="table" aria-label="Scorte">
      <div class="scorte-tr scorte-th" role="row"><span role="columnheader">${articoli ? 'Articolo' : 'Stampa'}</span><span role="columnheader">Pezzi</span>
        <span role="columnheader">Soglia</span><span role="columnheader">${articoli ? 'Pezzi per arrivo' : 'Pezzi per file'}</span>
        <span role="columnheader">${articoli ? '' : 'File sul NAS (dentro DATI)'}</span><span role="columnheader"></span></div>
      ${fam.map(scorteFamigliaHtml).join('') || '<div class="empty-list">Nessuna stampa</div>'}
    </div>`;
}

// Una famiglia: con un colore solo sta su una riga; con più colori/taglie, una riga per ciascuno sotto il nome
function scorteFamigliaHtml(f) {
  const id = 'sf-' + scorteChiave(f.nome);
  const colori = f.righe.filter(r => r.colore).length;
  const singola = f.righe.length === 1 && !f.righe[0].colore;
  const nome = `
      <span role="cell" class="scorte-fam-nome">
        <label class="check-inline scorte-check"><input type="checkbox" id="${id}" ${f.conteggia ? 'checked' : ''}
          onchange="scorteConteggia(${escapeHtml(JSON.stringify(f.nome))}, this.checked)"><span class="scorte-nome">${escapeHtml(f.nome)}</span></label>
        ${f.nuovo ? '<span class="chip chip-muted">nuovo</span>' : ''}
        <span class="scorte-meta">${colori ? `${colori} ${f.articolo ? (colori === 1 ? 'taglia' : 'taglie') : f.righe[0].regola === 'bandiere' ? (colori === 1 ? 'bandiera' : 'bandiere') : (colori === 1 ? 'colore' : 'colori')} · ` : ''}${f.venduti} vendut${f.venduti === 1 ? 'o' : 'i'}</span>
      </span>`;
  if (singola) return `<div class="scorte-fam ${f.conteggia ? 'is-on' : ''}">${scorteRigaHtml(f.righe[0], nome, f.conteggia)}</div>`;
  return `
    <div class="scorte-fam ${f.conteggia ? 'is-on' : ''}">
      <div class="scorte-tr" role="row">${nome}</div>
      ${f.conteggia ? f.righe.map(r => scorteRigaHtml(r, `<span role="cell" class="scorte-colore">${escapeHtml(r.colore || '—')}${r.capi?.length
        ? ` <span class="scorte-meta">su ${escapeHtml(r.capi.map(c => c.toLowerCase()).join(', '))}</span>` : ''}</span>`, true)).join('') : ''}
    </div>`;
}

// Riga dei pezzi; prima = la cella iniziale (nome della famiglia o colore). Senza spunta niente campi.
function scorteRigaHtml(r, prima, campi) {
  if (!campi) return `<div class="scorte-tr" role="row">${prima}</div>`;
  const campo = (k, tipo, extra = '') => `<input class="form-input scorte-in scorte-in-${k}" id="sr-${r.id}-${k}" type="${tipo}" ${extra}
    value="${r[k] == null ? '' : escapeHtml(String(r[k]))}" ${k === 'file' && r.file ? `title="${escapeHtml(r.file)}"` : ''} aria-label="${k}" onchange="scorteSalva('${r.id}', '${k}', this.value)">`;
  let stato = '';
  if (r.ristampa_at) stato = `<span class="scorte-stato is-giallo" title="Caricato in 1. Stampare/01 - Ordini Siti">In Stampare dal ${new Date(r.ristampa_at).toLocaleDateString('it-IT', { day: 'numeric', month: 'short' })}</span>`;
  else if (scorteSotto(r)) stato = `<span class="scorte-stato is-rosso">${r.file || scorteArticolo(r) ? 'Sotto soglia' : 'Sotto soglia, manca il file'}</span>`;
  if (r.file && r.file_ok === false) stato += `<span class="scorte-stato is-rosso">File non trovato</span>`;
  return `
    <div class="scorte-tr ${scorteSotto(r) ? 'is-sotto' : ''}" role="row">
      ${prima}
      <span role="cell" data-label="Pezzi">${campo('quantita', 'number', 'inputmode="numeric" step="1"')}</span>
      <span role="cell" data-label="Soglia">${r.regola === 'bandiere' ? '<span class="scorte-richiesta" title="Se un ordine la vuole e non c\'è, il file va subito in 1. Stampare">su richiesta</span>'
        : campo('soglia', 'number', 'inputmode="numeric" step="1" min="0" placeholder="—"')}</span>
      <span role="cell" data-label="${scorteArticolo(r) ? 'Pezzi per arrivo' : 'Pezzi per file'}">${campo('pezzi_file', 'number', 'inputmode="numeric" step="1" min="1" placeholder="—"')}</span>
      ${scorteArticolo(r) ? '<span role="cell" class="scorte-vuota"></span>' : `<span role="cell" data-label="File sul NAS">${campo('file', 'text', 'placeholder="Percorso del file" spellcheck="false"')}</span>`}
      <span role="cell" class="scorte-azioni">${r.pezzi_file ? `<button type="button" class="btn btn-secondary scorte-ristampa"
        title="${scorteArticolo(r) ? 'Merce arrivata' : 'Ristampa arrivata'}: aggiunge ${r.pezzi_file} pezzi" onclick="scorteSalva('${r.id}', 'aggiungi', ${r.pezzi_file})">+${r.pezzi_file}</button>` : ''}${stato}</span>
    </div>`;
}

const scorteChiave = (s) => s.toLowerCase().normalize('NFD').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

async function scorteConteggia(nome, on) {
  const { data, error } = await supabaseClient.rpc('tc_stampe_conteggia', { p_store: ScorteStampe.negozio, p_famiglia: nome, p_on: on });
  if (error || !data?.success) { showToast(`Non salvato: ${error?.message || data?.error}`, 'error'); return scorteRender(); }
  for (const r of ScorteStampe.stampe) if (r.famiglia === nome) { r.conteggia = on; r.nuovo = false; }
  scorteRender();
}

async function scorteSalva(id, campo, valore) {
  const v = typeof valore === 'string' ? valore.trim() : valore;
  if (['quantita', 'soglia', 'pezzi_file', 'aggiungi'].includes(campo) && v !== '' && !/^-?\d+$/.test(String(v))) {
    showToast('Scrivi un numero intero', 'error');
    return scorteRender();
  }
  if (campo === 'quantita' && v === '') return scorteRender();
  const { data, error } = await supabaseClient.rpc('tc_stampe_salva', { p_id: id, p_campi: { [campo]: v } });
  if (error || !data?.success) { showToast(`Non salvato: ${error?.message || data?.error}`, 'error'); return scorteRender(); }
  const i = ScorteStampe.stampe.findIndex(r => r.id === id);
  if (i >= 0) ScorteStampe.stampe[i] = { ...ScorteStampe.stampe[i], ...data.stampa };
  if (campo === 'aggiungi') showToast(`Aggiunti ${v} pezzi`);
  scorteRender();
}
