import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import { createExaminer } from "./examiner.js?v=1793870000";

const CFG = window.EXAM_CONFIG || {};
const TZ = CFG.TIME_ZONE || "Africa/Cairo";
const app = document.getElementById("app");
const nav = document.getElementById("topnav");
const SITE = location.origin + location.pathname;

let sb = null;
let session = null;
let cleanup = []; // functions to run when leaving a page

// ------------------------------------------------------------------ helpers
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const rich = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, "<b>$1</b>").replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\n/g, "<br>");
const fmtCairo = (iso, opts = {}) => iso ? new Intl.DateTimeFormat("en-GB", { timeZone: TZ, weekday: "short", day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", hour12: false, ...opts }).format(new Date(iso)) + " Cairo" : "—";
const num = (n) => (n === null || n === undefined) ? "—" : (Math.round(Number(n) * 100) / 100).toString();
function toast(msg, ms = 2800) { const t = document.getElementById("toast"); t.textContent = msg; t.hidden = false; clearTimeout(toast._t); toast._t = setTimeout(() => (t.hidden = true), ms); }
function errMsg(e) { const m = e?.message || e?.error_description || String(e); return m.replace(/^.*?:\s*(?=[A-Z])/, (x) => x.includes("JWT") ? x : ""); }
function go(hash) { if (location.hash === hash) render(); else location.hash = hash; }
async function rpc(name, params = {}) {
  const { data, error } = await sb.rpc(name, params);
  if (error) { if (/JWT|not authorized|Not authorized/i.test(error.message) && !session) go("#/login"); throw error; }
  return data;
}
function modal(html, { wide = false, onClose } = {}) {
  const root = document.getElementById("modal-root");
  root.innerHTML = `<div class="backdrop"><div class="modal ${wide ? "wide" : ""}" role="dialog" aria-modal="true">${html}</div></div>`;
  const close = () => { root.innerHTML = ""; onClose && onClose(); };
  root.querySelector(".backdrop").addEventListener("click", (e) => { if (e.target.classList.contains("backdrop")) close(); });
  return { el: root.querySelector(".modal"), close };
}
let isAdmin = false;
function setNav() {
  if (!session) { nav.innerHTML = ""; return; }
  nav.innerHTML = `<a href="#/">Exams</a>${isAdmin ? `<a href="#/examiner">Examiner</a>` : ""}<a href="#/account">Account</a>`;
}
async function refreshAdminFlag() {
  if (!session || !sb) { isAdmin = false; setNav(); return; }
  try {
    const { data } = await sb.rpc("admin_is_admin");
    isAdmin = !!(data && data.admin);
  } catch { isAdmin = false; }
  setNav();
}
const imgCache = new Map();
async function signedImage(path) {
  if (!path) return null;
  if (imgCache.has(path)) return imgCache.get(path);
  const { data, error } = await sb.storage.from("exam-images").createSignedUrl(path, 3600);
  if (error) return null;
  imgCache.set(path, data.signedUrl);
  return data.signedUrl;
}
async function attachImage(container, path) {
  if (!path) return;
  const url = await signedImage(path);
  if (!url) { container.innerHTML = `<div class="notice">Image could not be loaded.</div>`; return; }
  container.innerHTML = `<img class="qimg" alt="Question figure" src="${esc(url)}">`;
  container.querySelector("img").addEventListener("click", () => modal(`<img src="${esc(url)}" alt="">`, { wide: true }));
}

// ------------------------------------------------------------------ equation sheet viewer
// In-page panel (no iframe, no new tab), so opening it never blurs the window or hides the page:
// the focus log and the exam timer are unaffected. Pages are PNGs in the private bucket, fetched with
// short-lived signed URLs that storage RLS only issues while the attempt is open or results are released.
const sheetUrls = new Map(); // path -> { url, exp }
let sheetView = null;
function closeSheet() { if (sheetView) sheetView.destroy(); }
async function signSheet(pages, expiresIn) {
  const now = Date.now(), need = pages.map((p) => p.path).filter((p) => !(sheetUrls.get(p)?.exp > now + 60000));
  if (need.length) {
    const { data, error } = await sb.storage.from("exam-images").createSignedUrls(need, expiresIn);
    if (error) throw error;
    (data || []).forEach((d) => d.signedUrl && !d.error && sheetUrls.set(d.path, { url: d.signedUrl, exp: now + expiresIn * 1000 }));
  }
  return pages.map((p) => sheetUrls.get(p.path)?.url || null);
}
function openSheet(sheet, { expiresIn = 3600, withTimer = false } = {}) {
  if (sheetView) return closeSheet();
  const pages = sheet.pages || [];
  const root = document.getElementById("sheet-root");
  root.innerHTML = `<section class="sheet" role="dialog" aria-label="${esc(sheet.title || "Equation sheet")}">
    <div class="sheet-head">
      <b class="sheet-title">${esc(sheet.title || "Equation sheet")}</b>
      ${withTimer ? `<span class="timer sheet-timer" id="sheet-timer"></span>` : ""}
      <div class="sheet-tools">
        <button type="button" data-z="out" aria-label="Zoom out">−</button>
        <button type="button" data-z="fit" class="pct" aria-label="Fit to width">100%</button>
        <button type="button" data-z="in" aria-label="Zoom in">+</button>
        <button type="button" class="sheet-close" aria-label="Close equation sheet">✕</button>
      </div>
    </div>
    <div class="sheet-body" tabindex="0"><div class="sheet-pages">${pages.map((p, i) =>
      `<div class="sheet-page" style="aspect-ratio:${Number(p.w) || 1240} / ${Number(p.h) || 1754}"><img alt="Page ${i + 1} of ${pages.length}" draggable="false" data-i="${i}"></div>`).join("")}
    </div></div>
    <div class="sheet-foot"><span id="sheet-pg">${pages.length} page${pages.length === 1 ? "" : "s"}</span><span class="muted">Pinch or double-tap to zoom</span></div>
  </section>`;
  document.body.classList.add("sheet-open");
  const el = root.querySelector(".sheet"), body = el.querySelector(".sheet-body"), wrap = el.querySelector(".sheet-pages");
  const pct = el.querySelector(".pct"), pg = el.querySelector("#sheet-pg");
  let scale = 1;
  const MIN = 1, MAX = 5;
  function setScale(s, cx, cy) {
    s = Math.min(MAX, Math.max(MIN, s));
    const r = body.getBoundingClientRect();
    cx = cx ?? r.width / 2; cy = cy ?? r.height / 2;
    const x = (body.scrollLeft + cx) / scale, y = (body.scrollTop + cy) / scale;
    scale = s; wrap.style.width = `${scale * 100}%`;
    body.scrollLeft = x * scale - cx; body.scrollTop = y * scale - cy;
    pct.textContent = `${Math.round(scale * 100)}%`;
    body.classList.toggle("zoomed", scale > 1.01);
  }
  el.querySelectorAll("[data-z]").forEach((b) => (b.onclick = () => setScale(b.dataset.z === "fit" ? 1 : b.dataset.z === "in" ? scale * 1.25 : scale / 1.25)));
  el.querySelector(".sheet-close").onclick = closeSheet;
  // pinch zoom (two fingers) and double-tap; single-finger panning stays native scrolling
  let pinch = null, lastTap = 0;
  const mid = (t) => { const r = body.getBoundingClientRect(); return [(t[0].clientX + t[1].clientX) / 2 - r.left, (t[0].clientY + t[1].clientY) / 2 - r.top]; };
  const dist = (t) => Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY);
  body.addEventListener("touchstart", (e) => {
    if (e.touches.length === 2) { pinch = { d: dist(e.touches), s: scale }; e.preventDefault(); }
    else if (e.touches.length === 1) {
      const now = Date.now(), t = e.touches[0], r = body.getBoundingClientRect();
      if (now - lastTap < 300) { e.preventDefault(); setScale(scale > 1.01 ? 1 : 2.5, t.clientX - r.left, t.clientY - r.top); lastTap = 0; } else lastTap = now;
    }
  }, { passive: false });
  body.addEventListener("touchmove", (e) => {
    if (pinch && e.touches.length === 2) { e.preventDefault(); const [cx, cy] = mid(e.touches); setScale(pinch.s * dist(e.touches) / pinch.d, cx, cy); }
  }, { passive: false });
  body.addEventListener("touchend", (e) => { if (e.touches.length < 2) pinch = null; });
  body.addEventListener("dblclick", (e) => { const r = body.getBoundingClientRect(); setScale(scale > 1.01 ? 1 : 2.5, e.clientX - r.left, e.clientY - r.top); });
  body.addEventListener("wheel", (e) => { if (e.ctrlKey || e.metaKey) { e.preventDefault(); const r = body.getBoundingClientRect(); setScale(scale * Math.exp(-e.deltaY / 300), e.clientX - r.left, e.clientY - r.top); } }, { passive: false });
  // drag to pan with a mouse when zoomed
  let drag = null;
  body.addEventListener("mousedown", (e) => { if (scale > 1.01 && e.button === 0) { drag = { x: e.clientX, y: e.clientY, l: body.scrollLeft, t: body.scrollTop }; e.preventDefault(); } });
  const onMove = (e) => { if (drag) { body.scrollLeft = drag.l - (e.clientX - drag.x); body.scrollTop = drag.t - (e.clientY - drag.y); } };
  const onUp = () => (drag = null);
  const onKey = (e) => {
    if (e.key === "Escape") closeSheet();
    else if (!/INPUT|TEXTAREA/.test(document.activeElement?.tagName || "")) {
      if (e.key === "+" || e.key === "=") setScale(scale * 1.25); else if (e.key === "-") setScale(scale / 1.25); else if (e.key === "0") setScale(1);
    }
  };
  window.addEventListener("mousemove", onMove); window.addEventListener("mouseup", onUp); document.addEventListener("keydown", onKey);
  const onScroll = () => {
    const imgs = wrap.querySelectorAll(".sheet-page"), mid = body.scrollTop + body.clientHeight / 2;
    let n = 1; imgs.forEach((p, i) => { if (p.offsetTop <= mid) n = i + 1; });
    if (pages.length > 1) pg.textContent = `Page ${n} of ${pages.length}`;
  };
  body.addEventListener("scroll", onScroll, { passive: true });
  sheetView = {
    destroy() {
      window.removeEventListener("mousemove", onMove); window.removeEventListener("mouseup", onUp); document.removeEventListener("keydown", onKey);
      root.innerHTML = ""; document.body.classList.remove("sheet-open"); sheetView = null;
      document.querySelectorAll("[data-sheet-btn]").forEach((b) => b.setAttribute("aria-expanded", "false"));
    },
  };
  document.querySelectorAll("[data-sheet-btn]").forEach((b) => b.setAttribute("aria-expanded", "true"));
  onScroll();
  signSheet(pages, Math.round(expiresIn)).then((urls) => {
    if (!el.isConnected) return;
    let bad = 0;
    wrap.querySelectorAll("img").forEach((img, i) => { if (urls[i]) img.src = urls[i]; else { bad++; img.closest(".sheet-page").classList.add("missing"); } });
    if (bad) toast(bad === pages.length ? "The equation sheet isn't available right now." : `${bad} page(s) could not be loaded.`);
  }, () => { if (el.isConnected) { wrap.innerHTML = `<div class="error" style="margin:14px">The equation sheet isn't available right now.</div>`; } });
}

// ------------------------------------------------------------------ router
async function render() {
  cleanup.forEach((f) => { try { f(); } catch {} }); cleanup = [];
  document.getElementById("modal-root").innerHTML = "";
  closeSheet();
  setNav();
  const h = location.hash || "#/";
  const [, page, arg] = h.match(/^#\/([^/]*)\/?(.*)$/) || [];
  const open = ["login", "set-password", "forgot"];
  if (!session && !open.includes(page)) { sessionStorage.setItem("after_login", h); return pageLogin(); }
  try {
    switch (page) {
      case "login": return session ? go("#/") : pageLogin();
      case "forgot": return pageForgot();
      case "set-password": return pageSetPassword();
      case "account": return pageAccount();
      case "examiner": return pageExaminer(arg);
      case "exam": return pageExam(decodeURIComponent(arg));
      case "attempt": return pageAttempt(arg);
      case "results": return pageResults(arg);
      default: return pageDashboard();
    }
  } catch (e) { app.innerHTML = `<div class="card"><div class="error">${esc(errMsg(e))}</div><a class="btn secondary" href="#/">Back to exams</a></div>`; }
}

// ------------------------------------------------------------------ auth pages
function pageLogin() {
  app.innerHTML = `
  <div class="card narrow">
    <h1>Sign in</h1>
    <p class="muted small">Use the email and password for your exam account.</p>
    <div id="err"></div>
    <form id="f">
      <label class="field">Email<input type="email" name="email" autocomplete="username" required></label>
      <label class="field">Password<input type="password" name="password" autocomplete="current-password" required></label>
      <button class="btn block" type="submit">Sign in</button>
    </form>
    <p class="small" style="margin-top:14px"><a href="#/forgot">Forgot password?</a></p>
  </div>`;
  app.querySelector("#f").addEventListener("submit", async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target), btn = e.target.querySelector("button");
    btn.disabled = true; btn.textContent = "Signing in…";
    const { error } = await sb.auth.signInWithPassword({ email: fd.get("email").trim(), password: fd.get("password") });
    if (error) { app.querySelector("#err").innerHTML = `<div class="error">${esc(error.message)}</div>`; btn.disabled = false; btn.textContent = "Sign in"; return; }
    const next = sessionStorage.getItem("after_login") || "#/"; sessionStorage.removeItem("after_login");
    go(next.startsWith("#/login") ? "#/" : next);
  });
}
function pageForgot() {
  app.innerHTML = `
  <div class="card narrow"><h1>Reset password</h1>
    <p class="muted small">We'll email you a link to choose a new password.</p><div id="msg"></div>
    <form id="f"><label class="field">Email<input type="email" name="email" required></label>
    <button class="btn block">Send reset link</button></form>
    <p class="small" style="margin-top:14px"><a href="#/login">Back to sign in</a></p></div>`;
  app.querySelector("#f").addEventListener("submit", async (e) => {
    e.preventDefault();
    const { error } = await sb.auth.resetPasswordForEmail(new FormData(e.target).get("email").trim(), { redirectTo: SITE + "#/set-password" });
    app.querySelector("#msg").innerHTML = error ? `<div class="error">${esc(error.message)}</div>` : `<div class="notice">If that address has an account, a reset link is on its way.</div>`;
  });
}
function pageSetPassword() {
  if (!session) {
    app.innerHTML = `<div class="card narrow"><h1>Set your password</h1><div class="error">This link has expired or was already used. Ask for a new one or <a href="#/forgot">reset your password</a>.</div></div>`;
    return;
  }
  app.innerHTML = `
  <div class="card narrow"><h1>Choose a password</h1>
    <p class="muted small">Signed in as <b>${esc(session.user.email)}</b>. At least 10 characters.</p><div id="msg"></div>
    <form id="f">
      <label class="field">New password<input type="password" name="p1" minlength="10" autocomplete="new-password" required></label>
      <label class="field">Repeat password<input type="password" name="p2" minlength="10" autocomplete="new-password" required></label>
      <button class="btn block">Save password</button></form></div>`;
  app.querySelector("#f").addEventListener("submit", async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    if (fd.get("p1") !== fd.get("p2")) { app.querySelector("#msg").innerHTML = `<div class="error">Passwords don't match.</div>`; return; }
    const { error } = await sb.auth.updateUser({ password: fd.get("p1") });
    if (error) { app.querySelector("#msg").innerHTML = `<div class="error">${esc(error.message)}</div>`; return; }
    toast("Password saved"); go("#/");
  });
}
async function pageAccount() {
  app.innerHTML = `
  <h1>Account</h1>
  <div class="card"><div class="spread"><div><b>${esc(session.user.email)}</b><div class="muted small">Times are shown in Cairo time (${esc(TZ)}).</div></div>
  <button class="btn secondary" id="out">Sign out</button></div></div>
  <div class="card"><h2>Change password</h2><div id="msg"></div>
  <form id="f"><label class="field">New password<input type="password" name="p1" minlength="10" autocomplete="new-password" required></label>
  <label class="field">Repeat password<input type="password" name="p2" minlength="10" autocomplete="new-password" required></label>
  <button class="btn">Update password</button></form></div>`;
  app.querySelector("#out").onclick = async () => { await sb.auth.signOut(); go("#/login"); };
  app.querySelector("#f").addEventListener("submit", async (e) => {
    e.preventDefault(); const fd = new FormData(e.target);
    if (fd.get("p1") !== fd.get("p2")) { app.querySelector("#msg").innerHTML = `<div class="error">Passwords don't match.</div>`; return; }
    const { error } = await sb.auth.updateUser({ password: fd.get("p1") });
    app.querySelector("#msg").innerHTML = error ? `<div class="error">${esc(error.message)}</div>` : `<div class="notice">Password updated.</div>`;
    if (!error) e.target.reset();
  });
}

