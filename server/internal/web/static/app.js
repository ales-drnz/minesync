/* MineSync Hub — dashboard (vanilla JS, nessuna dipendenza) */
"use strict";

const $ = (sel, el = document) => el.querySelector(sel);
const main = $("#main");
let ME = null;
let SSE = null;
let route = { page: "home" };
let DNS_ZONE = ""; // zona del DNS interno dell'hub (es. "internal"); "" se disattivo
let DENIED = false; // pagina "accesso negato" mostrata
let CONN_ON = false; // stato dello stream SSE, per ridisegnare la pillola al cambio lingua

/* ---------- i18n ----------
   Dizionario per lingua con chiavi stabili. t(id, vars) sostituisce {nome};
   tn(id, n, vars) sceglie id.one / id.other; tx(id, vars) restituisce un
   array di testo e nodi, per i messaggi con un elemento (es. <b>) in mezzo.
   Lingua: localStorage "minesync.lang", poi navigator.languages, poi inglese. */
const I18N = {
  it: {
    "nav.home": "Server",
    "nav.dl": "Client",
    "theme.title": "Tema chiaro/scuro",
    "lang.title": "Lingua",
    "conn.online": "online",
    "conn.offline": "offline",
    "who.admin": "admin",
    "err.denied": "accesso negato",
    "copy": "copia",
    "toast.copied": "Copiato: {txt}",
    "toast.copyFail": "Copia non riuscita",
    "dlg.cancel": "Annulla",
    "dlg.confirm": "Conferma",
    "dlg.delete": "Elimina",
    "dlg.typeToConfirm": "Scrivi {name} per confermare",
    "addr.fixed": "indirizzo fisso",
    "addr.fixedHint": "Indirizzo unico per tutti: si salva una volta in Minecraft e risolve sempre all'host corrente.",
    "ev.push": "salvataggio",
    "ev.lock": "avvio",
    "ev.unlock": "stop",
    "ev.force": "force",
    "ev.restore": "restore",
    "ev.gc": "pulizia",
    "ev.space": "server",
    "denied.l1": "Non ti riconosco: questo hub autentica tramite la rete ZeroTier.",
    "denied.l2": "Apri la pagina dall'IP ZeroTier dell'hub, con un dispositivo autorizzato.",
    "denied.retry": "Riprova",
    "status.free": "LIBERO",
    "status.stale": "STALE · {owner}",
    "status.held": "IN GIOCO · {owner}",
    "home.online": "online",
    "home.servers.one": "server",
    "home.servers.other": "server",
    "home.openNow.one": "aperto ora",
    "home.openNow.other": "aperti ora",
    "home.playingNow": "in gioco ora",
    "home.yourServers": "I tuoi server",
    "home.newServer": "NUOVO SERVER",
    "home.activity": "Attività",
    "dl.forThisPc": "per questo pc",
    "dl.download": "Scarica",
    "dl.subtitle": "Il client per giocare ai server dell'hub.",
    "dl.otherPlatforms": "altre piattaforme",
    "dl.noBinaries": "Nessun binario sull'hub.",
    "dl.step1": "Avvialo — su Linux/macOS prima {cmd}.",
    "dl.step2": "Conferma l'indirizzo dell'hub, scegli il server e premi {key}.",
    "dl.step3": "Requisiti: rete ZeroTier + Java.",
    "new.title": "Nuovo server",
    "new.name": "Nome",
    "new.placeholder": "es. MioMondo",
    "new.create": "Crea",
    "new.created": "Server creato",
    "corrupt.head": "Region file danneggiati — verifica se serve un ripristino",
    "corrupt.confirmTitle": "Ripristinare la versione integra?",
    "corrupt.confirmText": "{path} verrà riportato all'ultima versione integra, in una nuova generazione. Il resto del mondo non cambia. Nessuno deve essere in gioco.",
    "corrupt.ok": "Ripristina",
    "corrupt.done": "File ripristinato",
    "corrupt.btn": "ripristina integro",
    "diff.more": "… e altri {n}",
    "diff.added": "aggiunti",
    "diff.changed": "modificati",
    "diff.removed": "rimossi",
    "diff.comparing": "confronto con #{n}…",
    "diff.none": "nessuna differenza",
    "diff.unavailable": "diff non disponibile: {err}",
    "reach.testing": "test porta in corso…",
    "reach.ok": "porta raggiungibile dai giocatori",
    "reach.bad": "porta bloccata: l'host deve consentirla nel firewall",
    "space.heartbeatLost": "heartbeat perso {ago}",
    "space.inSession": "in sessione da {dur}",
    "space.orDirect": "oppure IP diretto (adesso)",
    "space.joinAt": "entra in gioco su",
    "space.forceTitle": "Forzare il rilascio?",
    "space.forceStale": "Il lock di {owner} è scaduto. Il rilascio è sicuro.",
    "space.forceActive": "{owner} ha una sessione attiva: il rilascio forzato può fargli perdere i progressi non salvati.",
    "space.forceBtn": "Forza rilascio",
    "space.lockRemoved": "Lock rimosso",
    "space.noSession": "Nessuna sessione in corso.",
    "space.allServers": "tutti i server",
    "space.crumb": "Server /",
    "space.mods.one": "{n} mod",
    "space.mods.other": "{n} mod",
    "space.gen": "gen #{n}",
    "admin.head": "amministrazione",
    "admin.versions.one": "versione",
    "admin.versions.other": "versioni",
    "admin.onDisk": "su disco",
    "admin.retention": "Si conservano le ultime 30 versioni: a ogni salvataggio la più vecchia oltre il limite viene eliminata subito.",
    "admin.deleteTitle": "Eliminare il server?",
    "admin.deleteText": "TUTTA la storia e i file di «{name}» verranno eliminati dall'hub. Irreversibile.",
    "admin.deleteAll": "Elimina tutto",
    "admin.deleted": "Server eliminato",
    "admin.deleteBtn": "Elimina",
    "gen.restoreOf": "⟲ restore di #{n}",
    "gen.defaultMsg": "salvataggio",
    "gen.damaged.one": "{n} danneggiato",
    "gen.damaged.other": "{n} danneggiati",
    "gen.files.one": "{n} file",
    "gen.files.other": "{n} file",
    "gen.zip": "scarica questa versione (zip)",
    "gen.restoreTitle": "Ripristinare #{n}?",
    "gen.restoreText": "Verrà creata una nuova generazione con il contenuto di #{n}. Nessuno deve essere in gioco.",
    "gen.restoreOk": "Ripristina",
    "gen.restored": "Ripristinato",
    "gen.restoreBtn": "restore",
    "gen.deleteTip": "elimina questa versione",
    "gen.deleteTitle": "Eliminare la versione #{n}?",
    "gen.deleteText": "La versione e i suoi file esclusivi verranno rimossi dall'hub. Irreversibile.",
    "gen.deleted": "Versione eliminata",
    "gen.empty": "Nessuna generazione: fai il primo push dal client.",
    "tab.overview": "Panoramica",
    "tab.players": "Giocatori ({n})",
    "tab.mods": "Mod ({n})",
    "tab.history": "Storia ({n})",
    "tab.admin": "Amministrazione",
    "diff.0": "pacifica",
    "diff.1": "facile",
    "diff.2": "normale",
    "diff.3": "difficile",
    "mode.0": "sopravvivenza",
    "mode.1": "creativa",
    "mode.2": "avventura",
    "mode.3": "spettatore",
    "world.title": "Mondo",
    "world.version": "versione",
    "world.difficulty": "difficoltà",
    "world.hardcore": "hardcore",
    "world.mode": "modalità",
    "world.age": "età mondo",
    "world.ageVal": "giorno {day} · {h}h di gioco",
    "world.spawn": "spawn",
    "world.seed": "seed",
    "srv.title": "Server",
    "srv.motd": "motd",
    "srv.maxPlayers": "max giocatori",
    "srv.pvp": "pvp",
    "srv.whitelist": "whitelist",
    "srv.viewDistance": "view distance",
    "srv.chunks.one": "{n} chunk",
    "srv.chunks.other": "{n} chunk",
    "yes": "sì",
    "no": "no",
    "srv.on": "attiva",
    "pl.whitelist": "whitelist",
    "pl.played": "gioco",
    "pl.deaths": "morti",
    "pl.mobs": "mob",
    "pl.walked": "percorsi",
    "mods.search": "cerca una mod…",
    "mods.none": "nessuna mod trovata",
    "mods.summary": "{count} mod · {size} — clicca per i dettagli",
    "mods.loading": "carico…",
    "mods.unavailable": "dettagli non disponibili",
    "mods.version": "versione ",
    "mods.by": "di {authors}",
    "mods.site": "sito ufficiale",
    "mods.license": "licenza: {license}",
    "mods.noMeta": "nessun metadato nel jar (libreria o coremod)",
    "stats.head": "statistiche",
    "stats.played": "ore in gioco",
    "stats.hosting": "ore di hosting",
    "stats.sessions.one": "{n} sessione registrata",
    "stats.sessions.other": "{n} sessioni registrate",
    "ago.s": "{n}s fa",
    "ago.m": "{n}m fa",
    "ago.h": "{n}h fa",
    "ago.d": "{n}g fa",
  },
  en: {
    "nav.home": "Servers",
    "nav.dl": "Client",
    "theme.title": "Light/dark theme",
    "lang.title": "Language",
    "conn.online": "online",
    "conn.offline": "offline",
    "who.admin": "admin",
    "err.denied": "access denied",
    "copy": "copy",
    "toast.copied": "Copied: {txt}",
    "toast.copyFail": "Copy failed",
    "dlg.cancel": "Cancel",
    "dlg.confirm": "Confirm",
    "dlg.delete": "Delete",
    "dlg.typeToConfirm": "Type {name} to confirm",
    "addr.fixed": "fixed address",
    "addr.fixedHint": "One address for everyone: save it once in Minecraft and it always resolves to the current host.",
    "ev.push": "save",
    "ev.lock": "start",
    "ev.unlock": "stop",
    "ev.force": "force",
    "ev.restore": "restore",
    "ev.gc": "cleanup",
    "ev.space": "server",
    "denied.l1": "I don't recognise you: this hub authenticates through the ZeroTier network.",
    "denied.l2": "Open this page from the hub's ZeroTier IP, on an authorised device.",
    "denied.retry": "Retry",
    "status.free": "FREE",
    "status.stale": "STALE · {owner}",
    "status.held": "IN GAME · {owner}",
    "home.online": "online",
    "home.servers.one": "server",
    "home.servers.other": "servers",
    "home.openNow.one": "open now",
    "home.openNow.other": "open now",
    "home.playingNow": "playing now",
    "home.yourServers": "Your servers",
    "home.newServer": "NEW SERVER",
    "home.activity": "Activity",
    "dl.forThisPc": "for this PC",
    "dl.download": "Download",
    "dl.subtitle": "The client for playing on the hub's servers.",
    "dl.otherPlatforms": "other platforms",
    "dl.noBinaries": "No binaries on the hub.",
    "dl.step1": "Run it — on Linux/macOS first {cmd}.",
    "dl.step2": "Confirm the hub address, pick a server and press {key}.",
    "dl.step3": "Requirements: ZeroTier network + Java.",
    "new.title": "New server",
    "new.name": "Name",
    "new.placeholder": "e.g. MyWorld",
    "new.create": "Create",
    "new.created": "Server created",
    "corrupt.head": "Damaged region files — check whether a restore is needed",
    "corrupt.confirmTitle": "Restore the intact version?",
    "corrupt.confirmText": "{path} will be rolled back to its last intact version, in a new generation. The rest of the world is unchanged. Nobody may be in game.",
    "corrupt.ok": "Restore",
    "corrupt.done": "File restored",
    "corrupt.btn": "restore intact",
    "diff.more": "… and {n} more",
    "diff.added": "added",
    "diff.changed": "changed",
    "diff.removed": "removed",
    "diff.comparing": "comparing with #{n}…",
    "diff.none": "no differences",
    "diff.unavailable": "diff unavailable: {err}",
    "reach.testing": "testing port…",
    "reach.ok": "port reachable by players",
    "reach.bad": "port blocked: the host must allow it in the firewall",
    "space.heartbeatLost": "heartbeat lost {ago}",
    "space.inSession": "in session for {dur}",
    "space.orDirect": "or direct IP (right now)",
    "space.joinAt": "join the game at",
    "space.forceTitle": "Force release?",
    "space.forceStale": "{owner}'s lock has expired. Releasing it is safe.",
    "space.forceActive": "{owner} has an active session: a forced release may lose their unsaved progress.",
    "space.forceBtn": "Force release",
    "space.lockRemoved": "Lock removed",
    "space.noSession": "No session in progress.",
    "space.allServers": "all servers",
    "space.crumb": "Servers /",
    "space.mods.one": "{n} mod",
    "space.mods.other": "{n} mods",
    "space.gen": "gen #{n}",
    "admin.head": "administration",
    "admin.versions.one": "version",
    "admin.versions.other": "versions",
    "admin.onDisk": "on disk",
    "admin.retention": "The last 30 versions are kept: on every save, the oldest one beyond the limit is deleted right away.",
    "admin.deleteTitle": "Delete the server?",
    "admin.deleteText": "ALL history and files of “{name}” will be deleted from the hub. This cannot be undone.",
    "admin.deleteAll": "Delete everything",
    "admin.deleted": "Server deleted",
    "admin.deleteBtn": "Delete",
    "gen.restoreOf": "⟲ restore of #{n}",
    "gen.defaultMsg": "save",
    "gen.damaged.one": "{n} damaged",
    "gen.damaged.other": "{n} damaged",
    "gen.files.one": "{n} file",
    "gen.files.other": "{n} files",
    "gen.zip": "download this version (zip)",
    "gen.restoreTitle": "Restore #{n}?",
    "gen.restoreText": "A new generation will be created with the contents of #{n}. Nobody may be in game.",
    "gen.restoreOk": "Restore",
    "gen.restored": "Restored",
    "gen.restoreBtn": "restore",
    "gen.deleteTip": "delete this version",
    "gen.deleteTitle": "Delete version #{n}?",
    "gen.deleteText": "The version and the files only it uses will be removed from the hub. This cannot be undone.",
    "gen.deleted": "Version deleted",
    "gen.empty": "No generations yet: make the first push from the client.",
    "tab.overview": "Overview",
    "tab.players": "Players ({n})",
    "tab.mods": "Mods ({n})",
    "tab.history": "History ({n})",
    "tab.admin": "Administration",
    "diff.0": "peaceful",
    "diff.1": "easy",
    "diff.2": "normal",
    "diff.3": "hard",
    "mode.0": "survival",
    "mode.1": "creative",
    "mode.2": "adventure",
    "mode.3": "spectator",
    "world.title": "World",
    "world.version": "version",
    "world.difficulty": "difficulty",
    "world.hardcore": "hardcore",
    "world.mode": "game mode",
    "world.age": "world age",
    "world.ageVal": "day {day} · {h}h played",
    "world.spawn": "spawn",
    "world.seed": "seed",
    "srv.title": "Server",
    "srv.motd": "motd",
    "srv.maxPlayers": "max players",
    "srv.pvp": "pvp",
    "srv.whitelist": "whitelist",
    "srv.viewDistance": "view distance",
    "srv.chunks.one": "{n} chunk",
    "srv.chunks.other": "{n} chunks",
    "yes": "yes",
    "no": "no",
    "srv.on": "on",
    "pl.whitelist": "whitelist",
    "pl.played": "played",
    "pl.deaths": "deaths",
    "pl.mobs": "mob kills",
    "pl.walked": "walked",
    "mods.search": "search mods…",
    "mods.none": "no mods found",
    "mods.summary": "{count} mods · {size} — click for details",
    "mods.loading": "loading…",
    "mods.unavailable": "details unavailable",
    "mods.version": "version ",
    "mods.by": "by {authors}",
    "mods.site": "official website",
    "mods.license": "licence: {license}",
    "mods.noMeta": "no metadata in the jar (library or coremod)",
    "stats.head": "statistics",
    "stats.played": "hours played",
    "stats.hosting": "hours hosting",
    "stats.sessions.one": "{n} session recorded",
    "stats.sessions.other": "{n} sessions recorded",
    "ago.s": "{n}s ago",
    "ago.m": "{n}m ago",
    "ago.h": "{n}h ago",
    "ago.d": "{n}d ago",
  },
};
const LANGS = ["it", "en"];
const LOCALES = { it: "it-IT", en: "en-GB" };

