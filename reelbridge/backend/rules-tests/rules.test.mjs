import { test, before, after, beforeEach } from "node:test";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { assertFails, assertSucceeds, initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { collection, deleteDoc, doc, getDoc, getDocs, query, serverTimestamp, setDoc, updateDoc, where, writeBatch } from "firebase/firestore";
import { getBytes, ref, uploadBytes } from "firebase/storage";

const ALICE = "alice";
const BOB = "bob";
const PAGE = "111222333";
const sha = (s) => createHash("sha256").update(s).digest("hex");
const VIDEO_SHA = sha("video-bytes");
const KEY = sha(`v1|${ALICE}|video:${VIDEO_SHA}|${PAGE}`);

let env;
before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-reelbridge",
    firestore: { rules: readFileSync("../firestore.rules", "utf8") },
    storage: { rules: readFileSync("../storage.rules", "utf8") },
  });
});
after(async () => env?.cleanup());
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, "facebook_connections", ALICE), { uid: ALICE, status: "connected", selectedPageId: PAGE });
    await setDoc(doc(db, "facebook_connections", ALICE, "secrets", "user"), { enc: "v1:x:y:z" });
    await setDoc(doc(db, "facebook_pages", `${ALICE}_${PAGE}`), { uid: ALICE, pageId: PAGE, name: "Alice Page", canPublish: true });
    await setDoc(doc(db, "facebook_pages", `${ALICE}_${PAGE}`, "secrets", "token"), { enc: "v1:x:y:z" });
    await setDoc(doc(db, "facebook_pages", `${BOB}_999`), { uid: BOB, pageId: "999", name: "Bob Page", canPublish: true });
    await setDoc(doc(db, "publishing_jobs", "b".repeat(64)), { uid: BOB, status: "published" });
    await setDoc(doc(db, "publishing_jobs", "c".repeat(64)), { uid: ALICE, status: "published" });
    await setDoc(doc(db, "publishing_jobs", "d".repeat(64)), { uid: ALICE, status: "processing" });
    await setDoc(doc(db, "publishing_logs", "l1"), { uid: ALICE, message: "ok" });
    await setDoc(doc(db, "users", ALICE), { uid: ALICE, selectedPageId: PAGE });
  });
});

const fs = (uid) => (uid ? env.authenticatedContext(uid) : env.unauthenticatedContext()).firestore();

function jobData(overrides = {}) {
  return {
    uid: ALICE, reelId: KEY, pageId: PAGE, pageName: "Alice Page", caption: "hi", storagePath: `users/${ALICE}/videos/${KEY}.mp4`,
    source: "device", status: "queued", attempts: 0, createdAt: serverTimestamp(), updatedAt: serverTimestamp(), ...overrides,
  };
}
function reelData(overrides = {}) {
  return {
    uid: ALICE, source: "device", storagePath: `users/${ALICE}/videos/${KEY}.mp4`, sha256: VIDEO_SHA,
    sizeBytes: 1000, durationMs: 15000, width: 1080, height: 1920, caption: "hi", createdAt: serverTimestamp(), ...overrides,
  };
}
function createJob(db, { job = {}, reel = {}, id = KEY, withReel = true } = {}) {
  const b = writeBatch(db);
  if (withReel) b.set(doc(db, "reels", id), reelData(reel));
  b.set(doc(db, "publishing_jobs", id), jobData(job));
  return b.commit();
}

// ---- Facebook connection & tokens ----------------------------------------------------------

test("connection status is private to its owner and read-only", async () => {
  await assertSucceeds(getDoc(doc(fs(ALICE), "facebook_connections", ALICE)));
  await assertFails(getDoc(doc(fs(BOB), "facebook_connections", ALICE)));
  await assertFails(getDoc(doc(fs(null), "facebook_connections", ALICE)));
  await assertFails(updateDoc(doc(fs(ALICE), "facebook_connections", ALICE), { status: "connected" }));
});

test("tokens in secrets/ are unreadable and unwritable, even by their owner", async () => {
  await assertFails(getDoc(doc(fs(ALICE), "facebook_connections", ALICE, "secrets", "user")));
  await assertFails(getDoc(doc(fs(ALICE), "facebook_pages", `${ALICE}_${PAGE}`, "secrets", "token")));
  await assertFails(setDoc(doc(fs(ALICE), "facebook_pages", `${ALICE}_${PAGE}`, "secrets", "token"), { enc: "x" }));
});

test("pages: owner can list own pages only", async () => {
  await assertSucceeds(getDocs(query(collection(fs(ALICE), "facebook_pages"), where("uid", "==", ALICE))));
  await assertFails(getDocs(collection(fs(ALICE), "facebook_pages")));
  await assertFails(getDoc(doc(fs(ALICE), "facebook_pages", `${BOB}_999`)));
  await assertFails(setDoc(doc(fs(ALICE), "facebook_pages", `${ALICE}_1`), { uid: ALICE, canPublish: true }));
});

// ---- Settings ---------------------------------------------------------------------------------

