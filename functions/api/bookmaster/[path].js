/**
 * /api/bookmaster/<path> — generic bridge to BookMaster.
 *
 * Pages Function: the PAGETURNER_SECRET bridge credential lives only in this
 * deployment's environment — client JS never sees it. Proxies verbatim to
 * BookMaster's /api/pageturner/<path> so status and body reach the page
 * unchanged. The whitelist names the routes the bridge may reach — a new
 * BookMaster endpoint joins it deliberately, not by URL shape.
 */

const BM = (env) => env.BOOKMASTER_URL || "https://bookmaster.pages.dev";

// Routes the bridge will carry. GET routes take their params in the query
// string; everything else is a POST body forwarded untouched.
const ROUTES = new Set([
  "link",
  "progress",
  "session",
  "cover",
  "quote",
  "comment",
  "comments",
  "library",
  "overview",
  "together",
  "chat",
  "chat-read",
  "chat-remove",
  "nudge",
  "nudge-answer",
  "book",
  "shelf",
  "remove",
  "quotes",
  "achievements",
  "stats",
  "partner-shelf",
  "wrapped",
  "recommendations",
  "presence",
  "push-key",
  "push-subscribe",
  "push-unsubscribe",
  "push-inbox",
  "series",
  "series-detail",
  "series-book",
  "goal",
  "up-next",
  "edit-book",
  "export",
  "profile",
  "import",
]);

const json = (status, body) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

export const onRequest = async ({ request, env, params }) => {
  const path = Array.isArray(params.path) ? params.path.join("/") : params.path || "";
  if (!ROUTES.has(path)) return json(404, { error: "Unknown bridge route" });
  if (!env.PAGETURNER_SECRET)
    return json(503, { error: "BookMaster sync isn't configured on this deployment" });

  const method = request.method.toUpperCase();
  if (method !== "GET" && method !== "POST")
    return json(405, { error: "Method not allowed" });
  const isGet = method === "GET";

  // A few bridge names hide a different upstream path: redeeming a link code
  // lives at pageturner/redeem, and the push helpers are BookMaster's
  // endpoint-keyed routes, not pageturner ones. Everything else maps
  // straight into the bridge namespace.
  const upstreamPath = {
    link: "pageturner/redeem",
    "push-key": "push/key",
  }[path] || `pageturner/${path}`;

  const url = new URL(`${BM(env)}/api/${upstreamPath}`);
  if (isGet) new URL(request.url).searchParams.forEach((v, k) => url.searchParams.set(k, v));

  const body = isGet ? undefined : await request.text();
  let upstream;
  try {
    upstream = await fetch(url, {
      method,
      headers: {
        authorization: `Bearer ${env.PAGETURNER_SECRET}`,
        ...(isGet ? {} : { "content-type": "application/json" }),
        // The linking device's own credential — BookMaster demands it once
        // PAGETURNER_REQUIRE_KEY flips on upstream.
        ...(request.headers.get("x-pt-key")
          ? { "x-pt-key": request.headers.get("x-pt-key") }
          : {}),
      },
      body,
      // A hung upstream otherwise holds the function for its whole CPU budget
      // and leaves the app parked on a 60s URLSession default.
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    // 502 is the answer clients park a push on and try again later
    return json(502, { error: "BookMaster can't be reached" });
  }
  return new Response(upstream.body, {
    status: upstream.status,
    headers: { "content-type": upstream.headers.get("content-type") || "application/json" },
  });
};