function detectLang() {
  let saved = null;
  try { saved = localStorage.getItem("minesync.lang"); } catch { /* storage bloccato */ }
  if (LANGS.includes(saved)) return saved;
  for (const l of navigator.languages || [navigator.language || ""]) {
    const base = String(l).toLowerCase().split("-")[0];
    if (LANGS.includes(base)) return base;
  }
  return "en";
}
let LANG = detectLang();
const locale = () => LOCALES[LANG];

function t(id, vars) {
  let s = I18N[LANG][id] ?? I18N.it[id] ?? id;
  if (vars) s = s.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k]) : m));
  return s;
}
// plurale: n è anche disponibile come {n}, già formattato nella lingua
function tn(id, n, vars = {}) {
  return t(id + (n === 1 ? ".one" : ".other"), { n: num(n), ...vars });
}
// come t, ma i valori possono essere nodi DOM: restituisce [testo, nodo, testo…]
function tx(id, vars) {
  const s = I18N[LANG][id] ?? I18N.it[id] ?? id;
  return s.split(/(\{\w+\})/).filter((p) => p !== "").map((p) => {
    const m = /^\{(\w+)\}$/.exec(p);
    return m && vars && m[1] in vars ? vars[m[1]] : p;
  });
}
function num(n, digits = 0) {
  return Number(n).toLocaleString(locale(), { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

/* ---------- icone (lucide, inline) ---------- */
const ICONS = {
  /* box NON è quello di lucide: il suo è una scatola, non un cubo (lati 8 contro
     10.67, obliqui a 32.5°). Questo è un cubo isometrico esatto — esagono
     regolare di circumraggio 10 centrato in (12,12), obliqui a 30°, i tre
     spigoli frontali a 120° che convergono nel centro. 8.66 = 10·√3/2.
     Stesso disegno di scripts/genicon (icona exe + .ico): tienili allineati. */
  box: `<path d="M12 2 20.66 7 20.66 17 12 22 3.34 17 3.34 7Z"/><path d="m3.34 7 8.66 5 8.66-5"/><path d="M12 12v10"/>`,
  users: `<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>`,
  history: `<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l4 2"/>`,
  activity: `<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>`,
  download: `<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>`,
  copy: `<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>`,
  server: `<rect width="20" height="8" x="2" y="2" rx="2"/><rect width="20" height="8" x="2" y="14" rx="2"/><line x1="6" x2="6.01" y1="6" y2="6"/><line x1="6" x2="6.01" y1="18" y2="18"/>`,
  clock: `<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>`,
  gamepad: `<line x1="6" x2="10" y1="11" y2="11"/><line x1="8" x2="8" y1="9" y2="13"/><line x1="15" x2="15.01" y1="12" y2="12"/><line x1="18" x2="18.01" y1="10" y2="10"/><path d="M17.32 5H6.68a4 4 0 0 0-3.978 3.59c-.006.052-.01.101-.017.152C2.604 9.416 2 14.456 2 16a3 3 0 0 0 3 3c1 0 1.5-.5 2-1l1.414-1.414A2 2 0 0 1 9.828 16h4.344a2 2 0 0 1 1.414.586L17 18c.5.5 1 1 2 1a3 3 0 0 0 3-3c0-1.545-.604-6.584-.685-7.258-.007-.05-.011-.1-.017-.152A4 4 0 0 0 17.32 5z"/>`,
  restore: `<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>`,
  trash: `<path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/>`,
  plus: `<path d="M5 12h14"/><path d="M12 5v14"/>`,
  chevron: `<polyline points="6 9 12 15 18 9"/>`,
  broom: `<path d="m13 11 9-9"/><path d="M14.6 12.6c.8.8.9 2 .2 2.8l-4.6 4.6c-4.4 4.4-8.4-.2-8.4-.2s-4.6-4 -.2-8.4l4.6-4.6c.8-.7 2-.6 2.8.2Z"/>`,
  folder: `<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>`,
  sun: `<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>`,
  moon: `<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>`,
  arrow: `<path d="m12 19-7-7 7-7"/><path d="M19 12H5"/>`,
  alert: `<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><path d="M12 9v4"/><path d="M12 17h.01"/>`,
  shield: `<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1Z"/>`,
};
function icon(name, size = 16) {
  const span = document.createElement("span");
  span.innerHTML = `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${ICONS[name] || ""}</svg>`;
  return span.firstChild;
}
$("#logo").append(icon("box", 19));

/* ---------- nav: tab + tema ---------- */
$("#tab-home").addEventListener("click", (e) => { e.preventDefault(); go({ page: "home" }); });
$("#tab-dl").addEventListener("click", (e) => { e.preventDefault(); go({ page: "dl" }); });
function markTab() {
  $("#tab-home").classList.toggle("active", route.page !== "dl");
  $("#tab-dl").classList.toggle("active", route.page === "dl");
}

function applyTheme() {
  const pref = localStorage.getItem("minesync.theme"); // "light" | "dark" | null (auto)
  if (pref) document.documentElement.dataset.theme = pref;
  else delete document.documentElement.dataset.theme;
  const dark = pref ? pref === "dark"
    : !window.matchMedia("(prefers-color-scheme: light)").matches;
  $("#theme-btn").replaceChildren(icon(dark ? "sun" : "moon", 15));
}
$("#theme-btn").addEventListener("click", () => {
  const cur = document.documentElement.dataset.theme ||
    (window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
  localStorage.setItem("minesync.theme", cur === "dark" ? "light" : "dark");
  applyTheme();
});
applyTheme();

/* ---------- lingua: testi statici dell'header + selettore IT/EN ----------
   index.html marca i testi con data-i18n (contenuto) e data-i18n-title
   (tooltip); qui si riscrivono a ogni cambio di lingua. */
function applyLang() {
  document.documentElement.lang = LANG;
  document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
  document.querySelectorAll("[data-i18n-title]").forEach((el) => {
    el.title = t(el.dataset.i18nTitle);
    el.setAttribute("aria-label", el.title);
  });
  document.querySelectorAll("#lang-sw button").forEach((b) => {
    const on = b.dataset.lang === LANG;
    b.classList.toggle("active", on);
    b.setAttribute("aria-pressed", on ? "true" : "false");
  });
  $("#conn-txt").textContent = t(CONN_ON ? "conn.online" : "conn.offline");
  setWho();
}
function setLang(l) {
  if (!LANGS.includes(l) || l === LANG) return;
  LANG = l;
  try { localStorage.setItem("minesync.lang", l); } catch { /* storage bloccato */ }
  applyLang();
  // ridisegno immediato della pagina corrente (anche con un diff aperto:
  // è un'azione esplicita dell'utente)
  // EventSource non può mandare header: la lingua va nella query, quindi
  // al cambio si riapre lo stream; render() ricarica anche il feed recente,
  // che l'hub restituisce già nella nuova lingua
  if (SSE) connectSSE();
  if (DENIED) viewDenied(); else if (ME) render();
}
document.querySelectorAll("#lang-sw button").forEach((b) => {
  b.addEventListener("click", () => setLang(b.dataset.lang));
});
function setWho() {
  $("#who").textContent = ME ? ME.name + (ME.admin ? " · " + t("who.admin") : "") : "";
}
applyLang();

/* ---------- API ----------
   Nessuna credenziale: l'hub ci riconosce dall'IP della rete ZeroTier.
   X-MineSync è obbligatorio sulle modifiche (protezione anti-CSRF). */
async function api(method, path, body) {
  // Accept-Language: l'hub risponde con gli errori nella lingua della UI
  const headers = { "X-MineSync": "web", "Accept-Language": LANG };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const res = await fetch("/api/v1" + path, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401) throw Object.assign(new Error(t("err.denied")), { status: 401 });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(data.error || res.statusText), { data, status: res.status });
  return data;
}

/* ---------- util ---------- */
function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined) el.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined) continue;
    el.append(c.nodeType ? c : document.createTextNode(c));
  }
  return el;
}
function toast(msg, err = false) {
  const el = h("div", { class: "toast" + (err ? " err" : "") }, msg);
  document.body.append(el);
  setTimeout(() => el.remove(), err ? 6000 : 3000);
}
function fmtTime(ts) {
  const d = new Date(ts);
  const today = new Date().toDateString() === d.toDateString();
  return today
    ? d.toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" })
    : d.toLocaleString(locale(), { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
}
function fmtBytes(n) {
  if (n > 1e9) return num(n / 1e9, 2) + " GB";
  if (n > 1e6) return num(n / 1e6, 1) + " MB";
  if (n > 1e3) return num(n / 1e3) + " kB";
  return num(n) + " B";
}
function ago(ts) {
  const s = Math.floor((Date.now() - new Date(ts)) / 1000);
  if (s < 60) return t("ago.s", { n: s });
  if (s < 3600) return t("ago.m", { n: Math.floor(s / 60) });
  if (s < 86400) return t("ago.h", { n: Math.floor(s / 3600) });
  return t("ago.d", { n: Math.floor(s / 86400) });
}
function copyText(txt) {
  // navigator.clipboard esiste solo in contesti "sicuri" (https/localhost):
  // su http://10.147.x.x serve il fallback con execCommand
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(txt).then(() => toast(t("toast.copied", { txt })));
    return;
  }
  const ta = h("textarea", { style: "position:fixed;opacity:0" }, txt);
  document.body.append(ta);
  ta.select();
  try {
    document.execCommand("copy");
    toast(t("toast.copied", { txt }));
  } catch { toast(t("toast.copyFail"), true); }
  ta.remove();
}
function confirmDialog(title, text, okLabel = t("dlg.confirm"), danger = false) {
  return new Promise((resolve) => {
    const dlg = h("dialog", {},
      h("h3", {}, title), h("p", {}, text),
      h("div", { class: "row" },
        h("button", { class: "ghost", onclick: () => { dlg.close(); resolve(false); } }, t("dlg.cancel")),
        h("button", { class: danger ? "danger" : "", onclick: () => { dlg.close(); resolve(true); } }, okLabel)));
    document.body.append(dlg);
    dlg.addEventListener("close", () => dlg.remove());
    dlg.showModal();
  });
}

// conferma distruttiva "a prova di errore": per procedere bisogna riscrivere
// esattamente il nome (es. del server) — il bottone resta bloccato finché non combacia.
function confirmByName(title, text, expected, okLabel = t("dlg.delete")) {
  return new Promise((resolve) => {
    const input = h("input", { placeholder: expected, autocomplete: "off", spellcheck: "false" });
    const ok = h("button", { class: "danger", disabled: "" }, icon("trash", 14), okLabel);
    const done = (v) => { dlg.close(); resolve(v); };
    input.addEventListener("input", () => {
      if (input.value.trim() === expected) ok.removeAttribute("disabled");
      else ok.setAttribute("disabled", "");
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && input.value.trim() === expected) done(true);
    });
    ok.addEventListener("click", () => { if (input.value.trim() === expected) done(true); });
    const dlg = h("dialog", {},
      h("h3", {}, title),
      h("p", {}, text),
      h("div", { class: "formgrid" },
        h("label", {}, tx("dlg.typeToConfirm", { name: h("b", {}, expected) })),
        input),
      h("div", { class: "row" },
        h("button", { class: "ghost", onclick: () => done(false) }, t("dlg.cancel")),
        ok));
    document.body.append(dlg);
    dlg.addEventListener("close", () => dlg.remove());
    dlg.showModal();
    input.focus();
  });
}