// ------------------------------------------------------------------ dashboard
function examStatus(e, now) {
  const last = e.attempts[e.attempts.length - 1];
  const inProg = e.attempts.find((a) => a.status === "in_progress");
  const used = e.attempts.length, left = e.attempts_allowed - used;
  const notOpen = e.opens_at && new Date(e.opens_at) > now;
  const closed = e.closes_at && new Date(e.closes_at) <= now;
  if (inProg) return { badge: `<span class="badge amber">In progress</span>`, action: { label: "Resume", href: `#/attempt/${inProg.id}` } };
  if (last && last.released) return { badge: `<span class="badge green">Results released</span>`, action: { label: "View results", href: `#/results/${last.id}` }, extra: left > 0 && !closed && !notOpen };
  if (left > 0 && notOpen) return { badge: `<span class="badge gray">Opens ${esc(fmtCairo(e.opens_at))}</span>`, action: { label: "Details", href: `#/exam/${e.slug}` } };
  if (left > 0 && closed) return { badge: `<span class="badge red">Closed</span>`, action: null };
  if (left > 0) return { badge: `<span class="badge teal">Open</span>`, action: { label: used ? "Start new attempt" : "Start", href: `#/exam/${e.slug}` } };
  if (last) return { badge: `<span class="badge">Submitted · awaiting results</span>`, action: null };
  return { badge: `<span class="badge red">Closed</span>`, action: null };
}
async function pageDashboard() {
  app.innerHTML = `<h1>Your exams</h1><div class="center muted">Loading…</div>`;
  const data = await rpc("list_my_exams");
  const now = new Date(data.server_now);
  if (!data.exams.length) { app.innerHTML = `<h1>Your exams</h1><div class="card muted">No exams are available right now. New quizzes appear here when they're published.</div>`; return; }
  app.innerHTML = `<h1>Your exams</h1>` + data.exams.map((e) => {
    const s = examStatus(e, now);
    return `<div class="card">
      <div class="spread"><h2 style="margin:0">${esc(e.title)}</h2>${s.badge}</div>
      <div class="meta">
        <div><b>Time limit</b>${e.time_limit_minutes} min</div>
        <div><b>Questions</b>${e.question_count} · ${num(e.total_marks)} marks</div>
        <div><b>Attempts</b>${e.attempts.length} of ${e.attempts_allowed} used</div>
        ${e.opens_at ? `<div><b>Opens</b>${esc(fmtCairo(e.opens_at))}</div>` : ""}
        ${e.closes_at ? `<div><b>Closes</b>${esc(fmtCairo(e.closes_at))}</div>` : ""}
        ${e.attempts.length ? `<div><b>Last submitted</b>${esc(fmtCairo(e.attempts[e.attempts.length - 1].submitted_at))}</div>` : ""}
      </div>
      <div class="row">${s.action ? `<a class="btn" href="${s.action.href}">${s.action.label}</a>` : ""}
      ${s.extra ? `<a class="btn secondary" href="#/exam/${esc(e.slug)}">Start new attempt</a>` : ""}</div>
    </div>`;
  }).join("");
}

