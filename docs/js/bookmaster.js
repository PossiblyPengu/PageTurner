/**
 * bookmaster.js — BookMaster sync: pushes live reading progress and finished
 * reading sessions to the tracker at bookmaster.pages.dev. Entirely opt-in —
 * nothing leaves the device until the user links an account in Settings.
 *
 * Pushes that can't reach the network aren't dropped: they land in a small
 * IndexedDB queue ("bm-queue") and are retried oldest-first when connectivity
 * returns. Progress is a position — only the newest per book is worth
 * keeping — while every session is a distinct stretch of reading that always
 * rides the queue.
 */
import { kvGet, kvSet, kvUpdate, putBook } from "./db.js";
import { $, toast, uid } from "./util.js";

const USER_KEY = "bm-user";
const QUEUE_KEY = "bm-queue";
const QUEUE_MAX = 50;

// The linked reader, cached so a push fired from pagehide doesn't have to
// wait on IndexedDB before its fetch gets dispatched — the page may freeze
// first.
let userCache; // undefined = not read yet, null = unlinked
const linkedUser = async () => {
  if (userCache === undefined) userCache = await kvGet(USER_KEY, null);
  return userCache;
};

export const bookmasterLinked = async () => !!(await linkedUser());
export const bookmasterUser = () => linkedUser();

/**
 * Hand the device to BookMaster's pair flow; it mints a one-time code and
 * returns it to `from` as ?bm-link=<code>. We navigate away entirely — the
 * page reloads into finishBookmasterLink on return.
 */
export const bookmasterLink = () => {
  location.href =
    `https://bookmaster.pages.dev/link/pageturner?from=${encodeURIComponent(location.origin)}`;
};

/**
 * The return half of the pair flow: redeem the one-time code through our own
 * Pages Function (the bridge secret can't ship in client JS), remember who
 * we linked as, and always strip the code from the URL so a refresh or a
 * copied link can't redeem it twice.
 */
export const finishBookmasterLink = async () => {
  const url = new URL(location.href);
  const code = url.searchParams.get("bm-link");
  if (!code) return false;
  url.searchParams.delete("bm-link");
  history.replaceState(null, "", url.pathname + url.search + url.hash);
  try {
    const res = await fetch("/api/bookmaster/link", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code }),
    });
    const data = await res.json().catch(() => null);
    if (!res.ok) throw new Error(data?.error || `Link failed (${res.status})`);
    userCache = {
      username: data.username,
      display_name: data.display_name,
      // This device's own credential — BookMaster asks for it (X-PT-Key) once
      // PAGETURNER_REQUIRE_KEY is on; until then it rides the link record.
      deviceKey: data.device_key,
    };
    await kvSet(USER_KEY, userCache);
    brokeWarned = false; // a fresh link earns a fresh warning if it later dies
    toast("Linked to BookMaster");
    return true;
  } catch (err) {
    console.warn("BookMaster link failed", err);
    toast(err.message || "Couldn't link BookMaster", { error: true });
    return false;
  }
};

export const bookmasterUnlink = async () => {
  userCache = null;
  lastPush.clear();
  brokeWarned = false;
  await kvSet(USER_KEY, null);
  await kvSet(QUEUE_KEY, []);
};

// Throttled push: at most once per 30s per book, unless forced (book closed,
// playback paused). Fire-and-forget — reading progress must never block.
const lastPush = new Map(); // bookId -> { at, pct }
let brokeWarned = false; // toast the dead link once per session, not per turn

/**
 * The one POST both pushes share: JSON through our Pages Function, which is
 * the only place the bridge secret lives. `keepalive` lets a push fired as
 * the page hides — a session logged at the moment the app is killed — be
 * delivered anyway.
 */