// indirizzo fisso: zerotier.<spazio>.<zona>. L'hub fa da DNS e lo risolve
// verso l'IP di chi hosta ADESSO — gli amici lo salvano una volta in Minecraft
// e non lo toccano più. Non è un proxy: il gioco resta diretto P2P.
function fixedAddrBox(sp) {
  if (!DNS_ZONE) return null;
  const addr = `zerotier.${sp.id}.${DNS_ZONE}`;
  return h("div", { class: "hostlist" },
    h("div", { class: "k" }, t("addr.fixed")),
    h("div", { class: "hostaddr primary" }, addr,
      h("button", { class: "ghost icon", title: t("copy"), onclick: () => copyText(addr) }, icon("copy", 14))),
    h("p", { class: "muted", style: "font-size:12.5px;margin-top:6px;line-height:1.5" },
      t("addr.fixedHint")));
}

/* ---------- eventi live ---------- */
function connectSSE() {
  if (SSE) SSE.close();
  SSE = new EventSource("/api/v1/events?stream=1&lang=" + LANG);
  SSE.onopen = () => { CONN_ON = true; $("#conn").className = "connpill on"; $("#conn-txt").textContent = t("conn.online"); };
  SSE.onerror = () => { CONN_ON = false; $("#conn").className = "connpill off"; $("#conn-txt").textContent = t("conn.offline"); };
  SSE.onmessage = (m) => {
    let e; try { e = JSON.parse(m.data); } catch { return; }
    const feed = $("#evfeed");
    if (feed) { feed.prepend(evRow(e, true)); if (feed.children.length > 100) feed.lastChild.remove(); }
    if (["lock", "unlock", "force", "push", "restore", "space"].includes(e.type) && canAutoRefresh()) render();
  };
}