// ------------------------------------------------------------------ exam intro
async function pageExam(slug) {
  app.innerHTML = `<div class="center muted">Loading…</div>`;
  const data = await rpc("list_my_exams");
  const e = data.exams.find((x) => x.slug === slug);
  if (!e) { app.innerHTML = `<div class="card"><div class="error">This exam isn't available.</div><a class="btn secondary" href="#/">Back</a></div>`; return; }
  const now = new Date(data.server_now), s = examStatus(e, now);
  const inProg = e.attempts.find((a) => a.status === "in_progress");
  const canStart = !inProg && e.attempts.length < e.attempts_allowed && !(e.opens_at && new Date(e.opens_at) > now) && !(e.closes_at && new Date(e.closes_at) <= now);
  app.innerHTML = `
  <div class="card">
    <div class="spread"><h1 style="margin:0">${esc(e.title)}</h1>${s.badge}</div>
    <div class="meta">
      <div><b>Time limit</b>${e.time_limit_minutes} minutes</div>
      <div><b>Questions</b>${e.question_count} · ${num(e.total_marks)} marks</div>
      <div><b>Attempts left</b>${Math.max(0, e.attempts_allowed - e.attempts.length)} of ${e.attempts_allowed}</div>
      ${e.opens_at ? `<div><b>Opens</b>${esc(fmtCairo(e.opens_at))}</div>` : ""}
      ${e.closes_at ? `<div><b>Closes</b>${esc(fmtCairo(e.closes_at))}</div>` : ""}
    </div>
    ${e.instructions ? `<div class="instructions">${rich(e.instructions)}</div>` : ""}
    <ul class="small muted">
      <li>The timer starts as soon as you press <b>Start</b> and keeps running if you close the page.</li>
      <li>Answers save automatically. The exam submits itself when time runs out.</li>
      ${e.closes_at ? `<li>If the exam closes before your time is up, it ends at the closing time.</li>` : ""}
      ${e.log_focus ? `<li>Switching tabs or leaving the page is recorded.</li>` : ""}
      ${e.has_equation_sheet ? `<li>An equation sheet is available during the exam — use the <b>Equation sheet</b> button next to the timer. Opening it doesn't stop the clock.</li>` : ""}
    </ul>
    <div id="err"></div>
    <div class="row">
      ${inProg ? `<a class="btn" href="#/attempt/${inProg.id}">Resume attempt</a>` : ""}
      ${canStart ? `<button class="btn" id="start">Start exam</button>` : ""}
      <a class="btn secondary" href="#/">Back</a>
    </div>
  </div>`;
  const b = app.querySelector("#start");
  if (b) b.onclick = () => {
    const m = modal(`<h2>Start now?</h2><p>You'll have <b>${e.time_limit_minutes} minutes</b>. The clock can't be paused.${e.attempts_allowed === 1 ? " You only get <b>one attempt</b>." : ""}</p>
      <div class="row"><button class="btn" id="go">Start</button><button class="btn secondary" id="no">Cancel</button></div>`);
    m.el.querySelector("#no").onclick = m.close;
    m.el.querySelector("#go").onclick = async (ev) => {
      ev.target.disabled = true;
      try { const att = await rpc("start_attempt", { p_slug: slug }); m.close(); go(`#/attempt/${att.attempt_id}`); }
      catch (err) { m.close(); app.querySelector("#err").innerHTML = `<div class="error">${esc(errMsg(err))}</div>`; }
    };
  };
}

