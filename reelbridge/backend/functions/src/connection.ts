import { FieldValue, Timestamp, type Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { classify, GraphApiError } from "./errors";
import type { FbPage, GraphClient } from "./graph";
import { Collections, OPTIONAL_PERMISSIONS, REQUIRED_PERMISSIONS, pageDocId } from "./model";
import type { FirestoreTokenStore } from "./store";

export interface ConnectionDeps {
  db: Firestore;
  graph: GraphClient;
  tokens: FirestoreTokenStore;
  appId: string;
}

/** "Create content" is the Page task required to publish (pages_manage_posts acts on it). */
export function canPublish(page: FbPage): boolean {
  const tasks = page.tasks ?? [];
  return tasks.includes("CREATE_CONTENT") || tasks.includes("MANAGE");
}

export function missingPermissions(granted: string[]): string[] {
  return REQUIRED_PERMISSIONS.filter((p) => !granted.includes(p));
}

const tsOrNull = (epochSeconds?: number) => (epochSeconds && epochSeconds > 0 ? Timestamp.fromMillis(epochSeconds * 1000) : null);

/** Converts Graph failures into callable errors the app can show. */
export function toHttpsError(err: unknown): HttpsError {
  if (err instanceof HttpsError) return err;
  const c = classify(err);
  if (c.kind === "reconnect") return new HttpsError("failed-precondition", c.userMessage);
  if (err instanceof GraphApiError && c.kind === "permanent") return new HttpsError("invalid-argument", c.userMessage);
  return new HttpsError("unavailable", c.userMessage);
}

/**
 * Validates the short-lived user token from Facebook Login, exchanges it for a long-lived token
 * and stores everything server-side (encrypted). The token must belong to this app and to the
 * same Facebook user the caller signed in to Firebase with.
 */
export async function connect(deps: ConnectionDeps, uid: string, facebookIdentity: string | undefined, shortToken: string) {
  const { data } = await deps.graph.debugToken(shortToken);
  if (!data?.is_valid) throw new HttpsError("permission-denied", "Facebook rejected this login. Please try again.");
  if (data.app_id !== deps.appId) throw new HttpsError("permission-denied", "This Facebook token was issued for a different app.");
  if (!facebookIdentity || data.user_id !== facebookIdentity) {
    throw new HttpsError("permission-denied", "The Facebook account doesn't match your ReelBridge sign-in.");
  }

  const long = await deps.graph.exchangeForLongLived(shortToken);
  const me = await deps.graph.me(long.access_token);
  const perms = await deps.graph.permissions(long.access_token);
  const longInfo = (await deps.graph.debugToken(long.access_token)).data;

  await deps.db.collection(Collections.CONNECTIONS).doc(uid).collection(Collections.SECRETS).doc("user")
    .set(deps.tokens.sealUser(uid, long.access_token));
  await deps.db.collection(Collections.CONNECTIONS).doc(uid).set({
    uid,
    status: "connected",
    fbUserId: me.id,
    fbUserName: me.name ?? null,
    grantedPermissions: perms.granted,
    declinedPermissions: perms.declined,
    missingPermissions: missingPermissions(perms.granted),
    optionalPermissionsMissing: OPTIONAL_PERMISSIONS.filter((p) => !perms.granted.includes(p)),
    userTokenExpiresAt: tsOrNull(longInfo?.expires_at),
    dataAccessExpiresAt: tsOrNull(longInfo?.data_access_expires_at),
    checkedAt: FieldValue.serverTimestamp(),
    connectedAt: FieldValue.serverTimestamp(),
    lastError: null,
  }, { merge: true });
  await deps.db.collection(Collections.USERS).doc(uid).set({ uid, updatedAt: FieldValue.serverTimestamp() }, { merge: true });

  return syncPages(deps, uid, long.access_token);
}

/** Re-reads /me/accounts and stores each Page's (non-expiring) Page token encrypted. */
export async function syncPages(deps: ConnectionDeps, uid: string, userToken: string) {
  const pages = await deps.graph.pages(userToken);
  const connRef = deps.db.collection(Collections.CONNECTIONS).doc(uid);
  const existing = await deps.db.collection(Collections.PAGES).where("uid", "==", uid).get();
  const seen = new Set<string>();
  const batch = deps.db.batch();

  for (const p of pages) {
    const ref = deps.db.collection(Collections.PAGES).doc(pageDocId(uid, p.id));
    seen.add(ref.id);
    batch.set(ref, {
      uid,
      pageId: p.id,
      name: p.name,
      pictureUrl: p.picture?.data?.url ?? null,
      tasks: p.tasks ?? [],
      canPublish: canPublish(p),
      igUserId: p.instagram_business_account?.id ?? null,
      igUsername: p.instagram_business_account?.username ?? null,
      updatedAt: FieldValue.serverTimestamp(),
    });
    if (p.access_token) batch.set(ref.collection(Collections.SECRETS).doc("token"), deps.tokens.sealPage(uid, p.id, p.access_token));
  }
  for (const doc of existing.docs) {
    if (!seen.has(doc.id)) {
      batch.delete(doc.ref.collection(Collections.SECRETS).doc("token"));
      batch.delete(doc.ref);
    }
  }

  // Keep the selection valid; auto-select when there is exactly one publishable Page.
  const conn = await connRef.get();
  const selected = conn.get("selectedPageId") as string | undefined;
  const publishable = pages.filter(canPublish);
  if (selected && !publishable.some((p) => p.id === selected)) {
    batch.set(connRef, { selectedPageId: null, selectedPageName: null }, { merge: true });
  } else if (!selected && publishable.length === 1) {
    batch.set(connRef, { selectedPageId: publishable[0].id, selectedPageName: publishable[0].name }, { merge: true });
  }
  await batch.commit();
  return { pageCount: pages.length, publishableCount: publishable.length };
}

export async function selectPage(deps: ConnectionDeps, uid: string, pageId: string) {
  const page = await deps.db.collection(Collections.PAGES).doc(pageDocId(uid, pageId)).get();
  if (!page.exists || page.get("uid") !== uid) throw new HttpsError("not-found", "That Page isn't connected to your account.");
  if (page.get("canPublish") !== true) throw new HttpsError("permission-denied", "You don't have permission to publish to that Page.");
  await deps.db.collection(Collections.CONNECTIONS).doc(uid).set(
    { selectedPageId: pageId, selectedPageName: page.get("name"), updatedAt: FieldValue.serverTimestamp() }, { merge: true });
  await deps.db.collection(Collections.USERS).doc(uid).set({ selectedPageId: pageId, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
}

/** Re-validates stored tokens with debug_token and records the result for the app to display. */
export async function check(deps: ConnectionDeps, uid: string) {
  const ref = deps.db.collection(Collections.CONNECTIONS).doc(uid);
  const userToken = await deps.tokens.userToken(uid);
  if (!userToken) {
    await ref.set({ status: "disconnected", checkedAt: FieldValue.serverTimestamp() }, { merge: true });
    return { status: "disconnected" };
  }
  const info = (await deps.graph.debugToken(userToken)).data;
  if (!info?.is_valid) {
    await ref.set({ status: "expired", lastError: "Facebook access expired. Reconnect to keep publishing.", checkedAt: FieldValue.serverTimestamp() }, { merge: true });
    return { status: "expired" };
  }
  const perms = await deps.graph.permissions(userToken);
  const selected = (await ref.get()).get("selectedPageId") as string | undefined;
  let pageOk = true;
  if (selected) {
    const pageToken = await deps.tokens.pageToken(uid, selected);
    pageOk = !!pageToken && (await deps.graph.debugToken(pageToken)).data?.is_valid === true;
  }
  const missing = missingPermissions(perms.granted);
  const status = missing.length === 0 && pageOk ? "connected" : "needs_attention";
  await ref.set({
    status, // "needs_attention" makes the app ask the user to reconnect
    grantedPermissions: perms.granted,
    declinedPermissions: perms.declined,
    missingPermissions: missing,
    userTokenExpiresAt: tsOrNull(info.expires_at),
    dataAccessExpiresAt: tsOrNull(info.data_access_expires_at),
    lastError: !pageOk ? "The selected Page's access is no longer valid. Tap Reconnect." : missing.length ? `Missing permissions: ${missing.join(", ")}` : null,
    checkedAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  return { status, missingPermissions: missing, pageOk };
}

/** Deletes every stored token and Page; optionally revokes the app's permissions at Facebook. */
export async function disconnect(deps: ConnectionDeps, uid: string, revoke: boolean) {
  const userToken = await deps.tokens.userToken(uid).catch(() => null);
  if (revoke && userToken) await deps.graph.revokeAll(userToken).catch(() => undefined);
  const pages = await deps.db.collection(Collections.PAGES).where("uid", "==", uid).get();
  const batch = deps.db.batch();
  for (const doc of pages.docs) {
    batch.delete(doc.ref.collection(Collections.SECRETS).doc("token"));
    batch.delete(doc.ref);
  }
  const conn = deps.db.collection(Collections.CONNECTIONS).doc(uid);
  batch.delete(conn.collection(Collections.SECRETS).doc("user"));
  batch.delete(conn);
  await batch.commit();
}