// niente ridisegno automatico se l'utente sta leggendo un diff o scrivendo
function canAutoRefresh() {
  // niente ridisegno se l'utente sta leggendo un diff, un'anteprima mod o scrivendo
  if (document.querySelector(".gendiff") || document.querySelector(".moddetail")) return false;
  const a = document.activeElement;
  return !a || !["INPUT", "TEXTAREA", "SELECT"].includes(a.tagName);
}
const EV_TYPES = ["push", "lock", "unlock", "force", "restore", "gc", "space"];
// testo di un evento: msg arriva già nella lingua della richiesta (l'hub lo
// rende da key/args quando ci sono; ?lang= sullo stream SSE, Accept-Language
// sulla lista). Unico punto da cambiare se un giorno si renderà qui.
function evText(e) {
  return e.msg || "";
}
function evRow(e, flash = false) {
  // "alex ha pushato…" → attore in evidenza, resto del messaggio dopo
  let msg = evText(e);
  // nel feed la riga resta pulita: per i salvataggi togliamo la coda
  // "— <messaggio> (+a ~c −r)"; i dettagli stanno nella storia del server
  if (e.type === "push") {
    const d = msg.indexOf("—");
    if (d > 0) msg = msg.slice(0, d).trimEnd();
  }
  const i = msg.indexOf(" ");
  const actor = i > 0 ? msg.slice(0, i) : "";
  const rest = i > 0 ? msg.slice(i) : msg;
  return h("div", { class: "ev ev-" + e.type + (flash ? " flash" : "") },
    h("span", { class: "badge " + e.type }, EV_TYPES.includes(e.type) ? t("ev." + e.type) : e.type),
    h("span", { class: "msg" },
      actor ? h("b", {}, actor) : null, rest,
      e.space ? h("span", { class: "sp" }, e.space) : null),
    h("span", { class: "t" }, fmtTime(e.ts)));
}

/* i giocatori online cambiano senza generare eventi: poll leggero */
setInterval(() => {
  if (ME && canAutoRefresh() && (route.page === "home" || route.page === "space")) render();
}, 10000);

/* ---------- accesso negato ---------- */
function viewDenied() {
  DENIED = true;
  main.replaceChildren(h("div", { class: "login" },
    h("div", { class: "cube-big" }, icon("box", 52)),
    h("h1", {}, "MineSync Hub"),
    h("p", {}, t("denied.l1"), h("br", {}), t("denied.l2")),
    h("button", { onclick: () => { ME = null; DENIED = false; render(); } }, t("denied.retry"))));
  $("#who").textContent = "";
}

