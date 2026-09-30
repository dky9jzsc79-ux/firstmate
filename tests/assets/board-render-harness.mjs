// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges,clip}],
//     charted:[{title,sub,badges,pickable,clip}], empty, more, error, clipTap }
// Layout is modelled in characters: a .bb-clip element is BB_CLIP_COLS
// (default 60) wide and its content is as wide as its text, so the template's
// own overflow measurement decides which text is clipped. clip reports each
// row's title/sub clipped state and reveal attributes; clipTap reports what a
// tap, then Enter, did to the first clipped non-link text.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.classList = {
      add: (c) => { if (!this.classList.contains(c)) this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" "); },
      toggle: (c, force) => {
        const on = force === undefined ? !this.classList.contains(c) : Boolean(force);
        if (on) this.classList.add(c); else this.classList.remove(c);
        return on;
      },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get title() { return this.attributes.title ?? ""; }
  set title(v) { this.attributes.title = String(v); }
  get tabIndex() { return Number(this.attributes.tabindex ?? -1); }
  set tabIndex(v) { this.attributes.tabindex = String(v); }
  get clientWidth() { return this.classList.contains("bb-clip") ? CLIP_COLS : 0; }
  get scrollWidth() { return this.textContent.length; }
  getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; }
  removeAttribute(k) { delete this.attributes[k]; }
  // "tag", ".a", and "tag.a.b" compound selectors only.
  matches(sel) {
    const [tag, ...classes] = sel.split(".");
    return (!tag || this.tagName === tag.toUpperCase())
      && classes.every((c) => this.classList.contains(c));
  }
  closest(sel) {
    for (let n = this; n; n = n.parentNode) if (n.matches && n.matches(sel)) return n;
    return null;
  }
  contains(other) {
    for (let n = other; n; n = n.parentNode) if (n === this) return true;
    return false;
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  addEventListener() {}
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const CLIP_COLS = Number(process.env.BB_CLIP_COLS || 60);
const byId = new Map();
const docListeners = {};
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
  querySelectorAll: (sel) => {
    const seen = new Set();
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (!seen.has(c) && c.matches(sel)) { seen.add(c); out.push(c); }
        walk(c);
      }
    };
    for (const root of byId.values()) walk(root.parentNode || root);
    return out;
  },
  addEventListener: (type, fn) => { (docListeners[type] ||= []).push(fn); },
};
globalThis.window = { addEventListener() {} };
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const clipOf = (n) => n && {
  clipped: n.classList.contains("is-clipped"),
  expanded: n.classList.contains("is-expanded"),
  tip: n.getAttribute("title"),
  tabindex: n.getAttribute("tabindex"),
  role: n.getAttribute("role"),
  ariaExpanded: n.getAttribute("aria-expanded"),
};
const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      const title = main?.children.find((c) => c.className.includes("bb-row__title"));
      const sub = main?.children.find((c) => c.className.includes("bb-row__sub"));
      return {
        title: title?.textContent ?? "",
        sub: sub?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
        clip: { title: clipOf(title), sub: clipOf(sub) },
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
// Drive the page's own document listeners the way a tap and a key press would.
const fire = (type, ev) => (docListeners[type] || []).forEach((fn) => fn(ev));
const tapTarget = document.querySelectorAll(".bb-clip.is-clipped").find((n) => n.tagName !== "A");
let clipTap = null;
if (tapTarget) {
  fire("click", { target: tapTarget });
  const afterTap = clipOf(tapTarget);
  fire("keydown", { key: "Enter", target: tapTarget, preventDefault() {} });
  clipTap = { text: tapTarget.textContent, afterTap, afterEnter: clipOf(tapTarget) };
}
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({ stats, underway, charted, empty, more, error: errorText, clipTap }) + "\n");
