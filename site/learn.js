// Learning platform pages: courses, course, week, day (PDF viewer, infographic, videos, readings), progress.
// Course files live in the private `course-files` bucket; storage RLS only signs URLs for published material
// and allow-listed users. URLs are short-lived (1 h) and re-signed on every visit.
const PDFJS = "./vendor/pdfjs-4.10.38/";
const BUCKET = "course-files";

export function createLearn(ctx) {
  const { app, esc, rpc, toast, modal, fmtCairo, setWide } = ctx;
  const sb = () => ctx.sb();
  const signCache = new Map();

  // ---------------------------------------------------------------- helpers
  const pct = (a, b) => (b ? Math.round((100 * a) / b) : 0);
  const fmtSize = (n) => (!n ? "" : n > 1e6 ? `${(n / 1e6).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1e3))} KB`);
  const fmtDay = (iso) => iso ? new Intl.DateTimeFormat("en-GB", { timeZone: "Africa/Cairo", weekday: "short", day: "numeric", month: "short" }).format(new Date(iso)) : "";
  const dayHref = (c, w, p) => `#/learn/${encodeURIComponent(c)}/${w}/${p}`;
  const weekHref = (c, w) => `#/learn/${encodeURIComponent(c)}/${w}`;
  const courseHref = (c) => `#/learn/${encodeURIComponent(c)}`;
  const icon = {
    check: `<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M9.5 16.2 5.3 12l-1.4 1.4 5.6 5.6L20.1 8.4 18.7 7z"/></svg>`,
    pdf: `<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M6 2h8l6 6v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm7 1.5V9h5.5zM8 13v5h1.3v-1.6h.8a1.7 1.7 0 0 0 0-3.4zm1.3 1.1h.7a.6.6 0 0 1 0 1.2h-.7zM12.5 13v5h1.6a2.5 2.5 0 0 0 0-5zm1.3 1.1h.3a1.4 1.4 0 0 1 0 2.8h-.3zM17 13v5h1.3v-2h1.5v-1.1h-1.5v-.8h1.7V13z"/></svg>`,
    play: `<svg viewBox="0 0 68 48" width="68" height="48" aria-hidden="true"><path d="M66.5 7.7a8.5 8.5 0 0 0-6-6C55.3.3 34 .3 34 .3s-21.3 0-26.5 1.4a8.5 8.5 0 0 0-6 6C.1 13 .1 24 .1 24s0 11 1.4 16.3a8.5 8.5 0 0 0 6 6C12.7 47.7 34 47.7 34 47.7s21.3 0 26.5-1.4a8.5 8.5 0 0 0 6-6C67.9 35 67.9 24 67.9 24s0-11-1.4-16.3z" fill="#f00"/><path d="M45 24 27 14v20" fill="#fff"/></svg>`,
    file: `<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M6 2h8l6 6v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm7 1.5V9h5.5z"/></svg>`,
    link: `<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M14 3h7v7h-2V6.4l-9.3 9.3-1.4-1.4L17.6 5H14zM5 5h6v2H5v12h12v-6h2v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z"/></svg>`,
    fire: `<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M13.5.7s.7 2.6.7 4.7c0 2-1.3 3.6-3.3 3.6S7.5 7.4 7.5 5.4l.03-.4C5.5 7.4 4.3 10.5 4.3 14a7.7 7.7 0 0 0 15.4 0C19.7 7.6 16.6 3.4 13.5.7zM11.7 20c-1.6 0-2.9-1.2-2.9-2.8 0-1.5 1-2.5 2.6-2.8 1.6-.3 3.3-1.1 4.2-2.4.4 1.3.6 2.6.6 4 0 2.2-2 4-4.5 4z"/></svg>`,
  };
  async function sign(path, { download = false } = {}) {
    const k = path + (download ? "#d" : "");
    const c = signCache.get(k);
    if (c && c.exp > Date.now() + 120000) return c.url;
    const { data, error } = await sb().storage.from(BUCKET).createSignedUrl(path, 3600, download ? { download: true } : undefined);
    if (error || !data?.signedUrl) throw new Error("This file isn't available right now.");
    signCache.set(k, { url: data.signedUrl, exp: Date.now() + 3600000 });
    return data.signedUrl;
  }
  function crumbs(parts) {
    return `<nav class="crumbs" aria-label="Breadcrumb">${parts.map(([label, href], i) =>
      href && i < parts.length - 1 ? `<a href="${href}">${esc(label)}</a>` : `<span>${esc(label)}</span>`).join(`<i>›</i>`)}</nav>`;
  }
  function bar(done, total, color) {
    return `<div class="pbar" role="progressbar" aria-valuemin="0" aria-valuemax="${total}" aria-valuenow="${done}"><span style="width:${pct(done, total)}%;${color ? `background:${esc(color)}` : ""}"></span></div>`;
  }
  function ring(done, total, color, size = 76) {
    return `<div class="lring" style="--p:${pct(done, total)};--c:${esc(color || "#14b8a6")};width:${size}px;height:${size}px"><span>${pct(done, total)}%</span></div>`;
  }
  function quizLine(q) {
    let status, action;
    if (q.in_progress) { status = `<span class="badge amber">In progress</span>`; action = `<a class="btn sm" href="#/exam/${esc(q.slug)}">Resume</a>`; }
    else if (q.best) {
      status = `<span class="badge green">Best ${esc(String(+q.best.score))} / ${esc(String(+q.best.max))} · ${esc(String(q.best.pct))}%</span>`;
      action = `<a class="btn sm secondary" href="#/results/${esc(q.best.attempt_id)}">View results</a>`;
    } else if (q.submitted > 0) { status = `<span class="badge gray">Submitted · awaiting results</span>`; action = ""; }
    else { status = `<span class="badge teal">Not attempted</span>`; action = `<a class="btn sm" href="#/exam/${esc(q.slug)}">Open quiz</a>`; }
    const left = q.attempts_allowed - q.attempts_used;
    if (!q.in_progress && left > 0 && (q.best || q.submitted)) action += ` <a class="btn sm secondary" href="#/exam/${esc(q.slug)}">Retake (${left} left)</a>`;
    return `<div class="quizline"><div><b>${esc(q.title)}</b><div class="small muted">${q.attempts_used} of ${q.attempts_allowed} attempt${q.attempts_allowed === 1 ? "" : "s"} used${q.last_submitted_at ? ` · last submitted ${esc(fmtCairo(q.last_submitted_at))}` : ""}</div></div>
      <div class="row">${status}${action}</div></div>`;
  }
  function fileList(files, { skip = [] } = {}) {
    const fs = (files || []).filter((f) => !skip.includes(f.kind));
    if (!fs.length) return "";
    return `<ul class="files">${fs.map((f) => `<li><button type="button" class="filebtn" data-path="${esc(f.path)}" data-mime="${esc(f.mime || "")}" data-label="${esc(f.label)}">
      ${f.mime === "application/pdf" ? icon.pdf : icon.file}<span><b>${esc(f.label)}</b><small>${esc(f.path.split("/").pop())}${f.size ? ` · ${fmtSize(f.size)}` : ""}${f.pages ? ` · ${f.pages} pages` : ""}</small></span></button></li>`).join("")}</ul>`;
  }
  function wireFiles(root) {
    root.querySelectorAll(".filebtn").forEach((b) => b.addEventListener("click", async () => {
      try {
        if (b.dataset.mime === "application/pdf") return openPdfModal(b.dataset.path, b.dataset.label);
        if (b.dataset.mime.startsWith("image/")) return openImage(await sign(b.dataset.path), b.dataset.label);
        const url = await sign(b.dataset.path, { download: true });
        location.href = url;
      } catch (e) { toast(e.message || "Couldn't open the file"); }
    }));
  }
  function openImage(url, label) {
    const m = modal(`<div class="imgview"><div class="spread"><b>${esc(label || "")}</b><div class="row"><a class="btn sm secondary" href="${esc(url)}" target="_blank" rel="noopener">${icon.link} Full size</a><button class="btn sm secondary" data-x>Close</button></div></div>
      <div class="imgscroll"><img src="${esc(url)}" alt="${esc(label || "")}"></div></div>`, { wide: true });
    m.el.querySelector("[data-x]").onclick = m.close;
    const img = m.el.querySelector("img");
    img.addEventListener("click", () => img.classList.toggle("zoom"));
  }
  function openPdfModal(path, label) {
    const root = document.getElementById("modal-root");
    root.innerHTML = `<div class="pdfmodal"><div class="pdfmodal-in" id="pdfm"></div></div>`;
    let viewer;
    const close = () => { viewer && viewer.destroy(); root.innerHTML = ""; document.body.classList.remove("noscroll"); };
    document.body.classList.add("noscroll");
    viewer = pdfViewer(root.querySelector("#pdfm"), path, { title: label, onClose: close, full: true });
  }

  // ---------------------------------------------------------------- PDF viewer (pdf.js, lazy pages, links)
  let pdfjsP = null;
  function loadPdfjs() {
    if (!pdfjsP) pdfjsP = import(PDFJS + "pdf.min.mjs").then((lib) => { lib.GlobalWorkerOptions.workerSrc = PDFJS + "pdf.worker.min.mjs"; return lib; });
    return pdfjsP;
  }
  function pdfViewer(el, path, { title = "Study pack", onClose = null, full = false, pages: knownPages = null } = {}) {
    el.innerHTML = `<div class="pdfv${full ? " full" : ""}">
      <div class="pdfv-bar">
        <b class="pdfv-title" title="${esc(title)}">${esc(title)}</b>
        <span class="pdfv-pg" aria-live="polite">${knownPages ? `${knownPages} pages` : "Loading…"}</span>
        <div class="pdfv-tools">
          <button type="button" data-z="out" aria-label="Zoom out">−</button>
          <button type="button" data-z="fit" class="pct" aria-label="Fit width">Fit</button>
          <button type="button" data-z="in" aria-label="Zoom in">+</button>
          <button type="button" data-a="full" aria-label="Full screen" title="Full screen">⤢</button>
          <button type="button" data-a="open" aria-label="Open in a new tab" title="Open in a new tab">${icon.link}</button>
          ${onClose ? `<button type="button" data-a="close" aria-label="Close">✕</button>` : ""}
        </div>
      </div>
      <div class="pdfv-body" tabindex="0"><div class="pdfv-pages"><div class="pdfv-msg">Loading the PDF…</div></div></div>
    </div>`;
    const box = el.querySelector(".pdfv"), body = el.querySelector(".pdfv-body"), wrap = el.querySelector(".pdfv-pages");
    const pgLabel = el.querySelector(".pdfv-pg"), zBtn = el.querySelector(".pct");
    let doc = null, zoom = 1, baseW = 0, obs = null, destroyed = false, task = null, pageEls = [], sizes = [], rendered = new Map(), current = 1;
    const dpr = () => Math.min(window.devicePixelRatio || 1, 2);
    const fitWidth = () => Math.max(200, body.clientWidth - 24);

    el.querySelector("[data-a=open]").onclick = async () => { try { window.open(await sign(path), "_blank", "noopener"); } catch (e) { toast(e.message); } };
    el.querySelector("[data-a=full]").onclick = () => {
      if (onClose) return; box.classList.toggle("full"); document.body.classList.toggle("noscroll", box.classList.contains("full")); relayout();
    };
    if (onClose) el.querySelector("[data-a=close]").onclick = onClose;
    el.querySelectorAll("[data-z]").forEach((b) => (b.onclick = () => {
      const z = b.dataset.z === "fit" ? 1 : b.dataset.z === "in" ? Math.min(4, zoom * 1.25) : Math.max(0.5, zoom / 1.25);
      setZoom(z);
    }));
    const onKey = (e) => { if (e.key === "Escape" && box.classList.contains("full")) { if (onClose) onClose(); else { box.classList.remove("full"); document.body.classList.remove("noscroll"); relayout(); } } };
    document.addEventListener("keydown", onKey);

    function setZoom(z) {
      const anchor = current; zoom = z; zBtn.textContent = Math.abs(z - 1) < 0.01 ? "Fit" : `${Math.round(z * 100)}%`;
      relayout(); pageEls[anchor - 1]?.scrollIntoView({ block: "start" });
    }
    function cssW() { return fitWidth() * zoom; }
    function relayout() {
      if (!doc) return;
      const w = cssW();
      wrap.style.width = zoom > 1 ? `${w + 24}px` : "";
      pageEls.forEach((pe, i) => { const s = sizes[i] || sizes[0]; pe.style.width = `${w}px`; pe.style.height = `${(w * s.h) / s.w}px`; });
      for (const [i] of rendered) unrender(i);
      checkVisible();
    }
    function unrender(i) {
      const r = rendered.get(i); if (!r) return;
      try { r.task && r.task.cancel(); } catch {}
      const pe = pageEls[i - 1]; pe.querySelector("canvas")?.remove(); pe.querySelector(".pdfv-links")?.remove(); pe.classList.remove("done");
      rendered.delete(i);
    }
    async function renderPage(i) {
      if (rendered.has(i) || destroyed) return;
      const pe = pageEls[i - 1]; const rec = { task: null }; rendered.set(i, rec);
      try {
        const page = await doc.getPage(i);
        if (destroyed || rendered.get(i) !== rec) return;
        const v1 = page.getViewport({ scale: 1 });
        sizes[i - 1] = { w: v1.width, h: v1.height };
        const w = cssW(), scale = w / v1.width, vp = page.getViewport({ scale: scale * dpr() }), cssVp = page.getViewport({ scale });
        pe.style.height = `${cssVp.height}px`;
        const canvas = document.createElement("canvas");
        canvas.width = Math.floor(vp.width); canvas.height = Math.floor(vp.height);
        canvas.style.width = `${cssVp.width}px`; canvas.style.height = `${cssVp.height}px`;
        rec.task = page.render({ canvasContext: canvas.getContext("2d", { alpha: false }), viewport: vp });
        await rec.task.promise;
        if (destroyed || rendered.get(i) !== rec) return;
        pe.querySelector("canvas")?.remove(); pe.appendChild(canvas); pe.classList.add("done");
        // clickable links (web links open in a new tab, internal links jump to the page)
        const ann = await page.getAnnotations({ intent: "display" });
        const links = document.createElement("div"); links.className = "pdfv-links";
        for (const a of ann) {
          if (a.subtype !== "Link" || !a.rect) continue;
          const [x1, y1, x2, y2] = cssVp.convertToViewportRectangle(a.rect);
          const L = document.createElement("a");
          Object.assign(L.style, { left: `${Math.min(x1, x2)}px`, top: `${Math.min(y1, y2)}px`, width: `${Math.abs(x2 - x1)}px`, height: `${Math.abs(y2 - y1)}px` });
          if (a.url) { L.href = a.url; L.target = "_blank"; L.rel = "noopener noreferrer"; L.title = a.url; }
          else if (a.dest) { L.href = "#"; L.onclick = async (e) => { e.preventDefault(); try { const d = typeof a.dest === "string" ? await doc.getDestination(a.dest) : a.dest; const idx = await doc.getPageIndex(d[0]); pageEls[idx]?.scrollIntoView({ block: "start" }); } catch {} }; }
          else continue;
          links.appendChild(L);
        }
        pe.appendChild(links);
      } catch (e) {
        if (e?.name !== "RenderingCancelledException") rendered.delete(i);
      }
    }
    function checkVisible() {
      if (!doc) return;
      const r = body.getBoundingClientRect(); const near = [];
      let best = null, bestD = Infinity;
      pageEls.forEach((pe, k) => {
        const b = pe.getBoundingClientRect();
        if (b.bottom > r.top - r.height && b.top < r.bottom + r.height) near.push(k + 1);
        const d = Math.abs(b.top - r.top - 10); if (b.bottom > r.top + 30 && d < bestD) { bestD = d; best = k + 1; }
      });
      near.forEach(renderPage);
      for (const [i] of rendered) if (!near.includes(i) && rendered.size > 8) unrender(i);
      if (best) { current = best; pgLabel.textContent = `Page ${best} / ${doc.numPages}`; }
    }
    let raf = 0;
    const onScroll = () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(checkVisible); };
    body.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    let lastW = 0;
    const ro = new ResizeObserver(() => { const w = body.clientWidth; if (doc && Math.abs(w - lastW) > 30) { lastW = w; relayout(); } });
    ro.observe(body);

    (async () => {
      try {
        const [lib, url] = await Promise.all([loadPdfjs(), sign(path)]);
        if (destroyed) return;
        task = lib.getDocument({ url, rangeChunkSize: 262144, disableAutoFetch: true, cMapUrl: PDFJS + "cmaps/", cMapPacked: true, standardFontDataUrl: PDFJS + "standard_fonts/", isEvalSupported: false });
        doc = await task.promise;
        if (destroyed) { doc.destroy(); return; }
        const p1 = await doc.getPage(1); const v = p1.getViewport({ scale: 1 }); baseW = v.width;
        sizes = Array.from({ length: doc.numPages }, () => ({ w: v.width, h: v.height }));
        wrap.innerHTML = sizes.map((_, i) => `<div class="pdfv-page" data-i="${i + 1}" aria-label="Page ${i + 1}"><span class="pdfv-num">${i + 1}</span></div>`).join("");
        pageEls = [...wrap.querySelectorAll(".pdfv-page")];
        lastW = body.clientWidth; relayout();
        pgLabel.textContent = `Page 1 / ${doc.numPages}`;
      } catch (e) {
        if (!destroyed) wrap.innerHTML = `<div class="pdfv-msg error">The PDF couldn't be loaded here. <button type="button" class="linkbtn" data-retry>Open it in a new tab</button></div>`;
        wrap.querySelector("[data-retry]")?.addEventListener("click", async () => { try { window.open(await sign(path), "_blank", "noopener"); } catch (er) { toast(er.message); } });
      }
    })();
    const api = {
      destroy() {
        destroyed = true; document.removeEventListener("keydown", onKey); window.removeEventListener("resize", onScroll); ro.disconnect();
        document.body.classList.remove("noscroll");
        try { task && task.destroy(); } catch {}
      },
    };
    ctx.onLeave(api.destroy);
    return api;
  }

  // ---------------------------------------------------------------- video embeds (click to load, privacy-enhanced)
  function videoCard(v) {
    const id = esc(v.youtube_id);
    return `<figure class="vid">
      <div class="vid-frame"><button type="button" class="yt" data-id="${id}" aria-label="Play ${esc(v.title)}" style="background-image:url('https://i.ytimg.com/vi/${id}/hqdefault.jpg')">${icon.play}</button></div>
      <figcaption><b>${esc(v.title)}</b>
        <span class="small muted">${esc(v.channel || "")}${v.duration ? ` · ${esc(v.duration)}` : ""} · <a href="https://www.youtube.com/watch?v=${id}" target="_blank" rel="noopener">YouTube</a></span>
        ${v.note ? `<span class="small vnote">Watch for: ${esc(v.note)}</span>` : ""}</figcaption></figure>`;
  }
  function wireVideos(root) {
    root.querySelectorAll(".yt").forEach((b) => b.addEventListener("click", () => {
      const f = document.createElement("iframe");
      f.src = `https://www.youtube-nocookie.com/embed/${encodeURIComponent(b.dataset.id)}?autoplay=1&rel=0&modestbranding=1&playsinline=1`;
      f.title = b.getAttribute("aria-label"); f.allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture";
      f.allowFullscreen = true; f.referrerPolicy = "strict-origin-when-cross-origin"; b.replaceWith(f);
    }));
  }

  // ---------------------------------------------------------------- pages
  function streakCard(s) {
    const days = (s.last14 || []).map((d) => `<i class="${d.count ? "on" : ""}" title="${esc(d.date)}: ${d.count} day${d.count === 1 ? "" : "s"} done"></i>`).join("");
    return `<div class="streak card"><div class="streak-n">${icon.fire}<b>${s.current}</b><span>day streak</span></div>
      <div class="streak-r"><div class="heat" aria-label="Last 14 days">${days}</div><div class="small muted">Best ${s.best} day${s.best === 1 ? "" : "s"} · last 14 days</div></div></div>`;
  }

  async function pageCourses() {
    setWide(true);
    app.innerHTML = `<h1>Your courses</h1><div class="center muted">Loading…</div>`;
    const data = await rpc("list_courses");
    const cs = data.courses;
    const next = cs.find((c) => c.next && c.current_week && c.next.week <= c.current_week) || cs.find((c) => c.next);
    app.innerHTML = `
      <div class="hello"><div><h1>Your courses</h1><p class="muted">Study packs, infographics, videos and readings for every day, with your quizzes alongside.</p></div>
        <a class="btn secondary" href="#/progress">Progress</a></div>
      <div class="toprow">
        ${next ? `<a class="card upnext" href="${dayHref(next.slug, next.next.week, next.next.position)}" style="--c:${esc(next.color)}">
          <span class="eyebrow">Up next · ${esc(next.title)}</span><b>${esc(next.next.title)}</b>
          <span class="small muted">Week ${next.next.week} · ${esc(next.next.weekday)}</span><span class="go">Continue →</span></a>` : `<div class="card upnext"><b>All caught up</b><span class="small muted">Every published day is marked done.</span></div>`}
        ${streakCard(data.streak)}
      </div>
      <div class="courses">${cs.map((c) => `
        <a class="card course" href="${courseHref(c.slug)}" style="--c:${esc(c.color)}">
          <div class="course-top">${ring(c.days_done, c.days_total, c.color, 64)}
            <div><h2>${esc(c.title)}</h2><div class="small muted">${esc(c.subtitle)}</div></div></div>
          <p class="small">${esc(c.description)}</p>
          ${bar(c.days_done, c.days_total, c.color)}
          <div class="spread small"><span><b>${c.days_done}</b> of ${c.days_total} days done</span>
            <span class="muted">${c.weeks} week${c.weeks === 1 ? "" : "s"} available${c.total_weeks ? ` of ${c.total_weeks}` : ""}</span></div>
        </a>`).join("") || `<div class="card muted">No courses are available yet.</div>`}
      </div>
      <p class="small muted center-text"><a href="#/exams">All exams and quizzes →</a></p>`;
  }

  async function pageCourse(slug) {
    setWide(true);
    app.innerHTML = `<div class="center muted">Loading…</div>`;
    const { course: c, weeks } = await rpc("get_course", { p_slug: slug });
    const all = weeks.flatMap((w) => w.days); const done = all.filter((d) => d.done).length;
    const curW = c.current_week && weeks.find((w) => w.n === c.current_week) ? c.current_week : (weeks.find((w) => w.days.some((d) => !d.done)) || weeks[weeks.length - 1] || {}).n;
    const more = c.total_weeks && weeks.length < c.total_weeks ? c.total_weeks - weeks.length : 0;
    app.innerHTML = `${crumbs([["Courses", "#/courses"], [c.title]])}
      <div class="card hero" style="--c:${esc(c.color)}">
        <div class="hero-main">${ring(done, all.length, c.color, 84)}
          <div><h1>${esc(c.title)}</h1><div class="muted">${esc(c.subtitle)}</div><p class="small">${esc(c.description)}</p></div></div>
        <div class="hero-stats"><div><b>${done}/${all.length}</b><span>days done</span></div><div><b>${weeks.length}${c.total_weeks ? `/${c.total_weeks}` : ""}</b><span>weeks</span></div>
          <div><b>${weeks.reduce((n, w) => n + w.quizzes.filter((q) => q.best).length, 0)}</b><span>quiz scores</span></div></div>
        ${fileList(c.files)}
      </div>
      <div class="weeks">${weeks.map((w) => {
        const wd = w.days.filter((d) => d.done).length;
        return `<section class="card week${w.n === curW ? " current" : ""}" style="--c:${esc(c.color)}">
          <div class="spread"><a class="week-h" href="${weekHref(c.slug, w.n)}"><span class="eyebrow">Week ${w.n}${w.n === curW ? " · you are here" : ""}</span><h2>${esc(w.title)}</h2></a>
            <span class="badge ${wd === w.days.length && w.days.length ? "green" : "gray"}">${wd}/${w.days.length} done</span></div>
          ${w.summary ? `<p class="small muted">${esc(w.summary)}</p>` : ""}
          <div class="daychips">${w.days.map((d) => `<a class="daychip${d.done ? " done" : ""}" href="${dayHref(c.slug, w.n, d.position)}">
              <span class="dc-day">${esc(d.weekday.slice(0, 3))}</span><span class="dc-t">${esc(d.title)}</span>${d.done ? `<span class="dc-ok">${icon.check}</span>` : ""}</a>`).join("")}</div>
          ${w.quizzes.length ? `<div class="wquiz">${w.quizzes.map(quizLine).join("")}</div>` : ""}
          <div class="row small"><a href="${weekHref(c.slug, w.n)}">Lecture deck and week files →</a></div>
        </section>`;
      }).join("")}
      ${more ? `<div class="card soon muted">${more} more week${more === 1 ? "" : "s"} will appear here as they're released.</div>` : ""}</div>`;
    wireFiles(app);
  }

  async function pageWeek(slug, n) {
    setWide(true);
    app.innerHTML = `<div class="center muted">Loading…</div>`;
    const { course: c, weeks } = await rpc("get_course", { p_slug: slug });
    const w = weeks.find((x) => x.n === n);
    if (!w) throw new Error("This week isn't available yet.");
    const deck = w.files.find((f) => f.kind === "deck");
    const wd = w.days.filter((d) => d.done).length;
    app.innerHTML = `${crumbs([["Courses", "#/courses"], [c.title, courseHref(c.slug)], [`Week ${w.n}`]])}
      <div class="card hero" style="--c:${esc(c.color)}"><span class="eyebrow">Week ${w.n}</span><h1>${esc(w.title)}</h1>
        ${w.summary ? `<p class="muted">${esc(w.summary)}</p>` : ""}
        ${bar(wd, w.days.length, c.color)}<div class="small muted" style="margin-top:6px">${wd} of ${w.days.length} days done</div></div>
      <div class="card"><h2>Days</h2><ol class="daylist">${w.days.map((d) => `<li class="${d.done ? "done" : ""}"><a href="${dayHref(c.slug, w.n, d.position)}">
        <span class="dl-tick">${d.done ? icon.check : d.position}</span><span><b>${esc(d.title)}</b><small>${esc(d.weekday)}${d.videos ? ` · ${d.videos} video${d.videos === 1 ? "" : "s"}` : ""}${d.done_at ? ` · done ${esc(fmtDay(d.done_at))}` : ""}</small></span></a></li>`).join("")}</ol></div>
      ${w.quizzes.length ? `<div class="card"><h2>Quiz</h2>${w.quizzes.map(quizLine).join("")}</div>` : ""}
      ${deck ? `<section class="card"><h2>Lecture deck</h2><div id="deck"></div></section>` : ""}
      ${w.files.length ? `<div class="card"><h2>Week files</h2>${fileList(w.files)}</div>` : ""}`;
    if (deck) pdfViewer(app.querySelector("#deck"), deck.path, { title: deck.label, pages: deck.pages });
    wireFiles(app);
  }

  async function pageDay(slug, n, pos) {
    setWide(true);
    app.innerHTML = `<div class="center muted">Loading…</div>`;
    const r = await rpc("get_day", { p_course: slug, p_week: n, p_position: pos });
    const { course: c, week: w, day: d, nav: nv } = r;
    const pack = d.files.find((f) => f.kind === "pack");
    const ig = d.files.find((f) => f.kind === "infographic");
    const deck = w.files.find((f) => f.kind === "deck");
    const sections = [pack && ["pack", "Study pack"], ig && ["infographic", "Infographic"], d.goals.length && ["goals", "Goals"],
      d.videos.length && ["videos", `Videos (${d.videos.length})`], d.readings.length && ["readings", "Readings"], ["week", "This week"]].filter(Boolean);
    app.innerHTML = `${crumbs([["Courses", "#/courses"], [c.title, courseHref(c.slug)], [`Week ${w.n}`, weekHref(c.slug, w.n)], [d.weekday]])}
      <div class="card hero day" style="--c:${esc(c.color)}">
        <div class="spread"><span class="eyebrow">Week ${w.n} · ${esc(d.weekday)}</span><span id="donebadge">${d.done ? `<span class="badge green">Done ${esc(fmtDay(d.done_at))}</span>` : ""}</span></div>
        <h1>${esc(d.title)}</h1>
        <div class="day-actions">
          <button class="btn ${d.done ? "secondary" : ""}" id="donebtn" aria-pressed="${d.done ? "true" : "false"}">${d.done ? `${icon.check} Done · undo` : "Mark as done"}</button>
          <div class="row">${nv.prev ? `<a class="btn secondary sm" href="${dayHref(c.slug, nv.prev.week, nv.prev.position)}" title="${esc(nv.prev.title)}">← ${esc(nv.prev.weekday.slice(0, 3))}${nv.prev.week !== w.n ? ` W${nv.prev.week}` : ""}</a>` : ""}
          ${nv.next ? `<a class="btn secondary sm" href="${dayHref(c.slug, nv.next.week, nv.next.position)}" title="${esc(nv.next.title)}">${esc(nv.next.weekday.slice(0, 3))}${nv.next.week !== w.n ? ` W${nv.next.week}` : ""} →</a>` : ""}</div>
        </div>
        <nav class="jump">${sections.map(([id, l]) => `<a href="#" data-jump="${id}">${esc(l)}</a>`).join("")}</nav>
      </div>
      ${pack ? `<section class="card" id="s-pack"><div class="spread"><h2>Study pack</h2><span class="small muted">${pack.pages ? `${pack.pages} pages · ` : ""}${fmtSize(pack.size)}</span></div><div id="packv"></div></section>` : ""}
      ${ig ? `<section class="card" id="s-infographic"><div class="spread"><h2>Infographic</h2><button class="btn sm secondary" id="igfull">${icon.link} Full size</button></div>
          <button type="button" class="igbox" id="igbox" aria-label="Open the infographic full size"><span class="muted small">Loading…</span></button></section>` : ""}
      ${d.goals.length ? `<section class="card" id="s-goals"><h2>Learning goals</h2><ol class="goals">${d.goals.map((g) => `<li>${esc(g)}</li>`).join("")}</ol></section>` : ""}
      ${d.videos.length ? `<section class="card" id="s-videos"><h2>Videos</h2><div class="vids">${d.videos.map(videoCard).join("")}</div></section>` : ""}
      ${d.readings.length ? `<section class="card" id="s-readings"><h2>Readings</h2><ul class="reads">${d.readings.map((x) => `<li>${x.url ? `<a href="${esc(x.url)}" target="_blank" rel="noopener noreferrer">${esc(x.title)} ${icon.link}</a>` : `<span>${esc(x.title)}</span>`}${x.note ? `<small class="muted">${esc(x.note)}</small>` : ""}</li>`).join("")}</ul></section>` : ""}
      ${d.practice ? `<section class="card" id="s-practice"><h2>Practice</h2><p>${esc(d.practice)}</p><p class="small muted">The practice task is in the study pack. Send your answers to your mentor as usual.</p></section>` : ""}
      <section class="card" id="s-week"><h2>This week</h2>
        ${w.quizzes.length ? w.quizzes.map(quizLine).join("") : `<p class="small muted">No quiz is linked to this week yet.</p>`}
        ${fileList(w.files)}
      </section>
      <div class="day-foot row">${nv.next ? `<a class="btn" href="${dayHref(c.slug, nv.next.week, nv.next.position)}">Next: ${esc(nv.next.title)} →</a>` : ""}<a class="btn secondary" href="${weekHref(c.slug, w.n)}">Week ${w.n} overview</a></div>`;

    app.querySelectorAll("[data-jump]").forEach((a) => a.addEventListener("click", (e) => { e.preventDefault(); document.getElementById("s-" + a.dataset.jump)?.scrollIntoView({ behavior: "smooth", block: "start" }); }));
    if (pack) pdfViewer(app.querySelector("#packv"), pack.path, { title: `${d.weekday}: ${d.title}`, pages: pack.pages });
    if (ig) {
      sign(ig.path).then((url) => {
        const b = app.querySelector("#igbox"); if (!b) return;
        b.innerHTML = `<img src="${esc(url)}" alt="Infographic: ${esc(d.title)}" loading="lazy">`;
        const open = () => openImage(url, `Infographic: ${d.title}`);
        b.onclick = open; app.querySelector("#igfull").onclick = open;
      }).catch(() => { const b = app.querySelector("#igbox"); if (b) b.innerHTML = `<span class="error">The infographic couldn't be loaded.</span>`; });
    }
    wireVideos(app); wireFiles(app);
    const btn = app.querySelector("#donebtn");
    let done = !!d.done;
    btn.addEventListener("click", async () => {
      btn.disabled = true;
      try {
        const res = await rpc("set_day_done", { p_course: slug, p_week: n, p_position: pos, p_done: !done });
        done = res.done;
        btn.className = `btn ${done ? "secondary" : ""}`; btn.setAttribute("aria-pressed", String(done));
        btn.innerHTML = done ? `${icon.check} Done · undo` : "Mark as done";
        app.querySelector("#donebadge").innerHTML = done ? `<span class="badge green">Done today</span>` : "";
        toast(done ? `Marked done · ${res.streak.current} day streak` : "Marked as not done");
      } catch (e) { toast(e.message || "Couldn't save"); }
      btn.disabled = false;
    });
  }

  async function pageProgress() {
    setWide(true);
    app.innerHTML = `<h1>Progress</h1><div class="center muted">Loading…</div>`;
    const data = await rpc("learning_dashboard");
    const quizzes = data.weeks.flatMap((w) => w.quizzes.map((q) => ({ ...q, w })));
    const totDone = data.courses.reduce((n, c) => n + c.days_done, 0), tot = data.courses.reduce((n, c) => n + c.days_total, 0);
    app.innerHTML = `${crumbs([["Courses", "#/courses"], ["Progress"]])}<h1>Progress</h1>
      <div class="toprow">
        <div class="card overall">${ring(totDone, tot, "#14b8a6", 84)}<div><b>${totDone} of ${tot}</b><span class="muted small">study days done across all courses</span></div></div>
        ${streakCard(data.streak)}
      </div>
      <div class="statgrid">${data.courses.map((c) => `<a class="card stat" href="${courseHref(c.slug)}" style="--c:${esc(c.color)}">
        <span class="eyebrow">${esc(c.title)}</span><b>${c.days_done}<small>/${c.days_total}</small></b>${bar(c.days_done, c.days_total, c.color)}
        <span class="small muted">${c.next ? `Next: W${c.next.week} ${esc(c.next.weekday)} · ${esc(c.next.title)}` : "All published days done"}</span></a>`).join("")}</div>
      <section class="card"><h2>Quiz scores</h2>${quizzes.length ? `<div class="qtable">${quizzes.map((q) => `<div class="qrow">
          <span class="qdot" style="background:${esc(q.w.color)}"></span>
          <a class="qname" href="${q.best ? `#/results/${esc(q.best.attempt_id)}` : `#/exam/${esc(q.slug)}`}"><b>${esc(q.title)}</b><small class="muted">${esc(q.w.course_title)} · Week ${q.w.n}</small></a>
          <div class="qscore">${q.best ? `<b>${esc(String(q.best.pct))}%</b><small class="muted">${esc(String(+q.best.score))}/${esc(String(+q.best.max))}</small>` : q.submitted ? `<span class="badge gray">Awaiting results</span>` : q.in_progress ? `<span class="badge amber">In progress</span>` : `<span class="badge teal">Not attempted</span>`}</div>
          <a class="small qgo" href="${q.best ? `#/results/${esc(q.best.attempt_id)}` : `#/exam/${esc(q.slug)}`}">${q.best ? "Results" : "Open"} →</a></div>`).join("")}</div>` : `<p class="muted small">No quizzes are linked to your course weeks yet.</p>`}</section>
      <section class="card"><h2>By week</h2><div class="wtable">${data.weeks.map((w) => `<a class="wrow" href="${weekHref(w.course, w.n)}">
          <span class="qdot" style="background:${esc(w.color)}"></span><span class="wname"><b>Week ${w.n} · ${esc(w.title)}</b><small class="muted">${esc(w.course_title)}</small></span>
          <span class="wbar">${bar(w.days_done, w.days_total, w.color)}</span><span class="wnum">${w.days_done}/${w.days_total}</span></a>`).join("")}</div></section>
      <section class="card"><h2>Recently done</h2>${data.recent.length ? `<ul class="recent">${data.recent.map((x) => `<li><a href="${dayHref(x.course, x.week, x.position)}"><span class="qdot" style="background:${esc(x.color)}"></span><b>${esc(x.title)}</b> <small class="muted">${esc(x.course_title)} · W${x.week} ${esc(x.weekday)}</small></a><small class="muted">${esc(fmtCairo(x.done_at))}</small></li>`).join("")}</ul>` : `<p class="muted small">Mark a day as done and it shows up here.</p>`}</section>`;
  }

  return { pageCourses, pageCourse, pageWeek, pageDay, pageProgress };
}