/* ---------- home ---------- */
function statusPill(sp) {
  if (!sp.lock) return h("span", { class: "status-pill free" }, h("span", { class: "dot" }), t("status.free"));
  if (sp.lockStale) return h("span", { class: "status-pill stale" }, h("span", { class: "dot" }), t("status.stale", { owner: sp.lock.owner }));
  return h("span", { class: "status-pill held" }, h("span", { class: "dot" }), t("status.held", { owner: sp.lock.owner }));
}

function sessDur(since) {
  const s = Math.max(0, Math.floor((Date.now() - new Date(since)) / 1000));
  if (s >= 3600) return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m";
  return Math.floor(s / 60) + "m " + (s % 60) + "s";
}

/* le durate di sessione scorrono live: ogni elemento con data-since si
   aggiorna da solo una volta al secondo, senza ridisegnare la pagina */
setInterval(() => {
  document.querySelectorAll("[data-since]").forEach((el) => {
    el.textContent = sessDur(el.dataset.since);
  });
}, 1000);
function liveDur(since) {
  return h("b", { "data-since": since }, sessDur(since));
}

/* fmtHours: secondi → "12h 30m" / "45m" per le statistiche */
function fmtHours(sec) {
  const m = Math.floor(sec / 60);
  if (m < 60) return m + "m";
  return Math.floor(m / 60) + "h " + (m % 60) + "m";
}

/* stat tile per la statbar globale della home */
function statTile(ic, big, lbl) {
  return h("div", { class: "stat" }, icon(ic, 22),
    h("div", {}, h("div", { class: "big" }, big), h("div", { class: "lbl" }, lbl)));
}

/* avatar del server: il server-icon.png del mondo, o il cubo se manca */
function spaceIcon(id, size = 38) {
  const wrap = h("span", { class: "space-ico" });
  const img = h("img", { src: `/api/v1/spaces/${id}/icon`, alt: "", width: size, height: size });
  img.addEventListener("error", () => wrap.replaceChildren(icon("box", Math.round(size * 0.58))));
  wrap.append(img);
  return wrap;
}

async function viewHome() {
  const [spaces, events] = await Promise.all([
    api("GET", "/spaces"), api("GET", "/events?limit=40"),
  ]);

  const cards = spaces.map((sp) => {
    const online = sp.lock && !sp.lockStale;
    const players = (online && sp.lock.players) || [];
    return h("div", { class: "card clickable", onclick: () => go({ page: "space", id: sp.id }) },
      h("div", { class: "space-head" },
        spaceIcon(sp.id),
        h("span", { class: "space-name" }, sp.name),
        h("span", { class: "spacer" }),
        h("span", { class: "chip green" }, icon("gamepad", 12), "#" + sp.head)),
      statusPill(sp),
      // conteggio e durata della sessione: i NOMI dei giocatori stanno
      // nella pagina del server, qui solo il totale
      online ? h("div", { class: "meta-row" },
        h("span", { class: "m" }, icon("users", 14), h("b", {}, num(players.length)), t("home.online")),
        h("span", { class: "m" }, icon("clock", 14), liveDur(sp.lock.since))) : null);
  });

  // riga di statistiche globali in cima
  const onlineNow = spaces.filter((s) => s.lock && !s.lockStale).length;
  const playersNow = spaces.reduce((n, s) => n + ((s.lock && !s.lockStale && s.lock.players?.length) || 0), 0);
  const statbar = h("div", { class: "statbar" },
    statTile("server", num(spaces.length), tn("home.servers", spaces.length)),
    statTile("gamepad", num(onlineNow), tn("home.openNow", onlineNow)),
    statTile("users", num(playersNow), t("home.playingNow")));

  // due colonne: i server usano lo spazio grande, l'attività è una sidebar
  // che scorre per conto suo (sotto i 900px tornano impilate)
  main.replaceChildren(
    statbar,
    h("div", { class: "home-cols" },
      h("div", {},
        h("h2", {}, icon("server", 15), t("home.yourServers")),
        h("div", { class: "grid" }, cards,
          ME?.admin ? h("div", { class: "card clickable", onclick: newSpaceDialog, style: "display:flex;align-items:center;justify-content:center;gap:8px;color:var(--muted);min-height:100px" },
            icon("plus", 16), t("home.newServer")) : null)),
      h("div", {},
        h("h2", {}, icon("activity", 15), t("home.activity")),
        h("div", { class: "events", id: "evfeed" }, events.slice().reverse().map((e) => evRow(e))))));
}

/* ---------- tab client (download) ---------- */
const OS_LABEL = [
  ["minesync-windows", "Windows"],
  ["minesync-linux", "Linux"],
  ["minesync-darwin", "macOS"],
];
function myOS() {
  const ua = navigator.userAgent;
  if (/Windows/i.test(ua)) return "Windows";
  if (/Mac/i.test(ua)) return "macOS";
  if (/Linux|X11/i.test(ua)) return "Linux";
  return "";
}
function dlCard(f, primary) {
  let os = f.name;
  for (const [pre, label] of OS_LABEL) if (f.name.startsWith(pre)) os = label;
  return h("div", { class: "dlcard" + (primary ? " primary" : "") },
    icon("download", primary ? 34 : 22),
    h("div", { class: "os" }, os),
    primary ? h("span", { class: "chip green" }, t("dl.forThisPc")) : null,
    h("div", { class: "fn" }, f.size ? fmtBytes(f.size) : ""),
    h("a", { class: "btn-cta", href: "/dl/" + f.name, download: "" }, t("dl.download")));
}
async function viewDl() {
  const dl = await api("GET", "/dl");
  const mine = myOS();
  const files = dl.files || [];
  const primary = files.find((f) => {
    for (const [pre, label] of OS_LABEL) if (f.name.startsWith(pre) && label === mine) return true;
    return false;
  });
  const others = files.filter((f) => f !== primary);
  // NB: replaceChildren converte i null in testo "null" — vanno filtrati
  main.replaceChildren(...[
    h("div", { class: "pixel-title" }, "Minesync"),
    h("p", { style: "text-align:center;color:var(--muted)" }, t("dl.subtitle")),
    primary ? h("div", { class: "dlhero" }, dlCard(primary, true)) : null,
    others.length ? h("div", { class: "dlothers" },
      h("div", { class: "k" }, t("dl.otherPlatforms")),
      h("div", { class: "dlgrid" }, others.map((f) => dlCard(f, false)))) : null,
    !files.length ? h("p", { class: "muted", style: "text-align:center" }, t("dl.noBinaries")) : null,
    h("ol", { class: "dlsteps" },
      h("li", {}, tx("dl.step1", { cmd: h("b", {}, "chmod +x minesync") })),
      h("li", {}, tx("dl.step2", { key: h("b", {}, "G") })),
      h("li", {}, t("dl.step3"))),
  ].filter(Boolean));
}

function newSpaceDialog() {
  const name = h("input", { placeholder: t("new.placeholder") });
  const dlg = h("dialog", {},
    h("h3", {}, t("new.title")),
    h("div", { class: "formgrid" }, h("label", {}, t("new.name")), name),
    h("div", { class: "row" },
      h("button", { class: "ghost", onclick: () => dlg.close() }, t("dlg.cancel")),
      h("button", {
        onclick: async () => {
          try {
            await api("POST", "/spaces", { name: name.value, profile: "minecraft" });
            dlg.close(); toast(t("new.created")); render();
          } catch (e) { toast(e.message, true); }
        },
      }, t("new.create"))));
  document.body.append(dlg);
  dlg.addEventListener("close", () => dlg.remove());
  dlg.showModal();
}

