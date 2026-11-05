/** Examiner (admin) UI — author exams in the browser. Imported by app.js. */

const SLUG_RE = /^[a-z0-9][a-z0-9-]{1,80}$/;
const QID_RE = /^[A-Za-z0-9_-]{1,40}$/;
const LETTERS = "abcdefghijklmnopqrstuvwxyz";

function blankExam() {
  return {
    slug: "",
    title: "",
    instructions: "",
    time_limit_minutes: 30,
    opens_at: "",
    closes_at: "",
    attempts_allowed: 1,
    shuffle_questions: false,
    shuffle_options: false,
    log_focus: true,
    published: false,
    notify_emails: null, // null = inherit global
    equation_sheet: null, // {title, pages:[{path,w,h}]}
    questions: [],
  };
}

function blankQ(type = "mcq") {
  const id = "q" + Math.random().toString(36).slice(2, 7);
  const base = { id, type, prompt: "", marks: 1, explanation: "", image_path: null };
  if (type === "mcq") return { ...base, options: [{ id: "a", text: "" }, { id: "b", text: "" }], answer: "a" };
  if (type === "multi") return { ...base, options: [{ id: "a", text: "" }, { id: "b", text: "" }], answer: ["a"] };
  if (type === "tf") return { ...base, answer: true };
  if (type === "numeric") return { ...base, answer: 0, unit: "", tolerance_abs: null, tolerance_pct: null };
  return { ...base, answer: "" }; // short
}

async function sha20(buf) {
  const h = await crypto.subtle.digest("SHA-256", buf);
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 20);
}

