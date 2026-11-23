/**
 * T&C Factory — Pagina dell'ordine aperta col QR del modulo d'ordine.
 *
 * Il PDF del modulo porta in alto a destra un QR con https://cs.pngs.it/dashboard.html?ordine=<id>.
 * Scansionato (fotocamera del telefono/iPad, o lettore di codici collegato), apre a tutto schermo:
 *   • le FASI dell'ordine, gli stessi pulsanti del gestionale (Pulsanti.toggle), grandi per il dito;
 *   • le BOZZE: il PDF «<numero> bozza.pdf» nella cartella del cliente, anno corrente, sul NAS (lo porta il
 *     Mac mini con le immagini delle pagine e un PDF leggero, sql/bozze-pdf-task.sql)
 *     e gli allegati dell'ordine;
 *   • il MODULO in lettura: si possono solo evidenziare le righe e scrivere le note di riga.
 * La vede chiunque sia registrato. Un lettore di codici (USB o Bluetooth, modalità tastiera) funziona
 * su qualsiasi pagina del gestionale: scrive l'indirizzo del QR + Invio, la pagina se ne accorge e apre l'ordine.
 */

const SchedaOrdine = {
  id: null,
  bozze: [],          // [{ nome, percorso, tipo, peso, url }]
  stato: undefined,   // { cartella, suggerito } dal Mac mini; undefined = non ancora controllato, 'errore'
  _carico: 0,

  // All'avvio del gestionale: ?ordine=<id> nell'indirizzo (QR scansionato con la fotocamera)
  avvia() {
    if (this._avviata) return;
    this._avviata = true;
    TCFactory.onUpdate(() => this._aggiorna());
    this._lettore();
    const id = new URLSearchParams(location.search).get('ordine');
    if (id) {
      history.replaceState(null, '', location.pathname + location.hash);   // ricaricando non si riapre
      this.apri(id);
    }
  },

  async apri(id) {
    const o = TCFactory.getOrderById(id);
    if (!o) { showToast(`Ordine ${id} non trovato`, 'error'); return; }
    this.id = id;
    this.bozze = []; this.stato = undefined;
    migrateModPreviewChecks(id);
    this.render();
    await this._caricaBozze(id);
  },

  chiudi() {
    this.id = null;
    document.getElementById('scheda-ordine')?.remove();
    document.body.classList.remove('so-aperta');
  },

  async _caricaBozze(id) {
    const giro = ++this._carico;
    try {
      const [b, st] = await Promise.all([
        supabaseClient.from('ordini_bozze').select('nome, percorso, tipo, peso, mtime, pagine').eq('order_id', id).order('mtime', { ascending: false }),
        supabaseClient.from('ordini_bozze_stato').select('cartella, suggerito').eq('order_id', id).maybeSingle(),
      ]);
      if (b.error) throw b.error;
      const righe = b.data || [];
      let link = {};
      if (righe.length) {
        const percorsi = righe.flatMap(r => [r.percorso, ...(r.pagine || [])]);
        const { data, error } = await supabaseClient.storage.from('bozze').createSignedUrls(percorsi, 3600);
        if (error) throw error;
        link = Object.fromEntries((data || []).map(x => [x.path, x.signedUrl]));
      }
      if (giro !== this._carico || this.id !== id) return;
      this.bozze = righe.map(r => ({ ...r, url: link[r.percorso] || '', pagineUrl: (r.pagine || []).map(p => link[p]).filter(Boolean) }));
      this.stato = st.data || undefined;
    } catch (e) {
      console.error('[bozze]', e);
      if (giro === this._carico) this.stato = 'errore';
    }
    if (this.id === id) this._rendiBozze();
  },

  // Dati cambiati (anche da altri): si ridisegna, ma non mentre si scrive una nota di riga
  _aggiorna() {
    if (!this.id || !document.getElementById('scheda-ordine')) return;
    if (document.activeElement?.closest?.('#scheda-ordine input, #scheda-ordine textarea')) return;
    if (!TCFactory.getOrderById(this.id)) { this.chiudi(); return; }
    this.render();
  },

  render() {
    const D = orderModuleData(this.id);
    if (!D) return;
    const o = D.order;
    let el = document.getElementById('scheda-ordine');
    const scroll = el?.querySelector('.so-corpo')?.scrollTop || 0;
    if (!el) {
      el = document.createElement('div');
      el.id = 'scheda-ordine';
      el.setAttribute('role', 'dialog');
      el.setAttribute('aria-modal', 'true');
      document.body.appendChild(el);
      document.body.classList.add('so-aperta');
    }
    const lav = modLavParti(o);
    el.className = 'so om';
    el.style.cssText = `--om-c:${D.colore};--om-fg:${D.inchiostro};`;
    el.innerHTML = `
      <header class="so-testa">
        <div class="so-intest">
          <div class="so-tipo">${escapeHtml(D.tipologia)}${D.isUrgent ? ' <span class="om-urg">Urgente</span>' : ''}</div>
          <div class="so-cliente"><strong>${escapeHtml(D.cliente)}</strong>${D.desc ? ` <span>— ${escapeHtml(D.desc)}</span>` : ''}</div>
          <div class="so-date">
            <span>Ordine <strong>${escapeHtml(o.id)}</strong></span>
            <span>Data <strong>${omDate(D.data)}</strong></span>
            <span>Scadenza <strong class="${omDeadlineClass(D.deadline)}">${omDate(D.deadline)}</strong></span>
          </div>
          ${lav.length ? `<div class="so-lav">${lav.map(t => `<span>${escapeHtml(t)}</span>`).join('')}</div>` : ''}
        </div>
        <button type="button" class="btn-icon so-chiudi" onclick="SchedaOrdine.chiudi()" aria-label="Chiudi">${Icons.x()}</button>
      </header>
      <div class="so-corpo">
        <section class="so-sez">
          <h3>Fasi</h3>
          ${this._fasi(o)}
        </section>
        <section class="so-sez" id="so-bozze">${this._bozzeHtml(o)}</section>
        <section class="so-sez so-modulo">
          <h3>Modulo d'ordine</h3>
          ${(o.orderModule?.rows || []).length ? omCorpoHtml(D, { approva: false }) : '<p class="so-vuoto">Modulo d\'ordine vuoto.</p>'}
        </section>
      </div>`;
    el.querySelector('.so-corpo').scrollTop = scroll;
  },

  _fasi(o) {
    const gruppi = Pulsanti.gruppi().filter(g => Pulsanti.visibili(o, g.id).length);
    if (!gruppi.length) return '<p class="so-vuoto">Nessuna fase per questo ordine.</p>';
    return gruppi.map(g => `
      <div class="so-gruppo">
        ${gruppi.length > 1 ? `<div class="so-gruppo-nome">${escapeHtml(g.nome)}</div>` : ''}
        <div class="so-fasi">
          ${Pulsanti.visibili(o, g.id).map(p => {
            const st = Pulsanti.stato(o, p);
            const bloccato = !st.done && !Pulsanti.cliccabile(o, p);
            const data = st.done ? st.date : st.mezzo ? st.mezzoDate : null;
            return `<button type="button" class="so-fase ${st.done ? 'is-fatto' : st.mezzo ? 'is-mezzo' : ''}" ${bloccato ? `disabled title="${escapeHtml(Pulsanti.motivo(p))}"` : ''}
                onclick="SchedaOrdine.fase('${escapeHtml(p.id)}')">
                <span class="so-fase-segno">${st.done ? '✓' : st.mezzo ? '◐' : ''}</span>
                <span class="so-fase-nome">${escapeHtml(Pulsanti.etichetta(o, p))}</span>
                ${data ? `<span class="so-fase-data">${TCFactory.formatDate(data)}</span>` : ''}
                ${bloccato ? `<span class="so-fase-data">${escapeHtml(Pulsanti.motivo(p))}</span>` : ''}
              </button>`;
          }).join('')}
        </div>
      </div>`).join('');
  },

  // Come il gestionale: clic = avanti (con passaggio intermedio giallo dove c'è); togliere una fase fatta chiede conferma
  async fase(pid) {
    const o = TCFactory.getOrderById(this.id);
    const p = Pulsanti.get(pid);
    if (!o || !p) return;
    const st = Pulsanti.stato(o, p);
    if (st.done && !(await uiConfirm(`Togliere "${Pulsanti.etichetta(o, p)}" da questo ordine?`, { ok: 'Togli' }))) return;
    await pulsanteToggle(o.id, pid, !st.done);
    this.render();
    if (!st.done) showToast(`${Pulsanti.nome(p)} · ${o.nome}`);
  },

  // Bozza = PDF «<numero> bozza.pdf» dal NAS: le sue pagine come immagini (tocco = PDF leggero a tutto schermo)
  _bozzeHtml(o) {
    const allegati = o.files || [];
    const nomeFile = `${o.id} bozza.pdf`;
    let stato = '';
    if (this.stato === 'errore') stato = 'Bozze non caricate: riprova.';
    else if (!this.bozze.length) stato = this.stato === undefined
      ? `Il Mac mini non ha ancora cercato la bozza di questo ordine (entro 5 minuti).`
      : `Manca la bozza: salva sul NAS <strong>${escapeHtml(nomeFile)}</strong>${this.stato.suggerito ? ` in <strong>${escapeHtml(this.stato.suggerito)}</strong>` : ' nella cartella del cliente, anno corrente'}.`;
    const bozza = (b) => `
      <div class="so-bozza-file">
        <a class="so-bozza-apri" href="${escapeHtml(b.url)}" target="_blank" rel="noopener">${escapeHtml(b.nome)} · apri PDF</a>
        ${b.pagineUrl.length ? `<div class="so-bozze">${b.pagineUrl.map((u, k) => `
          <a class="so-bozza" href="${escapeHtml(b.url)}#page=${k + 1}" target="_blank" rel="noopener" title="Pagina ${k + 1}">
            <img src="${escapeHtml(u)}" alt="Bozza, pagina ${k + 1}" loading="lazy">
          </a>`).join('')}</div>` : ''}
      </div>`;
    return `
      <h3>Bozze${this.bozze.length > 1 ? ` <span class="so-conta">${this.bozze.length}</span>` : ''}</h3>
      ${this.bozze.map(bozza).join('')}
      ${this.bozze.length && this.stato?.cartella ? `<p class="so-nota">Dal NAS: ${escapeHtml(this.stato.cartella)}</p>` : ''}
      ${stato ? `<p class="so-vuoto">${stato}</p>` : ''}
      ${allegati.length ? `<div class="so-allegati"><div class="so-gruppo-nome">Allegati dell'ordine</div>
        ${allegati.map((f, i) => `<button type="button" class="td-file" onclick="taskApriAllegato('${o.id}', ${i})">${f.type?.startsWith('image/') ? '🖼' : f.type === 'application/pdf' ? '📄' : '📎'} <span>${escapeHtml(f.name || 'Allegato')}</span></button>`).join('')}
      </div>` : ''}`;
  },
  _rendiBozze() {
    const s = document.getElementById('so-bozze');
    const o = TCFactory.getOrderById(this.id);
    if (s && o) s.innerHTML = this._bozzeHtml(o);
  },

  // Lettore di codici in modalità tastiera: caratteri a raffica + Invio. Riconosce "ordine=<id>" anche se la
  // tastiera dell'iPad è impostata diversa dal lettore e qualche simbolo arriva storto.
  _lettore() {
    let buf = '', ultimo = 0;
    document.addEventListener('keydown', (e) => {
      const ora = performance.now();
      if (e.key === 'Enter') {
        const m = buf.length >= 10 && /ordine\W{0,3}([A-Za-z0-9-]{2,40})\s*$/i.exec(buf);
        buf = '';
        if (m) { e.preventDefault(); e.stopPropagation(); this.apri(m[1]); }
        return;
      }
      if (e.key.length !== 1 || e.ctrlKey || e.metaKey || e.altKey) return;
      buf = ora - ultimo < 60 ? buf + e.key : e.key;   // una persona non scrive così veloce
      ultimo = ora;
      if (buf.length > 200) buf = buf.slice(-200);
    }, true);
  },
};