// ------------------------------------------------------------------ take exam
async function pageAttempt(id) {
  app.innerHTML = `<div class="center muted">Loading exam…</div>`;
  let att = await rpc("get_attempt", { p_attempt: id });
  if (att.status !== "in_progress") return showSubmitted(att);

  const qs = att.questions;
  const answers = new Map(qs.map((q) => [q.id, q.response ?? null]));
  const flags = new Set(JSON.parse(localStorage.getItem(`flags:${id}`) || "[]"));
  const pending = new Map(); // qid -> response waiting to be saved
  const timers = new Map();
  let cur = Math.min(Number(sessionStorage.getItem(`cur:${id}`) || 0), qs.length - 1);
  let finished = false, saving = 0, lastError = "";
  const offset = new Date(att.server_now).getTime() - Date.now(); // server clock - local clock
  const deadline = new Date(att.deadline).getTime();
  const remaining = () => deadline - (Date.now() + offset);

  app.innerHTML = `
    <div class="exambar"><div class="inner">
      <div style="min-width:0"><div class="small" style="color:#b9cbe6;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(att.exam.title)}</div>
      <div class="savestate" id="save" style="text-align:left">All answers saved</div></div>
      ${att.equation_sheet ? `<button type="button" class="sheetbtn" id="sheetbtn" data-sheet-btn aria-expanded="false" title="Open the equation sheet (the timer keeps running)">📐<span><span class="lg">Equation </span>sheet</span></button>` : ""}
      <div style="text-align:right"><div class="timer" id="timer">--:--</div><div class="savestate">ends ${esc(fmtCairo(att.deadline, { weekday: undefined, year: undefined, day: undefined, month: undefined }))}</div></div>
    </div></div>
    ${att.exam.log_focus ? `<div class="notice small">Switching tabs or leaving this page is recorded.</div>` : ""}
    <div class="card" id="qcard"></div>
    <div class="card"><div class="spread"><b>Questions</b><span class="small muted" id="count"></span></div>
      <div class="grid" id="grid" style="margin-top:10px"></div>
      <div class="legend"><span><i style="background:#ccfbf1;border-color:#5eead4"></i>Answered</span><span><i></i>Not answered</span><span><i style="background:var(--amber);border-color:var(--amber);border-radius:50%"></i>Flagged</span></div>
    </div>
    <div class="bottombar"><div class="inner"><button class="btn navy block" id="submit">Submit exam</button></div></div>`;

  const answered = (v) => !(v === null || v === undefined || v === "" || (Array.isArray(v) && v.length === 0));
  const setSave = (t) => { const el = document.getElementById("save"); if (el) el.textContent = t; };
  const refreshSave = () => setSave(lastError ? lastError : (pending.size || saving) ? "Saving…" : "All answers saved");

  async function flushOne(qid) {
    if (!pending.has(qid) || finished && !flushing) return;
    const resp = pending.get(qid); saving++; refreshSave();
    try {
      await rpc("save_answer", { p_attempt: id, p_question: qid, p_response: resp });
      if (pending.get(qid) === resp) pending.delete(qid);
      lastError = "";
    } catch (e) {
      const m = errMsg(e);
      if (/Time is up|already submitted/i.test(m)) { pending.delete(qid); lastError = "Time is up"; }
      else { lastError = "Offline — will retry"; setTimeout(() => flushOne(qid), 3000); }
    } finally { saving--; refreshSave(); }
  }
  let flushing = false;
  async function flushAll() { flushing = true; for (const t of timers.values()) clearTimeout(t); timers.clear(); await Promise.all([...pending.keys()].map(flushOne)); flushing = false; }
  function queueSave(qid, value, delay) {
    answers.set(qid, value); pending.set(qid, value); refreshSave(); drawGrid();
    localStorage.setItem(`ans:${id}`, JSON.stringify([...answers]));
    clearTimeout(timers.get(qid)); timers.set(qid, setTimeout(() => flushOne(qid), delay));
  }

  function drawGrid() {
    const g = document.getElementById("grid"); if (!g) return;
    g.innerHTML = qs.map((q, i) => `<button class="gbtn ${answered(answers.get(q.id)) ? "ans" : ""} ${i === cur ? "cur" : ""} ${flags.has(q.id) ? "flag" : ""}" data-i="${i}" aria-label="Question ${i + 1}">${i + 1}</button>`).join("");
    g.querySelectorAll(".gbtn").forEach((b) => (b.onclick = () => { cur = Number(b.dataset.i); drawQ(); window.scrollTo({ top: 0, behavior: "smooth" }); }));
    document.getElementById("count").textContent = `${qs.filter((q) => answered(answers.get(q.id))).length} of ${qs.length} answered`;
  }

  function drawQ() {
    sessionStorage.setItem(`cur:${id}`, cur);
    const q = qs[cur], v = answers.get(q.id), el = document.getElementById("qcard");
    let input = "";
    if (q.type === "mcq" || q.type === "multi") {
      const multi = q.type === "multi";
      input = `${multi ? `<p class="small muted">Select all that apply.</p>` : ""}<div class="opts">` + q.options.map((o) => {
        const on = multi ? (Array.isArray(v) && v.includes(o.id)) : v === o.id;
        return `<label class="opt ${on ? "sel" : ""}"><input type="${multi ? "checkbox" : "radio"}" name="q" value="${esc(o.id)}" ${on ? "checked" : ""}><span>${rich(o.text)}</span></label>`;
      }).join("") + `</div>`;
    } else if (q.type === "tf") {
      input = `<div class="tfrow">${[["true", "True"], ["false", "False"]].map(([val, lab]) => `<label class="opt ${String(v) === val ? "sel" : ""}"><input type="radio" name="q" value="${val}" ${String(v) === val ? "checked" : ""}>${lab}</label>`).join("")}</div>`;
    } else if (q.type === "numeric") {
      input = `<div class="numrow"><input type="text" inputmode="decimal" autocomplete="off" id="numin" placeholder="Enter a number" value="${esc(v ?? "")}">${q.unit ? `<span class="unit">${esc(q.unit)}</span>` : ""}</div><div class="small muted" id="numhint" style="margin-top:6px"></div>`;
    } else {
      input = `<textarea id="txt" placeholder="Type your answer…">${esc(v ?? "")}</textarea>`;
    }
    el.innerHTML = `
      <div class="qhead"><span class="badge">Question ${cur + 1} of ${qs.length} · ${num(q.marks)} mark${Number(q.marks) === 1 ? "" : "s"}</span>
      <button class="flagbtn ${flags.has(q.id) ? "on" : ""}" id="flag">${flags.has(q.id) ? "★ Flagged" : "☆ Flag for review"}</button></div>
      <div class="prompt">${rich(q.prompt)}</div><div id="img"></div>${input}
      <div class="qnav"><button class="btn secondary" id="prev" ${cur === 0 ? "disabled" : ""}>← Previous</button>
      <button class="btn secondary" id="next" ${cur === qs.length - 1 ? "disabled" : ""}>Next →</button></div>`;
    attachImage(el.querySelector("#img"), q.image_path);
    el.querySelector("#prev").onclick = () => { cur--; drawQ(); };
    el.querySelector("#next").onclick = () => { cur++; drawQ(); };
    el.querySelector("#flag").onclick = () => { flags.has(q.id) ? flags.delete(q.id) : flags.add(q.id); localStorage.setItem(`flags:${id}`, JSON.stringify([...flags])); drawQ(); };
    el.querySelectorAll("input[name=q]").forEach((inp) => inp.addEventListener("change", () => {
      let val;
      if (q.type === "multi") val = [...el.querySelectorAll("input[name=q]:checked")].map((x) => x.value);
      else if (q.type === "tf") val = inp.value === "true";
      else val = inp.value;
      el.querySelectorAll(".opt").forEach((o) => o.classList.toggle("sel", o.querySelector("input").checked));
      queueSave(q.id, val, 150);
    }));
    const ni = el.querySelector("#numin");
    if (ni) ni.addEventListener("input", () => {
      const raw = ni.value.trim().replace(/,/g, "");
      const ok = raw === "" || /^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$/.test(raw);
      el.querySelector("#numhint").textContent = ok ? "" : "That doesn't look like a number. Use digits and a decimal point.";
      queueSave(q.id, raw === "" ? null : ok ? Number(raw) : raw, 700);
    });
    const tx = el.querySelector("#txt");
    if (tx) tx.addEventListener("input", () => queueSave(q.id, tx.value, 900));
    drawGrid();
  }

  async function submit(reason) {
    if (finished) return; finished = true;
    clearInterval(tick); closeSheet();
    setSave("Submitting…");
    await flushAll();
    for (let i = 0; i < 5; i++) {
      try { await rpc("submit_attempt", { p_attempt: id, p_reason: reason }); break; }
      catch (e) { if (i === 4) { toast("Couldn't reach the server. Your saved answers will be submitted automatically."); } await new Promise((r) => setTimeout(r, 1500)); }
    }
    localStorage.removeItem(`ans:${id}`); localStorage.removeItem(`flags:${id}`);
    const a2 = await rpc("get_attempt", { p_attempt: id }).catch(() => ({ ...att, status: "submitted", submitted_at: new Date().toISOString() }));
    showSubmitted(a2, reason === "timer");
  }

  document.getElementById("submit").onclick = () => {
    const un = qs.map((q, i) => answered(answers.get(q.id)) ? null : i + 1).filter(Boolean);
    const fl = qs.map((q, i) => flags.has(q.id) ? i + 1 : null).filter(Boolean);
    const m = modal(`<h2>Submit exam?</h2>
      <p>${un.length ? `<b>${un.length} unanswered:</b> question ${un.join(", ")}.` : "All questions answered."}${fl.length ? `<br>Flagged: ${fl.join(", ")}.` : ""}</p>
      <p class="small muted">You can't change your answers after submitting.</p>
      <div class="row"><button class="btn navy" id="yes">Submit</button><button class="btn secondary" id="no">Keep working</button></div>`);
    m.el.querySelector("#no").onclick = m.close;
    m.el.querySelector("#yes").onclick = () => { m.close(); submit("manual"); };
  };

  // timer
  const tEl = document.getElementById("timer");
  const tick = setInterval(() => {
    const ms = remaining();
    if (ms <= 0) { tEl.textContent = "00:00"; submit("timer"); return; }
    const s = Math.ceil(ms / 1000), h = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
    tEl.textContent = (h ? `${h}:${String(mm).padStart(2, "0")}` : String(mm).padStart(2, "0")) + ":" + String(ss).padStart(2, "0");
    tEl.className = "timer" + (ms < 60000 ? " crit" : ms < 300000 ? " warn" : "");
    const st = document.getElementById("sheet-timer");
    if (st) { st.textContent = tEl.textContent; st.className = tEl.className + " sheet-timer"; }
  }, 250);
  cleanup.push(() => clearInterval(tick));
  const sheetBtn = document.getElementById("sheetbtn");
  if (sheetBtn) sheetBtn.onclick = () => openSheet(att.equation_sheet, {
    withTimer: true,
    // signed links only live a little past the deadline
    expiresIn: Math.min(3600, Math.max(120, remaining() / 1000 + 120)),
  });

  // focus logging
  if (att.exam.log_focus) {
    const log = (ev, detail) => { if (!finished) sb.rpc("log_focus_event", { p_attempt: id, p_event: ev, p_client_ts: new Date().toISOString(), p_detail: detail || null }).then(() => {}, () => {}); };
    const onVis = () => log(document.visibilityState === "hidden" ? "hidden" : "visible");
    const onBlur = () => log("blur"), onFocus = () => log("focus"), onHide = () => log("pagehide");
    document.addEventListener("visibilitychange", onVis); window.addEventListener("blur", onBlur); window.addEventListener("focus", onFocus); window.addEventListener("pagehide", onHide);
    log("resume", { ua: navigator.userAgent.slice(0, 160) });
    cleanup.push(() => { document.removeEventListener("visibilitychange", onVis); window.removeEventListener("blur", onBlur); window.removeEventListener("focus", onFocus); window.removeEventListener("pagehide", onHide); });
  }
  const onUnload = (e) => { if (!finished && pending.size) { e.preventDefault(); e.returnValue = ""; } };
  window.addEventListener("beforeunload", onUnload);
  const onOnline = () => [...pending.keys()].forEach(flushOne);
  window.addEventListener("online", onOnline);
  cleanup.push(() => { window.removeEventListener("beforeunload", onUnload); window.removeEventListener("online", onOnline); flushAll(); });

  drawQ();
}

