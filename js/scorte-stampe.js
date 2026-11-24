/**
 * T&C Factory — Scorte delle stampe dei negozi (Brand → Bienjugado → Scorte stampe)
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
  aperte: new Set(),
  errore: null,
};

const SCORTE_FILTRI = { tutte: 'Tutte', contate: 'Da contare', nuove: 'Nuove' };

async function scorteCarica(negozio) {
  ScorteStampe.negozio = negozio;
  const { data, error } = await supabaseClient.rpc('tc_stampe_lista', { p_store: negozio });
  if (ScorteStampe.negozio !== negozio) return;
  if (error || !data?.success) {
    ScorteStampe.errore = error?.message || data?.error || 'Elenco non letto';
    ScorteStampe.stampe = [];
  } else {
    ScorteStampe.errore = null;
    ScorteStampe.stampe = data.stampe;
    ScorteStampe.dal = data.dal;
  }
  scorteRender();
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
    venduti: righe.reduce((t, r) => t + (r.venduti || 0), 0),
    sotto: righe.filter(scorteSotto).length,
  }));
}

const scorteSotto = (r) => r.conteggia && r.soglia != null && r.quantita <= r.soglia;

function renderScorteStampe(negozio) {
  if (ScorteStampe.negozio !== negozio || ScorteStampe.stampe === null) {
    if (ScorteStampe.negozio !== negozio) { ScorteStampe.stampe = null; ScorteStampe.aperte.clear(); }
    scorteCarica(negozio);
    return `<div class="glass-card page-card" id="scorte-root"><div class="empty-list">Caricamento…</div></div>`;
  }
  return `<div class="glass-card page-card scorte" id="scorte-root">${scorteHtml()}</div>`;
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
      Spunta le stampe da contare: da quel momento ogni ordine pagato scala i pezzi.</p>
    <ul class="scorte-lista">
      ${fam.map(scorteFamigliaHtml).join('') || '<li class="empty-list">Nessuna stampa</li>'}
    </ul>`;
}

function scorteFamigliaHtml(f) {
  const id = 'sf-' + scorteChiave(f.nome);
  const aperta = f.conteggia && (ScorteStampe.aperte.has(f.nome) || f.righe.length === 1 || f.sotto);
  const colori = f.righe.filter(r => r.colore).length;
  return `
    <li class="scorte-fam ${f.conteggia ? 'is-on' : ''}">
      <div class="scorte-fam-riga">
        <label class="check-inline scorte-check"><input type="checkbox" id="${id}" ${f.conteggia ? 'checked' : ''}
          onchange="scorteConteggia(${escapeHtml(JSON.stringify(f.nome))}, this.checked)"><span class="scorte-nome">${escapeHtml(f.nome)}</span></label>
        ${f.nuovo ? '<span class="chip chip-muted">nuovo</span>' : ''}
        <span class="scorte-meta">${colori ? `${colori} color${colori === 1 ? 'e' : 'i'} · ` : ''}${f.venduti} vendut${f.venduti === 1 ? 'o' : 'i'}</span>
        ${f.sotto ? `<span class="scorte-rosso scorte-meta">${f.sotto} sotto soglia</span>` : ''}
        ${f.conteggia && f.righe.length > 1 ? `<button type="button" class="btn btn-secondary scorte-apri" aria-expanded="${aperta}"
          onclick="scorteApri(${escapeHtml(JSON.stringify(f.nome))})">${aperta ? 'Chiudi' : 'Pezzi'}</button>` : ''}
      </div>
      ${aperta ? `<div class="scorte-tabella" role="table" aria-label="Pezzi di ${escapeHtml(f.nome)}">
        <div class="scorte-tr scorte-th" role="row"><span role="columnheader">Colore</span><span role="columnheader">Pezzi</span>
          <span role="columnheader">Soglia</span><span role="columnheader">Pezzi per file</span><span role="columnheader">File sul NAS (dentro DATI)</span><span role="columnheader"></span></div>
        ${f.righe.map(scorteRigaHtml).join('')}
      </div>` : ''}
    </li>`;
}

function scorteRigaHtml(r) {
  const campo = (k, tipo, extra = '') => `<input class="form-input scorte-in scorte-in-${k}" id="sr-${r.id}-${k}" type="${tipo}" ${extra}
    value="${r[k] == null ? '' : escapeHtml(String(r[k]))}" aria-label="${k}" onchange="scorteSalva('${r.id}', '${k}', this.value)">`;
  let stato = '';
  if (r.ristampa_at) stato = `<span class="scorte-stato is-giallo" title="Caricato in 1. Stampare/01 - Ordini Siti">In Stampare dal ${new Date(r.ristampa_at).toLocaleDateString('it-IT', { day: 'numeric', month: 'short' })}</span>`;
  else if (scorteSotto(r)) stato = `<span class="scorte-stato is-rosso">${r.file ? 'Sotto soglia' : 'Sotto soglia, manca il file'}</span>`;
  if (r.file && r.file_ok === false) stato += `<span class="scorte-stato is-rosso">File non trovato sul NAS</span>`;
  return `
    <div class="scorte-tr" role="row">
      <span role="cell" class="scorte-colore">${escapeHtml(r.colore || '—')}</span>
      <span role="cell" data-label="Pezzi">${campo('quantita', 'number', 'inputmode="numeric" step="1"')}</span>
      <span role="cell" data-label="Soglia">${campo('soglia', 'number', 'inputmode="numeric" step="1" min="0" placeholder="—"')}</span>
      <span role="cell" data-label="Pezzi per file">${campo('pezzi_file', 'number', 'inputmode="numeric" step="1" min="1" placeholder="—"')}</span>
      <span role="cell" data-label="File sul NAS">${campo('file', 'text', 'placeholder="Percorso del file" spellcheck="false"')}</span>
      <span role="cell" class="scorte-azioni">${r.pezzi_file ? `<button type="button" class="btn btn-secondary scorte-ristampa"
        title="Ristampa arrivata: aggiunge ${r.pezzi_file} pezzi" onclick="scorteSalva('${r.id}', 'aggiungi', ${r.pezzi_file})">+${r.pezzi_file}</button>` : ''}${stato}</span>
    </div>`;
}

const scorteChiave = (s) => s.toLowerCase().normalize('NFD').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

function scorteApri(nome) {
  if (ScorteStampe.aperte.has(nome)) ScorteStampe.aperte.delete(nome); else ScorteStampe.aperte.add(nome);
  scorteRender();
}

async function scorteConteggia(nome, on) {
  const { data, error } = await supabaseClient.rpc('tc_stampe_conteggia', { p_store: ScorteStampe.negozio, p_famiglia: nome, p_on: on });
  if (error || !data?.success) { showToast(`Non salvato: ${error?.message || data?.error}`, 'error'); return scorteRender(); }
  for (const r of ScorteStampe.stampe) if (r.famiglia === nome) { r.conteggia = on; r.nuovo = false; }
  if (on) ScorteStampe.aperte.add(nome);
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