export function createExaminer(ctx) {
  const { rpc, esc, rich, fmtCairo, num, toast, errMsg, go, sb, signedImage, modal } = ctx;
  let me = null;
  let draft = blankExam();
  let dirty = false;
  let globalEmails = ["ohady1992@gmail.com"];

  async function ensureAdmin() {
    me = await rpc("admin_is_admin");
    if (!me?.admin) throw Object.assign(new Error("Examiner is only available to admin accounts."), { code: "NOT_ADMIN" });
    try {
      const g = await rpc("admin_get_notify_emails", { p_slug: null });
      globalEmails = (g.emails || []).map(String);
    } catch { /* keep default */ }
    return me;
  }

  async function uploadBytes(slug, bytes, ext, prefix = "") {
    const hash = await sha20(bytes);
    const path = `${slug}/${prefix}${hash}${ext}`;
    const { error } = await sb.storage.from("exam-images").upload(path, bytes, {
      contentType: ext === ".png" ? "image/png" : ext === ".jpg" || ext === ".jpeg" ? "image/jpeg" : ext === ".webp" ? "image/webp" : "application/octet-stream",
      upsert: true,
    });
    if (error) throw error;
    return path;
  }

  async function uploadImageFile(slug, file, prefix = "") {
    const ext = (file.name.match(/\.(png|jpe?g|webp)$/i) || [, "png"])[0].toLowerCase().replace("jpeg", "jpg");
    const buf = await file.arrayBuffer();
    const path = await uploadBytes(slug, new Uint8Array(buf), ext.startsWith(".") ? ext : "." + ext, prefix);
    // read dimensions
    const url = URL.createObjectURL(file);
    const dim = await new Promise((res) => {
      const img = new Image();
      img.onload = () => { res({ w: img.naturalWidth, h: img.naturalHeight }); URL.revokeObjectURL(url); };
      img.onerror = () => { res({ w: 0, h: 0 }); URL.revokeObjectURL(url); };
      img.src = url;
    });
    return { path, ...dim };
  }

  async function pdfToPngPages(file, dpi = 140) {
    const pdfjs = await import("https://cdn.jsdelivr.net/npm/pdfjs-dist@4.4.168/+esm");
    pdfjs.GlobalWorkerOptions.workerSrc = "https://cdn.jsdelivr.net/npm/pdfjs-dist@4.4.168/build/pdf.worker.min.mjs";
    const data = new Uint8Array(await file.arrayBuffer());
    const doc = await pdfjs.getDocument({ data }).promise;
    const pages = [];
    const scale = dpi / 72;
    for (let i = 1; i <= doc.numPages; i++) {
      const page = await doc.getPage(i);
      const viewport = page.getViewport({ scale });
      const canvas = document.createElement("canvas");
      canvas.width = Math.floor(viewport.width);
      canvas.height = Math.floor(viewport.height);
      await page.render({ canvasContext: canvas.getContext("2d"), viewport }).promise;
      const blob = await new Promise((r) => canvas.toBlob(r, "image/png"));
      pages.push({ blob, w: canvas.width, h: canvas.height });
    }
    return pages;
  }

  function toPayload(force) {
    if (!SLUG_RE.test(draft.slug)) throw new Error("Slug must match ^[a-z0-9][a-z0-9-]{1,80}$");
    if (!draft.title.trim()) throw new Error("Title is required");
    if (!draft.questions.length) throw new Error("Add at least one question");
    const seen = new Set();
    const questions = draft.questions.map((q, i) => {
      if (!QID_RE.test(q.id)) throw new Error(`Question ${i + 1}: bad id`);
      if (seen.has(q.id)) throw new Error(`Duplicate question id ${q.id}`);
      seen.add(q.id);
      if (!q.prompt?.trim()) throw new Error(`Question ${q.id}: prompt required`);
      const out = {
        id: q.id, type: q.type, prompt: q.prompt, marks: Number(q.marks) || 1,
        image_path: q.image_path || null,
        explanation: q.explanation || null,
      };
      if (q.type === "mcq" || q.type === "multi") {
        const opts = (q.options || []).filter((o) => (o.text || "").trim());
        if (opts.length < 2) throw new Error(`${q.id}: need ≥2 options`);
        out.options = opts.map((o, j) => ({ id: o.id || LETTERS[j], text: o.text }));
        out.answer = q.type === "multi" ? (Array.isArray(q.answer) ? q.answer : []) : q.answer;
        if (q.type === "multi" && !out.answer.length) throw new Error(`${q.id}: pick at least one correct option`);
        if (q.type === "mcq" && !out.answer) throw new Error(`${q.id}: pick the correct option`);
      } else if (q.type === "tf") {
        out.answer = !!q.answer;
      } else if (q.type === "numeric") {
        out.answer = Number(q.answer);
        if (Number.isNaN(out.answer)) throw new Error(`${q.id}: numeric answer required`);
        out.unit = q.unit || null;
        out.tolerance_abs = q.tolerance_abs === "" || q.tolerance_abs == null ? null : Number(q.tolerance_abs);
        out.tolerance_pct = q.tolerance_pct === "" || q.tolerance_pct == null ? null : Number(q.tolerance_pct);
      } else {
        out.answer = q.answer || null;
      }
      return out;
    });
    const p = {
      slug: draft.slug,
      title: draft.title.trim(),
      instructions: draft.instructions || "",
      time_limit_minutes: Number(draft.time_limit_minutes) || 30,
      opens_at: draft.opens_at ? new Date(draft.opens_at).toISOString() : null,
      closes_at: draft.closes_at ? new Date(draft.closes_at).toISOString() : null,
      attempts_allowed: Number(draft.attempts_allowed) || 1,
      shuffle_questions: !!draft.shuffle_questions,
      shuffle_options: !!draft.shuffle_options,
      log_focus: !!draft.log_focus,
      published: !!draft.published,
      questions,
    };
    if (draft.equation_sheet?.pages?.length) p.equation_sheet = draft.equation_sheet;
    else p.equation_sheet = null;
    if (draft.notify_emails !== null) p.notify_emails = draft.notify_emails;
    return p;
  }

  async function save(force = false) {
    const p = toPayload(force);
    const res = await rpc("admin_upsert_exam", { p, p_force: force });
    dirty = false;
    toast(`Saved ${res.slug} (${res.questions} questions)`);
    return res;
  }

  function fromExport(data) {
    const e = data.exam || {};
    draft = {
      slug: e.slug || "",
      title: e.title || "",
      instructions: e.instructions || "",
      time_limit_minutes: e.time_limit_minutes || 30,
      opens_at: e.opens_at ? e.opens_at.slice(0, 16) : "",
      closes_at: e.closes_at ? e.closes_at.slice(0, 16) : "",
      attempts_allowed: e.attempts_allowed || 1,
      shuffle_questions: !!e.shuffle_questions,
      shuffle_options: !!e.shuffle_options,
      log_focus: e.log_focus !== false,
      published: !!e.published,
      notify_emails: e.notify_emails ?? null,
      equation_sheet: e.equation_sheet || null,
      questions: (data.questions || []).map((q) => ({
        id: q.id,
        type: q.type,
        prompt: q.prompt,
        marks: q.marks,
        explanation: q.explanation || "",
        image_path: q.image_path || null,
        options: Array.isArray(q.options) ? q.options.map((o) => typeof o === "string" ? { id: "", text: o } : { id: o.id, text: o.text }) : [],
        answer: q.answer,
        unit: q.unit || "",
        tolerance_abs: q.tolerance_abs,
        tolerance_pct: q.tolerance_pct,
      })),
    };
    dirty = false;
  }

  // ---------------- views
  async function pageList(root) {
    root.innerHTML = `<div class="center muted">Loading examiner…</div>`;
    const [rows, finishes] = await Promise.all([
      rpc("admin_list"),
      rpc("admin_list_finishes", { p_unacked_only: true }).catch(() => []),
    ]);
    root.innerHTML = `
      <div class="spread"><h1 style="margin:0">Examiner</h1>
        <div class="row">
          <button class="btn" id="new">New exam</button>
          <a class="btn secondary" href="#/">Student view</a>
        </div>
      </div>
      <p class="muted small">Signed in as admin <b>${esc(me.email)}</b>. Finish emails go to Omar only; Study Mentor is woken via the <code>finish_notifications</code> queue.</p>
      ${finishes?.length ? `<div class="card" style="border-left:4px solid var(--amber)">
        <div class="spread"><b>${finishes.length} unacked finish(es)</b>
          <button class="btn secondary" id="ackall">Ack all</button></div>
        <ul class="small" style="margin:8px 0 0;padding-left:18px">${finishes.map((f) =>
          `<li><b>${esc(f.exam_slug)}</b> · ${esc(f.student_email || "?")} · pending short ${f.pending_manual}
            · email ${esc(f.email_status)}
            <button type="button" class="linkbtn" data-ack="${esc(f.id)}">ack</button>
            · <code>${esc(f.commands?.export || "")}</code></li>`).join("")}</ul>
      </div>` : ""}
      <div class="card">
        <div class="spread"><h2 style="margin:0">Global finish emails</h2>
          <button class="btn secondary" id="save-emails">Save</button></div>
        <label class="field">Recipients (comma-separated)<input id="gemails" value="${esc(globalEmails.join(", "))}"></label>
        <p class="small muted">Default is ohady1992@gmail.com. Do not add Study Mentor here — use the finish queue / routine.</p>
      </div>
      ${(rows || []).length ? rows.map((e) => `
        <div class="card">
          <div class="spread"><h2 style="margin:0">${esc(e.title)}</h2>
            ${e.published ? `<span class="badge teal">Published</span>` : `<span class="badge gray">Draft</span>`}
          </div>
          <div class="meta">
            <div><b>Slug</b><code>${esc(e.slug)}</code></div>
            <div><b>Questions</b>${e.questions} · ${num(e.total_marks)} marks</div>
            <div><b>Time</b>${e.time_limit_minutes} min</div>
            <div><b>Attempts</b>${e.submitted}/${e.attempts} submitted · pending short ${e.pending_manual}</div>
            <div><b>Sheet</b>${e.equation_sheet_pages || 0} page(s)</div>
          </div>
          <div class="row">
            <a class="btn" href="#/examiner/edit/${esc(e.slug)}">Edit</a>
            <button class="btn secondary" data-pub="${esc(e.slug)}" data-on="${e.published ? 0 : 1}">${e.published ? "Unpublish" : "Publish"}</button>
            <button class="btn secondary" data-rel="${esc(e.slug)}">Release results</button>
            <button class="btn danger" data-del="${esc(e.slug)}">Delete</button>
          </div>
        </div>`).join("") : `<div class="card muted">No exams yet. Click <b>New exam</b>.</div>`}`;

    root.querySelector("#new").onclick = () => { draft = blankExam(); draft.questions = [blankQ("mcq")]; dirty = true; go("#/examiner/edit/"); };
    root.querySelector("#save-emails")?.addEventListener("click", async () => {
      const emails = root.querySelector("#gemails").value.split(/[,;\s]+/).map((s) => s.trim()).filter(Boolean);
      try {
        const r = await rpc("admin_set_notify_emails", { p_emails: emails, p_slug: null });
        globalEmails = (r.emails || emails).map(String);
        toast("Global notify emails saved");
      } catch (e) { toast(errMsg(e)); }
    });
    root.querySelectorAll("[data-ack]").forEach((b) => b.onclick = async () => {
      try { await rpc("admin_ack_finish", { p_id: b.dataset.ack }); toast("Acked"); pageList(root); }
      catch (e) { toast(errMsg(e)); }
    });
    root.querySelector("#ackall")?.addEventListener("click", async () => {
      for (const f of finishes) { try { await rpc("admin_ack_finish", { p_id: f.id }); } catch {} }
      pageList(root);
    });
    root.querySelectorAll("[data-pub]").forEach((b) => b.onclick = async () => {
      try { await rpc("admin_set_published", { p_slug: b.dataset.pub, p_published: b.dataset.on === "1" }); pageList(root); }
      catch (e) { toast(errMsg(e)); }
    });
    root.querySelectorAll("[data-rel]").forEach((b) => b.onclick = async () => {
      if (!confirm(`Release results for ${b.dataset.rel}?`)) return;
      try { await rpc("admin_release", { p_slug: b.dataset.rel, p_released: true, p_attempt: null }); toast("Released"); pageList(root); }
      catch (e) { toast(errMsg(e)); }
    });
    root.querySelectorAll("[data-del]").forEach((b) => b.onclick = async () => {
      if (!confirm(`Delete exam ${b.dataset.del} and all attempts?`)) return;
      try { await rpc("admin_delete_exam", { p_slug: b.dataset.del }); toast("Deleted"); pageList(root); }
      catch (e) { toast(errMsg(e)); }
    });
  }

  function qEditor(q, idx) {
    const opts = (q.options || []).map((o, j) => `
      <div class="row" style="margin-bottom:6px">
        <label class="small" style="display:flex;align-items:center;gap:6px;flex:none">
          <input type="${q.type === "multi" ? "checkbox" : "radio"}" name="ans-${idx}" value="${esc(o.id || LETTERS[j])}"
            ${q.type === "multi" ? (Array.isArray(q.answer) && q.answer.includes(o.id || LETTERS[j]) ? "checked" : "")
              : (q.answer === (o.id || LETTERS[j]) ? "checked" : "")}>
          correct
        </label>
        <input data-opt="${idx}:${j}" value="${esc(o.text || "")}" placeholder="Option text" style="flex:1">
        <button type="button" class="btn secondary" data-rmopt="${idx}:${j}" style="min-height:36px;padding:6px 10px">✕</button>
      </div>`).join("");
    return `<div class="card qedit" data-qi="${idx}">
      <div class="spread">
        <div class="row">
          <span class="badge">#${idx + 1}</span>
          <input data-f="id" data-i="${idx}" value="${esc(q.id)}" style="width:100px" title="Question id">
          <select data-f="type" data-i="${idx}">
            ${["mcq","multi","tf","numeric","short"].map((t) => `<option value="${t}" ${q.type === t ? "selected" : ""}>${t}</option>`).join("")}
          </select>
          <label class="small">Marks <input data-f="marks" data-i="${idx}" type="number" min="0" step="0.5" value="${esc(q.marks)}" style="width:70px"></label>
        </div>
        <button type="button" class="btn danger" data-rmq="${idx}" style="min-height:36px;padding:6px 10px">Remove</button>
      </div>
      <label class="field">Prompt<textarea data-f="prompt" data-i="${idx}" rows="3">${esc(q.prompt)}</textarea></label>
      ${q.type === "mcq" || q.type === "multi" ? `<div><b class="small">Options</b>${opts}
        <button type="button" class="btn secondary" data-addopt="${idx}">Add option</button></div>` : ""}
      ${q.type === "tf" ? `<div class="tfrow" style="margin:8px 0">
        <label class="opt ${q.answer === true ? "sel" : ""}"><input type="radio" name="tf-${idx}" data-tf="${idx}" value="true" ${q.answer === true ? "checked" : ""}> True</label>
        <label class="opt ${q.answer === false ? "sel" : ""}"><input type="radio" name="tf-${idx}" data-tf="${idx}" value="false" ${q.answer === false ? "checked" : ""}> False</label>
      </div>` : ""}
      ${q.type === "numeric" ? `<div class="row" style="margin:8px 0">
        <label class="field" style="flex:1;margin:0">Answer<input data-f="answer" data-i="${idx}" type="number" step="any" value="${esc(q.answer)}"></label>
        <label class="field" style="width:100px;margin:0">Unit<input data-f="unit" data-i="${idx}" value="${esc(q.unit || "")}"></label>
        <label class="field" style="width:110px;margin:0">Tol abs<input data-f="tolerance_abs" data-i="${idx}" type="number" step="any" value="${esc(q.tolerance_abs ?? "")}"></label>
        <label class="field" style="width:110px;margin:0">Tol %<input data-f="tolerance_pct" data-i="${idx}" type="number" step="any" value="${esc(q.tolerance_pct ?? "")}"></label>
      </div>` : ""}
      ${q.type === "short" ? `<label class="field">Model answer (for marker)<textarea data-f="answer" data-i="${idx}" rows="2">${esc(q.answer || "")}</textarea></label>` : ""}
      <label class="field">Explanation (shown after release)<textarea data-f="explanation" data-i="${idx}" rows="2">${esc(q.explanation || "")}</textarea></label>
      <div class="row">
        <label class="btn secondary" style="cursor:pointer">Upload image<input type="file" accept="image/*" hidden data-img="${idx}"></label>
        ${q.image_path ? `<span class="small muted"><code>${esc(q.image_path)}</code>
          <button type="button" class="linkbtn" data-clrim="${idx}">clear</button></span>` : `<span class="small muted">No image</span>`}
      </div>
    </div>`;
  }

  async function pageEdit(root, slug) {
    if (slug) {
      root.innerHTML = `<div class="center muted">Loading ${esc(slug)}…</div>`;
      const data = await rpc("admin_export", { p_slug: slug });
      fromExport(data);
    } else if (!draft.slug && !draft.questions.length) {
      draft = blankExam();
      draft.questions = [blankQ("mcq")];
    }
    renderEdit(root);
  }

  function renderEdit(root) {
    const ne = draft.notify_emails;
    root.innerHTML = `
      <div class="spread"><h1 style="margin:0">${draft.slug ? "Edit exam" : "New exam"}</h1>
        <div class="row">
          <a class="btn secondary" href="#/examiner">Back</a>
          <button class="btn secondary" id="force-save" title="Allow removing questions that have attempts">Save --force</button>
          <button class="btn" id="save">Save</button>
        </div>
      </div>
      ${dirty ? `<div class="notice">Unsaved changes</div>` : ""}
      <div class="card">
        <div class="row" style="align-items:flex-start">
          <label class="field" style="flex:1">Slug<input id="slug" value="${esc(draft.slug)}" ${draft.slug && slugLocked() ? "readonly" : ""} placeholder="my-quiz"></label>
          <label class="field" style="flex:2">Title<input id="title" value="${esc(draft.title)}" placeholder="Week 4 quiz"></label>
        </div>
        <label class="field">Instructions<textarea id="instructions" rows="3">${esc(draft.instructions)}</textarea></label>
        <div class="row">
          <label class="field">Time (min)<input id="tl" type="number" min="1" max="1440" value="${esc(draft.time_limit_minutes)}"></label>
          <label class="field">Attempts<input id="aa" type="number" min="1" value="${esc(draft.attempts_allowed)}"></label>
          <label class="field">Opens (Cairo local)<input id="oa" type="datetime-local" value="${esc(draft.opens_at)}"></label>
          <label class="field">Closes<input id="ca" type="datetime-local" value="${esc(draft.closes_at)}"></label>
        </div>
        <div class="row">
          <label class="small"><input type="checkbox" id="sq" ${draft.shuffle_questions ? "checked" : ""}> Shuffle questions</label>
          <label class="small"><input type="checkbox" id="so" ${draft.shuffle_options ? "checked" : ""}> Shuffle options</label>
          <label class="small"><input type="checkbox" id="lf" ${draft.log_focus ? "checked" : ""}> Log focus</label>
          <label class="small"><input type="checkbox" id="pub" ${draft.published ? "checked" : ""}> Published</label>
        </div>
        <label class="field">Per-exam notify emails (blank = use global: ${esc(globalEmails.join(", "))})
          <input id="nemails" placeholder="inherit global" value="${ne == null ? "" : esc(ne.join(", "))}">
        </label>
      </div>
      <div class="card">
        <div class="spread"><h2 style="margin:0">Equation sheet</h2>
          <div class="row">
            <label class="btn secondary" style="cursor:pointer">Add PDF/PNG<input type="file" accept=".pdf,image/*" hidden id="sheet-file" multiple></label>
            ${draft.equation_sheet ? `<button type="button" class="btn danger" id="clr-sheet">Clear sheet</button>` : ""}
          </div>
        </div>
        <label class="field">Sheet title<input id="sheet-title" value="${esc(draft.equation_sheet?.title || "Equation sheet")}"></label>
        <p class="small muted">${draft.equation_sheet?.pages?.length || 0} page(s) uploaded. PDFs are rendered to PNG in the browser.</p>
      </div>
      <div class="spread"><h2>Questions (${draft.questions.length})</h2>
        <div class="row">
          <button class="btn secondary" data-addq="mcq">+ MCQ</button>
          <button class="btn secondary" data-addq="multi">+ Multi</button>
          <button class="btn secondary" data-addq="tf">+ T/F</button>
          <button class="btn secondary" data-addq="numeric">+ Numeric</button>
          <button class="btn secondary" data-addq="short">+ Short</button>
        </div>
      </div>
      <div id="qs">${draft.questions.map(qEditor).join("")}</div>
      <div class="row" style="margin-top:12px">
        <button class="btn" id="save2">Save exam</button>
        <a class="btn secondary" href="#/examiner">Cancel</a>
      </div>`;

    const bind = () => {
      const mark = () => { dirty = true; };
      root.querySelector("#slug").oninput = (e) => { draft.slug = e.target.value.trim().toLowerCase(); mark(); };
      root.querySelector("#title").oninput = (e) => { draft.title = e.target.value; mark(); };
      root.querySelector("#instructions").oninput = (e) => { draft.instructions = e.target.value; mark(); };
      root.querySelector("#tl").oninput = (e) => { draft.time_limit_minutes = +e.target.value; mark(); };
      root.querySelector("#aa").oninput = (e) => { draft.attempts_allowed = +e.target.value; mark(); };
      root.querySelector("#oa").oninput = (e) => { draft.opens_at = e.target.value; mark(); };
      root.querySelector("#ca").oninput = (e) => { draft.closes_at = e.target.value; mark(); };
      root.querySelector("#sq").onchange = (e) => { draft.shuffle_questions = e.target.checked; mark(); };
      root.querySelector("#so").onchange = (e) => { draft.shuffle_options = e.target.checked; mark(); };
      root.querySelector("#lf").onchange = (e) => { draft.log_focus = e.target.checked; mark(); };
      root.querySelector("#pub").onchange = (e) => { draft.published = e.target.checked; mark(); };
      root.querySelector("#nemails").oninput = (e) => {
        const v = e.target.value.trim();
        draft.notify_emails = v ? v.split(/[,;\s]+/).map((s) => s.trim()).filter(Boolean) : null;
        mark();
      };
      root.querySelector("#sheet-title").oninput = (e) => {
        if (!draft.equation_sheet) draft.equation_sheet = { title: e.target.value, pages: [] };
        else draft.equation_sheet.title = e.target.value;
        mark();
      };
      root.querySelector("#clr-sheet")?.addEventListener("click", () => { draft.equation_sheet = null; mark(); renderEdit(root); });
      root.querySelector("#sheet-file").onchange = async (e) => {
        const files = [...e.target.files];
        if (!files.length) return;
        if (!SLUG_RE.test(draft.slug)) { toast("Set a valid slug before uploading the sheet"); return; }
        toast("Rendering / uploading sheet…");
        try {
          const pages = draft.equation_sheet?.pages ? [...draft.equation_sheet.pages] : [];
          for (const f of files) {
            if (/\.pdf$/i.test(f.name)) {
              const rendered = await pdfToPngPages(f);
              for (const pg of rendered) {
                const buf = new Uint8Array(await pg.blob.arrayBuffer());
                const path = await uploadBytes(draft.slug, buf, ".png", "sheet-");
                pages.push({ path, w: pg.w, h: pg.h });
              }
            } else {
              const up = await uploadImageFile(draft.slug, f, "sheet-");
              pages.push(up);
            }
          }
          draft.equation_sheet = { title: root.querySelector("#sheet-title").value || "Equation sheet", pages };
          dirty = true;
          toast(`${pages.length} sheet page(s) ready`);
          renderEdit(root);
        } catch (err) { toast(errMsg(err)); }
      };
      root.querySelectorAll("[data-addq]").forEach((b) => b.onclick = () => {
        draft.questions.push(blankQ(b.dataset.addq)); dirty = true; renderEdit(root);
      });
      root.querySelectorAll("[data-rmq]").forEach((b) => b.onclick = () => {
        draft.questions.splice(+b.dataset.rmq, 1); dirty = true; renderEdit(root);
      });
      root.querySelectorAll("[data-f]").forEach((el) => {
        el.oninput = () => {
          const i = +el.dataset.i, f = el.dataset.f;
          let v = el.value;
          if (f === "marks" || f === "answer" && draft.questions[i].type === "numeric") v = el.value === "" ? "" : Number(el.value);
          if (f === "tolerance_abs" || f === "tolerance_pct") v = el.value === "" ? null : Number(el.value);
          draft.questions[i][f] = v; dirty = true;
        };
      });
      root.querySelectorAll("[data-opt]").forEach((el) => {
        el.oninput = () => {
          const [i, j] = el.dataset.opt.split(":").map(Number);
          draft.questions[i].options[j].text = el.value;
          if (!draft.questions[i].options[j].id) draft.questions[i].options[j].id = LETTERS[j];
          dirty = true;
        };
      });
      root.querySelectorAll(`[name^="ans-"]`).forEach((el) => {
        el.onchange = () => {
          const idx = +el.name.split("-")[1];
          const q = draft.questions[idx];
          if (q.type === "multi") {
            q.answer = [...root.querySelectorAll(`input[name="ans-${idx}"]:checked`)].map((x) => x.value);
          } else q.answer = el.value;
          dirty = true;
        };
      });
      root.querySelectorAll("[data-tf]").forEach((el) => {
        el.onchange = () => { draft.questions[+el.dataset.tf].answer = el.value === "true"; dirty = true; renderEdit(root); };
      });
      root.querySelectorAll("[data-addopt]").forEach((b) => b.onclick = () => {
        const q = draft.questions[+b.dataset.addopt];
        const id = LETTERS[q.options.length] || `o${q.options.length}`;
        q.options.push({ id, text: "" }); dirty = true; renderEdit(root);
      });
      root.querySelectorAll("[data-rmopt]").forEach((b) => b.onclick = () => {
        const [i, j] = b.dataset.rmopt.split(":").map(Number);
        draft.questions[i].options.splice(j, 1); dirty = true; renderEdit(root);
      });
      root.querySelectorAll("[data-img]").forEach((el) => {
        el.onchange = async () => {
          const i = +el.dataset.img, file = el.files?.[0];
          if (!file) return;
          if (!SLUG_RE.test(draft.slug)) { toast("Set a valid slug first"); return; }
          try {
            const up = await uploadImageFile(draft.slug, file, "q-");
            draft.questions[i].image_path = up.path; dirty = true; toast("Image uploaded"); renderEdit(root);
          } catch (err) { toast(errMsg(err)); }
        };
      });
      root.querySelectorAll("[data-clrim]").forEach((b) => b.onclick = () => {
        draft.questions[+b.dataset.clrim].image_path = null; dirty = true; renderEdit(root);
      });
      const doSave = async (force) => {
        try {
          await save(force);
          go(`#/examiner/edit/${draft.slug}`);
        } catch (e) {
          const m = errMsg(e);
          if (/--force|needs --force/i.test(m) && !force) {
            if (confirm(m + "\n\nSave with force?")) return doSave(true);
          }
          toast(m, 5000);
        }
      };
      root.querySelector("#save").onclick = () => doSave(false);
      root.querySelector("#save2").onclick = () => doSave(false);
      root.querySelector("#force-save").onclick = () => doSave(true);
    };
    bind();
  }

  function slugLocked() { return false; }

  return {
    async open(root, slug) {
      await ensureAdmin();
      if (slug !== undefined && slug !== null && location.hash.includes("/edit")) {
        return pageEdit(root, slug || null);
      }
      return pageList(root);
    },
  };
}