function showSubmitted(att, timedOut = false) {
  app.innerHTML = `<div class="card narrow" style="text-align:center">
    <div style="font-size:44px">✓</div><h1>${timedOut ? "Time's up — exam submitted" : "Exam submitted"}</h1>
    <p class="muted">${esc(att.exam?.title || "")}<br>Submitted ${esc(fmtCairo(att.submitted_at))}</p>
    ${att.released ? `<a class="btn" href="#/results/${att.attempt_id}">View results</a>` : `<p>Your answers are with your mentor. Results will appear on your dashboard once they're released.</p><a class="btn" href="#/">Back to exams</a>`}
  </div>`;
}

// ------------------------------------------------------------------ results
function showResp(q, v) {
  if (v === null || v === undefined || v === "") return "<i class=muted>No answer</i>";
  if (q.type === "mcq" || q.type === "multi") {
    const ids = Array.isArray(v) ? v : [v];
    return ids.map((i) => esc((q.options.find((o) => o.id === i) || { text: i }).text)).join("<br>") || "<i class=muted>No answer</i>";
  }
  if (q.type === "tf") return v === true ? "True" : v === false ? "False" : esc(v);
  if (q.type === "numeric") return esc(v) + (q.unit ? " " + esc(q.unit) : "");
  return esc(v);
}
function showKey(q) {
  if (q.answer === null || q.answer === undefined) return "—";
  if (q.type === "numeric") {
    const tol = [q.tolerance_abs ? `± ${num(q.tolerance_abs)}${q.unit ? " " + esc(q.unit) : ""}` : "", q.tolerance_pct ? `± ${num(q.tolerance_pct)}%` : ""].filter(Boolean).join(" or ");
    return `${esc(q.answer)}${q.unit ? " " + esc(q.unit) : ""}${tol ? ` <span class="muted small">(accepted ${tol})</span>` : ""}`;
  }
  return showResp(q, q.answer);
}
async function pageResults(id) {
  app.innerHTML = `<div class="center muted">Loading results…</div>`;
  let r;
  try { r = await rpc("get_results", { p_attempt: id }); }
  catch (e) { app.innerHTML = `<div class="card narrow"><h1>Results not available yet</h1><p class="muted">${esc(errMsg(e))}</p><a class="btn" href="#/">Back to exams</a></div>`; return; }
  const pct = r.max_score > 0 ? Math.round((r.total_score / r.max_score) * 100) : 0;
  app.innerHTML = `
    <div class="card"><div class="score"><div class="ring" style="--p:${pct}"><span>${pct}%</span></div>
      <div><h1 style="margin:0">${esc(r.exam.title)}</h1><div><b>${num(r.total_score)}</b> / ${num(r.max_score)} marks</div>
      <div class="small muted">Submitted ${esc(fmtCairo(r.submitted_at))}${r.submit_reason === "time_expired" || r.submit_reason === "timer" ? " · time ran out" : ""}</div>
      ${r.pending_manual ? `<div class="small" style="color:var(--amber)">${r.pending_manual} answer(s) still being marked</div>` : ""}</div></div>
      ${r.feedback ? `<div class="fb"><b>Mentor feedback</b><br>${rich(r.feedback)}</div>` : ""}
      ${r.equation_sheet ? `<div class="row" style="margin-top:12px"><button type="button" class="btn secondary" id="sheetbtn" data-sheet-btn aria-expanded="false">📐 ${esc(r.equation_sheet.title || "Equation sheet")}</button></div>` : ""}</div>
    ${r.questions.map((q) => {
      const cls = q.pending ? "" : q.is_correct === true ? "ok" : q.is_correct === false ? "bad" : "part";
      const badge = q.pending ? `<span class="badge amber">Awaiting marking</span>` : q.is_correct === true ? `<span class="badge green">Correct</span>` : q.is_correct === false ? `<span class="badge red">Incorrect</span>` : `<span class="badge amber">Partial</span>`;
      return `<div class="card res ${cls}">
        <div class="qhead"><span class="badge">Question ${q.n}</span>${badge}</div>
        <div class="prompt">${rich(q.prompt)}</div><div data-img="${esc(q.image_path || "")}"></div>
        <dl class="kv"><dt>Your answer</dt><dd>${showResp(q, q.response)}</dd>
        <dt>${q.type === "short" ? "Model answer" : "Correct answer"}</dt><dd>${showKey(q)}</dd>
        <dt>Marks</dt><dd>${q.pending ? "—" : num(q.awarded)} / ${num(q.marks)}</dd></dl>
        ${q.explanation ? `<div class="fb"><b>Explanation</b><br>${rich(q.explanation)}</div>` : ""}
        ${q.feedback ? `<div class="fb"><b>Feedback</b><br>${rich(q.feedback)}</div>` : ""}
      </div>`;
    }).join("")}
    <a class="btn secondary" href="#/">Back to exams</a>`;
  app.querySelectorAll("[data-img]").forEach((d) => d.dataset.img && attachImage(d, d.dataset.img));
  const sb2 = app.querySelector("#sheetbtn");
  if (sb2) sb2.onclick = () => openSheet(r.equation_sheet);
}


// ------------------------------------------------------------------ examiner (admin)
async function pageExaminer(arg) {
  app.innerHTML = `<div class="center muted">Loading examiner…</div>`;
  try {
    const ex = createExaminer({
      rpc, esc, rich, fmtCairo, num, toast, errMsg, go, sb, signedImage, modal,
    });
    const parts = (arg || "").split("/").filter(Boolean);
    // #/examiner | #/examiner/edit | #/examiner/edit/<slug>
    if (parts[0] === "edit") {
      await ex.open(app, parts[1] || "");
    } else {
      await ex.open(app);
    }
    isAdmin = true; setNav();
  } catch (e) {
    if (e?.code === "NOT_ADMIN" || /Not authorized|only available to admin/i.test(errMsg(e))) {
      app.innerHTML = `<div class="card narrow"><h1>Examiner</h1><p class="muted">This area is for admin accounts only.</p><a class="btn" href="#/">Back to exams</a></div>`;
      isAdmin = false; setNav();
      return;
    }
    app.innerHTML = `<div class="card"><div class="error">${esc(errMsg(e))}</div><a class="btn secondary" href="#/">Back</a></div>`;
  }
}

// ------------------------------------------------------------------ boot
async function boot() {
  if (!CFG.SUPABASE_URL || !CFG.SUPABASE_ANON_KEY) {
    app.innerHTML = `<div class="card narrow"><h1>Almost ready</h1><p class="muted">The site isn't connected to its database yet (missing public key in <code>config.js</code>).</p></div>`;
    return;
  }
  sb = createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: "implicit" } });
  const raw = location.hash + location.search;
  const params = new URLSearchParams(location.search);
  let landing = null;
  // Invite / recovery links that carry a token_hash (custom email templates)
  if (params.get("token_hash") && params.get("type")) {
    const { error } = await sb.auth.verifyOtp({ token_hash: params.get("token_hash"), type: params.get("type") });
    history.replaceState(null, "", location.pathname);
    landing = error ? "#/set-password" : "#/set-password";
  } else if (/access_token=|type=(invite|recovery|signup)/.test(raw)) {
    landing = /type=(invite|recovery)/.test(raw) ? "#/set-password" : "#/";
  } else if (/error_description=/.test(raw)) {
    const m = new URLSearchParams(location.hash.slice(1)); toast(m.get("error_description") || "Link error", 6000); landing = "#/login";
  }
  const { data } = await sb.auth.getSession();
  session = data.session;
  await refreshAdminFlag();
  sb.auth.onAuthStateChange(async (ev, s) => {
    const had = !!session; session = s;
    await refreshAdminFlag();
    if (ev === "PASSWORD_RECOVERY") go("#/set-password");
    if (ev === "SIGNED_OUT" && had) go("#/login");
  });
  window.addEventListener("hashchange", render);
  if (landing) { history.replaceState(null, "", location.pathname + landing); }
  render();
}
boot();