export const postBookmaster = (path, body) => {
  const json = JSON.stringify(body);
  return fetch(`/api/bookmaster/${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(userCache?.deviceKey ? { "x-pt-key": userCache.deviceKey } : {}),
    },
    // keepalive lets a close-time push outlive the page, but the platform
    // caps those bodies near 64KB — a cover-bearing push is far over and
    // would throw every time, parked in the queue blocking what came after.
    keepalive: new TextEncoder().encode(json).byteLength < 60_000,
    body: json,
  });
};

/**
 * What a refused push means. A 404 "Unknown reader" is a dead link — stop
 * quietly failing on every page turn from here on. Any other 404 means the
 * pinned shelf row is gone: drop the pin so the next push re-resolves by
 * ISBN and title and pins the row it gets back.
 */
const handleFailedPush = async (book, res) => {
  if (res.status === 404) {
    const data = await res.json().catch(() => null);
    if (data?.error === "Unknown reader") {
      userCache = null;
      await kvSet(USER_KEY, null);
      if (!brokeWarned) {
        brokeWarned = true;
        toast("BookMaster link broke — relink in Settings", { error: true });
      }
    } else if (book?.bookmasterId) {
      delete book.bookmasterId;
      await putBook(book).catch(() => {});
    }
  } else {
    console.warn("BookMaster sync failed", res.status);
  }
};

// ---------- offline queue ----------

const readQueue = async () => (await kvGet(QUEUE_KEY, [])) || [];

const sameBook = (a, b) => {
  if (a.username !== b.username) return false;
  if (a.user_book_id != null && b.user_book_id != null) return a.user_book_id === b.user_book_id;
  return a.title === b.title && sendableAuthor(a.author) === sendableAuthor(b.author);
};

/**
 * File metadata spells authors every way — "Herbert, Frank", "Frank Herbert
 * (Author)". Send the display order: the shelf stores what a push carries,
 * and a row created by the bridge shouldn't read backwards forever.
 */
export const sendableAuthor = (a) => {
  const clean = (a || "").replace(/\([^)]*\)/g, " ").replace(/\s+/g, " ").trim();
  const comma = /^([^,;&]+),\s*([^,;&]+)$/.exec(clean);
  return comma ? `${comma[2].trim()} ${comma[1].trim()}` : clean;
};

/**
 * How every push names the book — the identity fields, then the catalogue
 * facts this copy already knows, so a push fills gaps in BookMaster's row
 * rather than leaving them for a later lookup. The shelf row BookMaster
 * gave back pins it, beating every guess.
 */
const bookRef = (book) => ({
  user_book_id: book.bookmasterId || undefined,
  title: book.title,
  author: sendableAuthor(book.author),
  isbn: book.isbn || book.identifiers?.isbn13 || book.identifiers?.isbn10 || undefined,
  open_library_id: book.identifiers?.open_library || undefined,
  description: book.desc || undefined,
  published_year: parseInt(book.year, 10) || undefined,
});

/**
 * Park a push the network couldn't take. Sessions always queue — each one is
 * a distinct stretch of reading — but progress is positional, so a newer
 * position for the same book replaces the queued one rather than adding a
 * stale point for the replay to land. Capped; the oldest give way.
 */
const enqueue = async (entry) => {
  if ((await linkedUser())?.username !== entry.body.username) return;
  await kvUpdate(QUEUE_KEY, (q) => {
    if (userCache?.username !== entry.body.username) return q || [];
    q = q || [];
    if (entry.kind === "progress")
      q = q.filter((e) => e.kind !== "progress" || !sameBook(e.body, entry.body));
    return [...q, { ...entry, id: uid() }].slice(-QUEUE_MAX);
  }, []);
};

/** A bridge answer worth retrying later rather than dropping the push. */
const retriable = (res) => res.status === 408 || res.status === 429 || res.status >= 500;

const removeQueued = (head) => kvUpdate(QUEUE_KEY, (q) => {
  q = q || [];
  const i = q.findIndex((e) => head.id ? e.id === head.id : JSON.stringify(e) === JSON.stringify(head));
  if (i >= 0) q.splice(i, 1);
  return q;
}, []);

let flushPromise;
/**
 * Drain the queue oldest-first, stopping at the first push the network still
 * won't take — order is the point (a replayed position must not land after
 * a newer one). A 4xx can never succeed, so it's dropped rather than left to
 * block the line behind it.
 */
export const flushBookmaster = () => {
  if (flushPromise) return flushPromise;
  flushPromise = (async () => {
    for (;;) {
      const user = await linkedUser();
      if (!user?.username) return;
      const q = await readQueue();
      if (!q.length) return;
      const [head] = q;
      if (head.body.username !== user.username) {
        await removeQueued(head);
        continue;
      }
      let res;
      try {
        res = await postBookmaster(head.kind, head.body);
      } catch {
        return; // still offline — leave the queue alone
      }
      if (retriable(res)) return;
      await removeQueued(head);
      if (!res.ok) await handleFailedPush(null, res);
    }
  })().finally(() => { flushPromise = null; });
  return flushPromise;
};

/**
 * Send a push, parking it in the queue when the network can't take it.
 * Queued entries go first so positions reach BookMaster in the order the
 * reader lived them.
 */
const send = async (kind, body) => {
  await flushBookmaster();
  if ((await linkedUser())?.username !== body.username) return null;
  if ((await readQueue()).length) {
    await enqueue({ kind, body });
    return null;
  }
  let res;
  try {
    res = await postBookmaster(kind, body);
  } catch {
    await enqueue({ kind, body });
    return null;
  }
  if (retriable(res)) {
    await enqueue({ kind, body });
    return null;
  }
  return res;
};

/** A blob as the JSON-safe string a push can carry. */
const blobToBase64 = async (blob) => {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000)
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
};

/**
 * The cover fields a push carries, or null when there's nothing new to send.
 * A cover goes up once per blob — bmCoverTag (size:type) on the book record
 * is the "already sent" mark; a re-picked or re-compressed cover changes the
 * tag and sends again. Over 1MB stays home rather than bloat every push.
 */
const coverFields = async (book) => {
  const blob = book.coverBlob;
  if (!blob?.size || blob.size > 1_000_000) return null;
  const tag = `${blob.size}:${blob.type || "image/jpeg"}`;
  if (book.bmCoverTag === tag) return null;
  try {
    return {
      tag,
      fields: {
        cover_b64: await blobToBase64(blob),
        cover_mime: blob.type || "image/jpeg",
      },
    };
  } catch {
    return null;
  }
};

/**
 * Just the cover, for a book the bridge already knows — the pull sweep sends
 * these for books whose last push predates the feature. No progress fields,
 * so a want_to_read row stays want_to_read.
 */
export const syncCover = async (book) => {
  try {
    if (!book?.title || !(book.bookmasterId || book.bmBookId)) return;
    const user = await linkedUser();
    if (!user?.username) return;
    const cover = await coverFields(book);
    if (!cover) return;
    const res = await postBookmaster("cover", {
      username: user.username,
      ...bookRef(book),
      ...cover.fields,
    });
    if (res.ok && book.bmCoverTag !== cover.tag) {
      book.bmCoverTag = cover.tag;
      await putBook(book).catch(() => {});
    }
  } catch { /* a cover is extra — never worth an error */ }
};

export const syncProgress = async (book, { force = false } = {}) => {
  try {
    if (!book?.title) return;
    const user = await linkedUser();
    if (!user?.username) return;
    const pct = Math.round((book.progress?.fraction ?? 0) * 1000) / 10;
    const last = lastPush.get(book.id);
    if (!force) {
      if (last?.pct === pct) return; // nothing new to say
      if (last && Date.now() - last.at < 30_000) return;
    }
    lastPush.set(book.id, { at: Date.now(), pct });
    const payload = {
      username: user.username,
      ...bookRef(book),
      percent: pct,
      format: book.kind === "audio" ? "audio" : "ebook",
      // 'read' is the only status a push may claim — finishing here (a page
      // turn past 99.5%, or "Mark as finished") marks it read over there,
      // reads_on_finish trigger and all.
      status: (book.progress?.fraction || 0) >= 0.995 ? "read" : undefined,
      rating: book.rating || undefined,
    };
    // The cover the reader sees goes too — real art lives in coverBlob
    // (generated jackets never touch it), so the bytes ride the push once
    // and BookMaster serves them back. The tag remembers which blob went up.
    const cover = await coverFields(book);
    if (cover) Object.assign(payload, cover.fields);
    const coverTag = cover?.tag ?? null;
    const res = await send("progress", payload);
    if (!res) return; // offline — parked in the queue
    if (res.ok) {
      // BookMaster answers with the shelf row it wrote — remember its id so
      // the next push pins to it rather than trusting the title again.
      const { userBook, newAchievements } = await res.json().catch(() => ({}));
      let dirty = false;
      if (userBook?.id && userBook.id !== book.bookmasterId) {
        book.bookmasterId = userBook.id;
        dirty = true;
      }
      if (coverTag && book.bmCoverTag !== coverTag) {
        book.bmCoverTag = coverTag;
        dirty = true;
      }
      if (dirty) await putBook(book).catch(() => {});
      // the bridge hydrates ids into {id, name, icon} — Pageturner keeps no
      // achievement catalogue of its own
      for (const a of newAchievements || [])
        toast(`${a.icon || "🏆"} ${a.name || "Achievement earned"}`, { ms: 4500 });
    } else {
      await handleFailedPush(book, res);
    }
  } catch (err) {
    console.warn("BookMaster sync failed", err);
  }
};

/**
 * A finished stretch of reading, pushed when the reader closes a book or the
 * player pauses — BookMaster logs it as a real session, so streaks and stats
 * move the way they do for a session entered by hand. Sessions are events,
 * not positions: no throttle, and no force flag to swallow one.
 */
export const syncSession = async (book, { percentStart, percentEnd, minutes, at } = {}) => {
  try {
    if (!book?.title) return;
    const user = await linkedUser();
    if (!user?.username) return;
    const res = await send("session", {
      username: user.username,
      ...bookRef(book),
      percent_start: percentStart,
      percent_end: percentEnd,
      duration_minutes: Math.round(minutes) || undefined,
      at,
    });
    if (res && res.ok) {
      const { newAchievements } = await res.json().catch(() => ({}));
      for (const a of newAchievements || [])
        toast(`${a.icon || "🏆"} ${a.name || "Achievement earned"}`, { ms: 4500 });
    } else if (res) {
      await handleFailedPush(book, res);
    }
  } catch (err) {
    console.warn("BookMaster session sync failed", err);
  }
};

/**
 * A line worth keeping, pushed from the reader's selection chip — lands on
 * the book's shelf row as a BookMaster quote. Queues like a session: a quote
 * is an event, not a position.
 */
export const postQuote = async (book, { content, percent } = {}) => {
  try {
    if (!book?.title || !content) return false;
    const user = await linkedUser();
    if (!user?.username) return false;
    const res = await send("quote", {
      username: user.username,
      ...bookRef(book),
      content,
      // the reader measures in percent — BookMaster converts to pages when
      // the shelf row knows the book's length
      percent: typeof percent === "number" ? percent * 100 : undefined,
    });
    if (!res) return true; // parked for later — report success
    if (!res.ok) { await handleFailedPush(book, res); return false; }
    return true;
  } catch (err) {
    console.warn("BookMaster quote sync failed", err);
    return false;
  }
};

// Pushes stranded by an earlier outage or a killed page go first, and the
// queue drains again whenever the network comes back.
if (typeof window !== "undefined") {
  flushBookmaster().catch(() => {});
  window.addEventListener("online", () => flushBookmaster().catch(() => {}));
}

// ---------------------------------------------------------------------------
// Presence — "I'm here", in the same three-field shape every suite app keeps.
// Pageturner has no server to be polled, so it pushes beats: every 45s while
// visible (the suite counts you there for two minutes), once more as
// `leaving` when the page goes away. Never queued — a replayed beat is a lie
// about when you were there, and a beat is cheap to remake.
// ---------------------------------------------------------------------------

const BEAT_MS = 45_000;

const currentPlace = () => {
  // The overlay views cover the library when they're up — the deepest open
  // one is where you actually are.
  if (!$("view-reader")?.hidden) return "reader";
  if (!$("view-player")?.hidden) return "player";
  if (!$("view-settings")?.hidden) return "settings";
  return "library";
};

const beat = (extra = {}) =>
  linkedUser()
    .then((user) => user?.username
      && postBookmaster("presence", { username: user.username, ...extra }))
    .catch(() => {}); // a missed beat is absence of signal, not an error

export const initPresence = () => {
  if (typeof window === "undefined") return;
  const arrive = () => beat({ place: currentPlace() });
  arrive();
  setInterval(() => { if (document.visibilityState === "visible") arrive(); }, BEAT_MS);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") beat({ leaving: true });
    else arrive();
  });
};