/* ---------- diff tra generazioni ---------- */
async function genDiff(id, n) {
  const cur = await api("GET", `/spaces/${id}/generations/${n}`);
  let prev = { files: {} };
  if (cur.parent > 0) {
    try { prev = await api("GET", `/spaces/${id}/generations/${cur.parent}`); } catch { /* potata dal GC */ }
  }
  const added = [], changed = [], removed = [];
  for (const [p, m] of Object.entries(cur.files || {})) {
    const old = (prev.files || {})[p];
    if (!old) added.push([p, m.s]);
    else if (old.h !== m.h) changed.push([p, m.s]);
  }
  for (const p of Object.keys(prev.files || {})) {
    if (!(cur.files || {})[p]) removed.push([p, 0]);
  }
  const sortP = (a, b) => a[0].localeCompare(b[0]);
  added.sort(sortP); changed.sort(sortP); removed.sort(sortP);
  return { added, changed, removed };
}

// riquadro dei region file danneggiati in una generazione, con il ripristino
// chirurgico della versione integra (solo admin)
function corruptSection(id, g) {
  const box = h("div", { class: "corruptbox" },
    h("div", { class: "ch" }, icon("alert", 13),
      t("corrupt.head")));
  for (const path of g.corrupt) {
    box.append(h("div", { class: "crow" },
      h("span", { class: "cp" }, path),
      ME?.admin ? h("button", {
        class: "ghost", onclick: async () => {
          const ok = await confirmDialog(t("corrupt.confirmTitle"),
            t("corrupt.confirmText", { path }), t("corrupt.ok"));
          if (!ok) return;
          try { await api("POST", `/spaces/${id}/restore-file`, { path }); toast(t("corrupt.done")); render(); }
          catch (e) { toast(e.message, true); }
        },
      }, icon("shield", 13), t("corrupt.btn")) : null));
  }
  return box;
}

function diffSection(box, title, cls, sign, list) {
  if (!list.length) return;
  box.append(h("div", { class: "dh" }, `${title} (${num(list.length)})`));
  const cap = 120;
  for (const [p, size] of list.slice(0, cap)) {
    box.append(h("div", { class: "f " + cls }, `${sign} ${p} `,
      size ? h("span", { class: "size" }, fmtBytes(size)) : null));
  }
  if (list.length > cap) box.append(h("div", { class: "f" }, t("diff.more", { n: num(list.length - cap) })));
}

// riga esito raggiungibilità porta (test fatto dall'hub sull'host corrente)
function reachRow(sp) {
  const lk = sp.lock;
  if (!lk || sp.lockStale || !lk.ready) return null;
  if (lk.reachable === undefined || lk.reachable === null) {
    return h("div", { class: "reach test" }, icon("clock", 13), t("reach.testing"));
  }
  return lk.reachable
    ? h("div", { class: "reach ok" }, icon("shield", 13), t("reach.ok"))
    : h("div", { class: "reach bad" }, icon("alert", 13), t("reach.bad"));
}

/* ---------- pagina progetto ---------- */
async function viewSpace(id) {
  const [sp, gens, stats, world, gamers, modsData] = await Promise.all([
    api("GET", "/spaces/" + id), api("GET", `/spaces/${id}/generations?limit=50`),
    api("GET", `/spaces/${id}/stats`).catch(() => null),
    api("GET", `/spaces/${id}/world`).catch(() => null),
    api("GET", `/spaces/${id}/players`).catch(() => []),
    api("GET", `/spaces/${id}/mods`).catch(() => null),
  ]);
  const online = sp.lock && !sp.lockStale;
  const players = (online && sp.lock.players) || [];
  const port = (sp.lock && sp.lock.info && sp.lock.info.port) || "25565";

  // --- riquadro stato/lock ---
  const lockCard = h("div", { class: "card" },
    statusPill(sp),
    sp.lock ? h("div", { class: "meta-row" },
      h("span", { class: "m" }, icon("clock", 14), sp.lockStale
        ? t("space.heartbeatLost", { ago: ago(sp.lock.lastBeat) })
        : h("span", {}, tx("space.inSession", { dur: liveDur(sp.lock.since) })))) : null,
    players.length ? h("div", { class: "players" },
      players.map((p) => h("span", { class: "player" }, p))) : null,
    // esito del test porta fatto dall'hub (solo a server avviato)
    reachRow(sp),
    // indirizzo fisso: sempre visibile (anche offline), è quello da salvare
    fixedAddrBox(sp),
    online && sp.lock.info?.host ? h("div", { class: "hostlist" },
      h("div", { class: "k" }, t(DNS_ZONE ? "space.orDirect" : "space.joinAt")),
      // solo l'indirizzo ZeroTier (il primo: il client li ordina ZT per primo)
      (() => {
        const addr = sp.lock.info.host.split(",")[0].trim() + ":" + port;
        return h("div", { class: "hostaddr" }, addr,
          h("button", { class: "ghost icon", title: t("copy"), onclick: () => copyText(addr) }, icon("copy", 14)));
      })()) : null,
    sp.lock ? h("div", { class: "row", style: "margin-top:14px" },
      h("button", {
        class: "danger",
        onclick: async () => {
          const ok = await confirmDialog(t("space.forceTitle"),
            t(sp.lockStale ? "space.forceStale" : "space.forceActive", { owner: sp.lock.owner }),
            t("space.forceBtn"), true);
          if (!ok) return;
          try { await api("DELETE", `/spaces/${id}/lock?force=1`); toast(t("space.lockRemoved")); render(); }
          catch (e) { toast(e.message, true); }
        },
      }, t("space.forceBtn"))) : null,
    !sp.lock ? h("p", { class: "muted", style: "margin-top:12px;font-size:13.5px" }, t("space.noSession")) : null);

  // --- riquadro amministrazione (le esclusioni sono gestite internamente,
  //     la pulizia delle versioni vecchie è automatica) ---
  const adminCard = !ME?.admin ? null : h("div", { class: "card" },
    h("div", { class: "k", style: "color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.08em;margin-bottom:10px;font-weight:800" }, t("admin.head")),
    h("div", { class: "meta-row", style: "margin:0 0 10px" },
      h("span", { class: "m" }, icon("history", 14), h("b", {}, num(gens.length)), tn("admin.versions", gens.length)),
      sp.diskBytes ? h("span", { class: "m" }, icon("server", 14), h("b", {}, fmtBytes(sp.diskBytes)), t("admin.onDisk")) : null),
    h("p", { class: "muted", style: "font-size:13px;margin-bottom:12px" },
      t("admin.retention")),
    h("div", { class: "row" },
      h("button", {
        class: "danger",
        onclick: async () => {
          const ok = await confirmByName(t("admin.deleteTitle"),
            t("admin.deleteText", { name: sp.name }), sp.name, t("admin.deleteAll"));
          if (!ok) return;
          try { await api("DELETE", "/spaces/" + id); toast(t("admin.deleted")); go({ page: "home" }); }
          catch (e) { toast(e.message, true); }
        },
      }, icon("trash", 14), t("admin.deleteBtn"))));

  // --- classifica: chi gioca e chi hosta, dagli heartbeat dell'hub ---
  const statsCard = buildStatsCard(stats);

  // --- storia con diff espandibile ---
  // barra proporzionale al peso: si vede a colpo d'occhio quando il mondo cresce
  const maxBytes = Math.max(1, ...gens.map((g) => g.stats.bytes || 0));
  const genRows = [];
  for (const g of gens) {
    const row = h("div", { class: "gen" + (g.n === sp.head ? " head" : "") },
      h("span", { class: "n" }, "#" + g.n),
      h("div", {},
        h("div", {}, (g.restore ? t("gen.restoreOf", { n: g.restore }) : g.message || t("gen.defaultMsg")),
          g.n === sp.head ? h("span", { class: "chip green", style: "margin-left:8px" }, "HEAD") : null,
          g.corrupt?.length ? h("span", { class: "chip warn", style: "margin-left:8px", title: g.corrupt.join("\n") },
            icon("alert", 12), tn("gen.damaged", g.corrupt.length)) : null),
        h("div", { class: "meta" }, `${g.author} · ${fmtTime(g.ts)} · ${tn("gen.files", g.stats.files)} · ${fmtBytes(g.stats.bytes)}`),
        h("div", { class: "stats" },
          h("span", { class: "a" }, "+" + num(g.stats.added)), " ",
          h("span", { class: "c" }, "~" + num(g.stats.changed)), " ",
          h("span", { class: "r" }, "−" + num(g.stats.removed))),
        h("div", { class: "sizebar" },
          h("span", { style: `width:${Math.max(2, Math.round(100 * (g.stats.bytes || 0) / maxBytes))}%` }))),
      h("div", { class: "row" },
        h("a", {
          class: "ghost icon btnlike", title: t("gen.zip"),
          href: `/api/v1/spaces/${id}/generations/${g.n}/zip`,
          onclick: (ev) => ev.stopPropagation(),
        }, icon("download", 14)),
        g.n !== sp.head && ME?.admin ? h("button", {
          class: "ghost",
          onclick: async (ev) => {
            ev.stopPropagation();
            const ok = await confirmDialog(t("gen.restoreTitle", { n: g.n }),
              t("gen.restoreText", { n: g.n }), t("gen.restoreOk"));
            if (!ok) return;
            try { await api("POST", `/spaces/${id}/restore`, { gen: g.n }); toast(t("gen.restored")); render(); }
            catch (e) { toast(e.message, true); }
          },
        }, icon("restore", 14), t("gen.restoreBtn")) : null,
        g.n !== sp.head && ME?.admin ? h("button", {
          class: "danger icon", title: t("gen.deleteTip"),
          onclick: async (ev) => {
            ev.stopPropagation();
            const ok = await confirmDialog(t("gen.deleteTitle", { n: g.n }),
              t("gen.deleteText"), t("dlg.delete"), true);
            if (!ok) return;
            try { await api("DELETE", `/spaces/${id}/generations/${g.n}`); toast(t("gen.deleted")); render(); }
            catch (e) { toast(e.message, true); }
          },
        }, icon("trash", 14)) : null,
        icon("chevron", 16)));
    const holder = h("div", {}); // il diff si apre come estensione della riga
    row.addEventListener("click", async () => {
      if (holder.firstChild) { holder.replaceChildren(); row.classList.remove("open"); return; }
      row.classList.add("open");
      const box = h("div", { class: "gendiff" }, t("diff.comparing", { n: g.parent || "0" }));
      holder.replaceChildren(box);
      try {
        const d = await genDiff(id, g.n);
        box.replaceChildren();
        if (g.corrupt?.length) box.append(corruptSection(id, g));
        if (!d.added.length && !d.changed.length && !d.removed.length) {
          box.append(h("div", { class: "f" }, t("diff.none")));
        }
        diffSection(box, t("diff.added"), "add", "+", d.added);
        diffSection(box, t("diff.changed"), "chg", "~", d.changed);
        diffSection(box, t("diff.removed"), "del", "−", d.removed);
      } catch (e) {
        box.replaceChildren(h("div", { class: "f del" }, t("diff.unavailable", { err: e.message })));
      }
    });
    genRows.push(row, holder);
  }

  const lvl = world?.level;
  const historyPane = h("div", {}, genRows.length ? genRows
    : h("p", { class: "muted" }, t("gen.empty")));

  // sotto-schede: la vista server non è più un unico scroll, si mostra solo
  // la sezione attiva. L'ordine è fisso (memoria spaziale) e la scheda scelta
  // vive in route.tab, così un refresh in background non la resetta.
  const sections = [
    { key: "overview", label: t("tab.overview"), ic: "server",
      pane: h("div", { class: "grid" }, lockCard, worldCard(world), serverCard(world), statsCard) },
    gamers?.length ? { key: "players", label: t("tab.players", { n: num(gamers.length) }), ic: "users", pane: playersGrid(gamers) } : null,
    modsData?.count ? { key: "mods", label: t("tab.mods", { n: num(modsData.count) }), ic: "box", pane: modsSection(id, modsData) } : null,
    { key: "history", label: t("tab.history", { n: num(gens.length) }), ic: "history", pane: historyPane },
    adminCard ? { key: "admin", label: t("tab.admin"), ic: "trash", pane: adminCard } : null,
  ].filter(Boolean);

  let active = sections.some((s) => s.key === route.tab) ? route.tab : "overview";
  const panes = sections.map((s) => h("div", { class: "tabpane" + (s.key === active ? " active" : "") }, s.pane));
  const tabbar = h("div", { class: "subtabs" });
  const btns = sections.map((s, i) => {
    const b = h("button", { class: "subtab" + (s.key === active ? " active" : ""),
      onclick: () => {
        route.tab = s.key;
        btns.forEach((x, j) => x.classList.toggle("active", j === i));
        panes.forEach((p, j) => p.classList.toggle("active", j === i));
      } }, icon(s.ic, 13), s.label);
    return b;
  });
  tabbar.append(...btns);

  main.replaceChildren(
    h("div", { class: "toolbar" },
      h("button", { class: "ghost icon", title: t("space.allServers"), onclick: () => go({ page: "home" }) }, icon("arrow", 16)),
      spaceIcon(id, 30),
      h("span", { class: "crumb" }, t("space.crumb"), h("b", {}, sp.name)),
      // impronta del modpack nel breadcrumb: versione + numero mod
      lvl?.version ? h("span", { class: "chip" }, icon("box", 12), lvl.version) : null,
      modsData?.count ? h("span", { class: "chip" }, tn("space.mods", modsData.count)) : null,
      h("span", { class: "spacer" }),
      h("span", { class: "chip green" }, icon("history", 12), t("space.gen", { n: sp.head }))),
    tabbar,
    ...panes);
}