test("users: settings writable, Page selection is backend-only", async () => {
  const db = fs(ALICE);
  await assertSucceeds(setDoc(doc(db, "users", ALICE), { autoPublish: true, captionTemplate: "{caption}", defaultHashtags: "#a", updatedAt: serverTimestamp() }, { merge: true }));
  await assertFails(setDoc(doc(db, "users", ALICE), { selectedPageId: "999" }, { merge: true }));
  await assertFails(setDoc(doc(db, "users", ALICE), { isAdmin: true }, { merge: true }));
  await assertFails(setDoc(doc(db, "users", ALICE), { autoPublish: "yes" }, { merge: true }));
  await assertFails(setDoc(doc(fs(BOB), "users", ALICE), { autoPublish: true }, { merge: true }));
});

// ---- Publishing jobs ------------------------------------------------------------------------

test("a valid queued job + reel can be created by its owner", async () => {
  await assertSucceeds(createJob(fs(ALICE)));
});

test("the same idempotency key cannot be created twice (duplicate prevention)", async () => {
  await assertSucceeds(createJob(fs(ALICE)));
  await assertFails(createJob(fs(ALICE)));
});

test("clients cannot forge job state or target other users/pages/paths", async () => {
  const db = fs(ALICE);
  await assertFails(createJob(db, { job: { status: "published" } }));
  await assertFails(createJob(db, { job: { attempts: 5 } }));
  await assertFails(createJob(db, { job: { fbVideoId: "123" } }));
  await assertFails(createJob(db, { job: { uid: BOB } }));
  await assertFails(createJob(db, { job: { pageId: "999" } }));
  await assertFails(createJob(db, { job: { storagePath: `users/${BOB}/videos/${KEY}.mp4` } }));
  await assertFails(createJob(db, { job: { caption: "x".repeat(2201) } }));
  await assertFails(createJob(db, { id: "not-a-key", job: { reelId: "not-a-key" } }));
  await assertFails(createJob(db, { withReel: false }));
  await assertFails(createJob(fs(null)));
});

test("job reads: own jobs, and 'does this key exist' checks; never other users' jobs", async () => {
  await assertSucceeds(getDoc(doc(fs(ALICE), "publishing_jobs", "c".repeat(64))));
  await assertSucceeds(getDoc(doc(fs(ALICE), "publishing_jobs", "e".repeat(64)))); // missing → allowed
  await assertFails(getDoc(doc(fs(ALICE), "publishing_jobs", "b".repeat(64))));
  await assertSucceeds(getDocs(query(collection(fs(ALICE), "publishing_jobs"), where("uid", "==", ALICE))));
  await assertFails(getDocs(collection(fs(ALICE), "publishing_jobs")));
});

test("clients cannot update jobs; may delete only finished own jobs", async () => {
  await assertFails(updateDoc(doc(fs(ALICE), "publishing_jobs", "d".repeat(64)), { status: "published" }));
  await assertFails(deleteDoc(doc(fs(ALICE), "publishing_jobs", "d".repeat(64))));
  await assertFails(deleteDoc(doc(fs(ALICE), "publishing_jobs", "b".repeat(64))));
  await assertSucceeds(deleteDoc(doc(fs(ALICE), "publishing_jobs", "c".repeat(64))));
});

test("logs are read-only and private", async () => {
  await assertSucceeds(getDoc(doc(fs(ALICE), "publishing_logs", "l1")));
  await assertFails(getDoc(doc(fs(BOB), "publishing_logs", "l1")));
  await assertFails(setDoc(doc(fs(ALICE), "publishing_logs", "l2"), { uid: ALICE }));
});

test("unknown collections are denied", async () => {
  await assertFails(setDoc(doc(fs(ALICE), "anything", "x"), { a: 1 }));
});

// ---- Storage ----------------------------------------------------------------------------------

const st = (uid) => (uid ? env.authenticatedContext(uid) : env.unauthenticatedContext()).storage();
const bytes = new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112]);
const meta = (o = {}) => ({ contentType: "video/mp4", customMetadata: { sha256: VIDEO_SHA }, ...o });

test("storage: owner uploads a video to the deterministic path", async () => {
  await assertSucceeds(uploadBytes(ref(st(ALICE), `users/${ALICE}/videos/${KEY}.mp4`), bytes, meta()));
  await assertSucceeds(uploadBytes(ref(st(ALICE), `users/${ALICE}/videos/${KEY}.mov`), bytes, meta({ contentType: "video/quicktime" })));
  await assertSucceeds(getBytes(ref(st(ALICE), `users/${ALICE}/videos/${KEY}.mp4`)));
});

test("storage: rejects other users, wrong types, bad names, missing hash, anonymous", async () => {
  await assertFails(uploadBytes(ref(st(BOB), `users/${ALICE}/videos/${KEY}.mp4`), bytes, meta()));
  await assertFails(uploadBytes(ref(st(ALICE), `users/${ALICE}/videos/${KEY}.mp4`), bytes, meta({ contentType: "image/png" })));
  await assertFails(uploadBytes(ref(st(ALICE), `users/${ALICE}/videos/evil.mp4`), bytes, meta()));
  await assertFails(uploadBytes(ref(st(ALICE), `users/${ALICE}/videos/${KEY}.mp4`), bytes, { contentType: "video/mp4" }));
  await assertFails(uploadBytes(ref(st(ALICE), `users/${ALICE}/other/${KEY}.mp4`), bytes, meta()));
  await assertFails(uploadBytes(ref(st(null), `users/${ALICE}/videos/${KEY}.mp4`), bytes, meta()));
  await assertFails(getBytes(ref(st(BOB), `users/${ALICE}/videos/${KEY}.mp4`)));
});
