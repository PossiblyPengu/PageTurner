/**
 * bm-push.js — Web Push through the BookMaster bridge.
 *
 * BookMaster's pushes carry nothing: a VAPID-signed wake-up POST reaches the
 * push service, the service worker hears `push`, asks /push-inbox what is
 * new *for this endpoint*, and says that — notice text never passes through
 * Apple or Google's servers. Subscribing leaves this device's endpoint with
 * BookMaster, which wakes it for the linked reader's notices.
 *
 * iOS only offers PushManager to an installed PWA — the settings row says so
 * rather than pretending a browser tab can take them.
 */
import { bookmasterUser } from "./bookmaster.js";

export const pushSupported = () =>
  typeof window !== "undefined" &&
  "serviceWorker" in navigator &&
  "PushManager" in window &&
  "Notification" in window;

/** The key, as the Push API wants it, from its base64url form. */
const keyBytes = (base64url) => {
  const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
  return Uint8Array.from(raw, (ch) => ch.charCodeAt(0));
};

const registration = async () =>
  (await navigator.serviceWorker.getRegistration()) ?? navigator.serviceWorker.ready;

const bridgeKey = async () => {
  const res = await fetch("/api/bookmaster/push-key", { cache: "no-store" });
  if (!res.ok) return null;
  return (await res.json().catch(() => ({}))).key || null;
};

const bridgePost = async (path, body) => {
  const user = await bookmasterUser();
  if (!user?.username) throw new Error("not linked");
  const res = await fetch(`/api/bookmaster/${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      // the device's own key — these routes are pageturner/* upstream, so they
      // need it as much as any other push once REQUIRE_KEY is on
      ...(user.deviceKey ? { "x-pt-key": user.deviceKey } : {}),
    },
    body: JSON.stringify({ username: user.username, ...body }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `BookMaster → ${res.status}`);
  return data;
};

export const pushState = async () => {
  if (!pushSupported()) return "unsupported";
  if (Notification.permission === "denied") return "denied";
  if (!(await bookmasterUser())?.username) return "unlinked";
  if (!(await bridgeKey().catch(() => null))) return "unconfigured";
  const reg = await registration().catch(() => null);
  const sub = await reg?.pushManager.getSubscription().catch(() => null);
  return sub ? "on" : "off";
};

/** Ask, subscribe, and leave the endpoint with BookMaster. */
export const enablePush = async () => {
  if (!pushSupported()) return "unsupported";
  const key = await bridgeKey().catch(() => null);
  if (!key) return "unconfigured";
  const permission = await Notification.requestPermission();
  if (permission !== "granted") return permission === "denied" ? "denied" : "off";
  const reg = await registration().catch(() => null);
  if (!reg) return "unsupported";
  const sub =
    (await reg.pushManager.getSubscription()) ??
    (await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: keyBytes(key),
    }));
  await bridgePost("push-subscribe", { endpoint: sub.endpoint });
  return "on";
};

export const disablePush = async () => {
  const reg = await registration().catch(() => null);
  const sub = await reg?.pushManager.getSubscription().catch(() => null);
  if (sub) {
    await bridgePost("push-unsubscribe", { endpoint: sub.endpoint }).catch(() => {});
    await sub.unsubscribe();
  }
  return "off";
};