/* ---------- card mondo e server (da level.dat + server.properties) ---------- */
// difficoltà 0..3 ("diff.N") e modalità di gioco 0..3 ("mode.N"); valori
// sconosciuti restano numerici
const enumLabel = (prefix, v) => (I18N.it[prefix + v] !== undefined ? t(prefix + v) : String(v));

function kv(k, v) {
  return h("div", { class: "kvrow" }, h("span", { class: "kk" }, k), h("span", { class: "vv" }, v));
}

function worldCard(world) {
  const l = world?.level;
  if (!l) return null;
  const rows = [];
  if (l.version) rows.push(kv(t("world.version"), l.version));
  if (l.difficulty >= 0) rows.push(kv(t("world.difficulty"), (l.hardcore ? t("world.hardcore") + " · " : "") + enumLabel("diff.", l.difficulty)));
  rows.push(kv(t("world.mode"), enumLabel("mode.", l.gameType)));
  if (l.day) rows.push(kv(t("world.age"), t("world.ageVal", { day: num(l.day), h: num(Math.round(l.ageTicks / 20 / 3600)) })));
  if (l.spawn) rows.push(kv(t("world.spawn"), l.spawn.join(", ")));
  if (l.seed) rows.push(h("div", { class: "kvrow" }, h("span", { class: "kk" }, t("world.seed")),
    h("span", { class: "vv seed", onclick: () => copyText(l.seed), title: t("copy") }, l.seed, icon("copy", 12))));
  return h("div", { class: "card" },
    h("div", { class: "cardhead" }, icon("box", 14), l.name || t("world.title")), ...rows);
}

function serverCard(world) {
  const s = world?.server;
  if (!s) return null;
  const rows = [];
  if (s.motd) rows.push(kv(t("srv.motd"), s.motd));
  if (s.maxPlayers) rows.push(kv(t("srv.maxPlayers"), num(s.maxPlayers)));
  rows.push(kv(t("srv.pvp"), t(s.pvp ? "yes" : "no")));
  rows.push(kv(t("srv.whitelist"), t(s.whitelist ? "srv.on" : "no")));
  if (s.viewDistance) rows.push(kv(t("srv.viewDistance"), tn("srv.chunks", Number(s.viewDistance))));
  return h("div", { class: "card" },
    h("div", { class: "cardhead" }, icon("server", 14), t("srv.title")), ...rows);
}

/* ---------- sezione giocatori: identicon offline + stats reali ---------- */
// identicon deterministico dall'UUID: griglia 5x5 simmetrica colorata, SVG
// inline (nessun servizio esterno, coerente con "tutto in ZeroTier").
function identicon(uuid, size = 40) {
  let hash = 0;
  for (const ch of uuid) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
  const hue = hash % 360;
  const fg = `hsl(${hue} 55% 55%)`;
  let cells = "";
  for (let x = 0; x < 3; x++) for (let y = 0; y < 5; y++) {
    if ((hash >> (x * 5 + y)) & 1) {
      for (const cx of [x, 4 - x]) cells += `<rect x="${cx}" y="${y}" width="1" height="1"/>`;
    }
  }
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 5 5" shape-rendering="crispEdges"><g fill="${fg}">${cells}</g></svg>`;
  return h("img", { class: "identicon", width: size, height: size, alt: "", src: "data:image/svg+xml," + encodeURIComponent(svg) });
}

function playersGrid(gamers) {
  return h("div", { class: "pgrid" }, gamers.map((p) => {
    const hours = p.playTimeTicks ? (p.playTimeTicks / 20 / 3600) : 0;
    const km = p.walkCm ? (p.walkCm / 100000) : 0;
    return h("div", { class: "pcard" },
      h("div", { class: "phead" }, identicon(p.uuid),
        h("div", {},
          h("div", { class: "pname" }, p.name),
          h("div", { class: "pbadges" },
            p.op ? h("span", { class: "pbadge op" }, "OP") : null,
            p.whitelist ? h("span", { class: "pbadge wl" }, t("pl.whitelist")) : null))),
      h("div", { class: "pstats" },
        pstat(hours >= 1 ? num(hours) + "h" : num(Math.round(hours * 60)) + "m", t("pl.played")),
        pstat(num(p.deaths || 0), t("pl.deaths")),
        pstat(num(p.mobKills || 0), t("pl.mobs")),
        pstat(km >= 1 ? num(km) + "km" : num(Math.round(km * 1000)) + "m", t("pl.walked"))));
  }));
}
function pstat(v, k) {
  return h("div", { class: "pst" }, h("div", { class: "pv" }, v), h("div", { class: "pk" }, k));
}

/* ---------- sezione mod: lista + anteprima singola col sito ---------- */
function modsSection(id, data) {
  const wrap = h("div", { class: "modwrap" });
  const search = h("input", { class: "modsearch", placeholder: t("mods.search"), autocomplete: "off" });
  const list = h("div", { class: "modlist" });
  const rows = data.mods.map((m) => modRow(id, m));
  list.append(...rows);
  // il filtro legge data-search dal wrapper restituito da modRow: prima
  // leggeva data-name, che sta sull'elemento interno, quindi era undefined e
  // il gestore moriva sulla prima riga senza filtrare niente
  const nores = h("p", { class: "muted", style: "display:none;font-size:13px" }, t("mods.none"));
  search.addEventListener("input", () => {
    const q = search.value.trim().toLowerCase();
    let visibili = 0;
    rows.forEach((r) => {
      const ok = !q || (r.dataset.search || "").includes(q);
      r.style.display = ok ? "" : "none";
      if (ok) visibili++;
    });
    nores.style.display = visibili ? "none" : "";
  });
  wrap.append(
    h("p", { class: "muted", style: "margin-bottom:10px;font-size:13px" },
      t("mods.summary", { count: num(data.count), size: fmtBytes(data.totalBytes) })),
    search, nores, list);
  return wrap;
}

function modRow(id, m) {
  const holder = h("div", { class: "modbody" });
  const row = h("div", { class: "modrow", "data-name": m.name.toLowerCase() },
    h("img", { class: "modico", width: 28, height: 28, alt: "", loading: "lazy",
      src: `/api/v1/spaces/${id}/mods/${encodeURIComponent(m.file)}/icon`,
      onerror: (e) => { e.target.replaceWith(icon("box", 20)); } }),
    h("span", { class: "modname" }, m.name),
    h("span", { class: "modsize" }, fmtBytes(m.size)),
    icon("chevron", 15));
  // la chiave di ricerca sta sul WRAPPER, che è quello che il filtro scorre,
  // e comprende anche il nome del file: si cerca "nomemod" ma anche "0.8.12"
  const outer = h("div", { "data-search": (m.name + " " + m.file).toLowerCase() }, row, holder);
  let loaded = false;
  row.addEventListener("click", async () => {
    if (holder.firstChild) { holder.replaceChildren(); row.classList.remove("open"); return; }
    row.classList.add("open");
    if (!loaded) {
      holder.replaceChildren(h("div", { class: "moddetail" }, t("mods.loading")));
      try {
        const d = await api("GET", `/spaces/${id}/mods/${encodeURIComponent(m.file)}`);
        holder.replaceChildren(modDetail(d));
        loaded = true;
      } catch (e) { holder.replaceChildren(h("div", { class: "moddetail" }, t("mods.unavailable"))); }
    }
  });
  return outer;
}

function modDetail(d) {
  const box = h("div", { class: "moddetail" });
  if (d.version) box.append(h("div", { class: "mline" }, h("b", {}, t("mods.version")), d.version,
    d.loader ? h("span", { class: "chip", style: "margin-left:8px" }, d.loader) : null));
  if (d.authors) box.append(h("div", { class: "mline muted" }, t("mods.by", { authors: d.authors })));
  if (d.description) box.append(h("p", { class: "mdesc" }, d.description));
  const links = h("div", { class: "row", style: "margin-top:8px" });
  // solo link http(s): i metadati del jar non sono fidati (niente javascript:)
  if (d.homepage && /^https?:\/\//i.test(d.homepage)) links.append(h("a", { class: "btn-cta", href: d.homepage, target: "_blank", rel: "noopener noreferrer" },
    icon("download", 13), t("mods.site")));
  if (d.license) links.append(h("span", { class: "muted", style: "font-size:12px;align-self:center" }, t("mods.license", { license: d.license })));
  if (links.children.length) box.append(links);
  if (!d.version && !d.description) box.append(h("div", { class: "muted", style: "font-size:13px" }, t("mods.noMeta")));
  return box;
}

/* ---------- statistiche di gioco ---------- */
// classifica ore di gioco e di hosting, con mini-barre proporzionali.
function buildStatsCard(stats) {
  if (!stats) return null;
  const players = Object.entries(stats.players || {}).sort((a, b) => b[1].seconds - a[1].seconds);
  const hosts = Object.entries(stats.hosts || {}).sort((a, b) => b[1].seconds - a[1].seconds);
  if (!players.length && !hosts.length) return null;

  const rank = (list, cap) => {
    const max = Math.max(1, ...list.map(([, v]) => v.seconds));
    return list.slice(0, cap).map(([name, v]) =>
      h("div", { class: "rank" },
        h("span", { class: "rn" }, name),
        h("span", { class: "rbar" }, h("span", { style: `width:${Math.max(3, Math.round(100 * v.seconds / max))}%` })),
        h("span", { class: "rv" }, fmtHours(v.seconds))));
  };

  const sessions = (stats.sessions || []).length;
  return h("div", { class: "card" },
    h("div", { class: "k", style: "color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.08em;margin-bottom:10px;font-weight:800" }, t("stats.head")),
    players.length ? h("div", { class: "rankgroup" },
      h("div", { class: "rk" }, icon("users", 12), t("stats.played")), rank(players, 6)) : null,
    hosts.length ? h("div", { class: "rankgroup" },
      h("div", { class: "rk" }, icon("server", 12), t("stats.hosting")), rank(hosts, 4)) : null,
    sessions ? h("p", { class: "muted", style: "font-size:12px;margin-top:10px" },
      tn("stats.sessions", sessions)) : null);
}

/* ---------- router ---------- */
function go(r) { route = r; render(); }
async function render() {
  if (!ME) {
    try {
      ME = await api("GET", "/whoami"); // riconoscimento via IP ZeroTier
    } catch {
      return viewDenied();
    }
    if (!SSE) connectSSE();
    const st = await api("GET", "/status").catch(() => null);
    if (st) { $("#ver").textContent = "v" + st.version; DNS_ZONE = st.dnsZone || ""; }
  }
  setWho();
  markTab();
  try {
    if (route.page === "space") await viewSpace(route.id);
    else if (route.page === "dl") await viewDl();
    else await viewHome();
  } catch (e) {
    if (e.status !== 401) toast(e.message, true);
  }
}
render();
