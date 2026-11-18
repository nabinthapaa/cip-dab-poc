import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { appSecretProof, decrypt, encrypt, parseKey } from "../src/crypto";
import { classify, GraphApiError, PermanentError, ReconnectRequiredError } from "../src/errors";
import { keyForInstagramMedia, keyForVideo, isValidKey } from "../src/idempotency";
import { findByShortcode, instagramShortcode, isVideo } from "../src/instagram";
import { isAllowedMediaUrl } from "../src/instagramImport";
import { canPublish, missingPermissions } from "../src/connection";
import { parseGraphResponse } from "../src/graph";
import { canSendFinish, interpretStatus } from "../src/reelStatus";
import { redact } from "../src/redact";
import { retryDelayMs } from "../src/retry";

test("idempotency key matches the Kotlin implementation (shared vector)", () => {
  assert.equal(keyForVideo("uid", "00", "page"), "bb18eae0c883cca44cc253d8b69ea8b5a18177315651eaef1e16a02d9d1bf96c");
  assert.equal(keyForVideo("uid", "AB", "p"), keyForVideo("uid", "ab", "p"));
  assert.notEqual(keyForInstagramMedia("uid", "00", "page"), keyForVideo("uid", "00", "page"));
  assert.ok(isValidKey(keyForVideo("u", "s", "p")));
  assert.ok(!isValidKey("../etc"));
});

test("token encryption round-trips, binds context, and detects tampering", () => {
  const key = randomBytes(32);
  const env = encrypt("EAAsecret", key, "page:u:p");
  assert.ok(!env.includes("EAAsecret"));
  assert.equal(decrypt(env, key, "page:u:p"), "EAAsecret");
  assert.throws(() => decrypt(env, key, "page:u:OTHER"));
  const parts = env.split(":");
  parts[3] = Buffer.from("tampered").toString("base64");
  assert.throws(() => decrypt(parts.join(":"), key, "page:u:p"));
  assert.throws(() => decrypt(env, randomBytes(32), "page:u:p"));
  assert.throws(() => parseKey(Buffer.alloc(16).toString("base64")));
  assert.equal(parseKey(key.toString("base64")).length, 32);
});

test("appsecret_proof is HMAC-SHA256(token, secret)", () => {
  // Independent reference: `printf token | openssl dgst -sha256 -hmac secret`
  assert.equal(appSecretProof("token", "secret"), "e941110e3d2bfe82621f0e3e1434730d7305d106c5f68c87165d0b27a4611a4a");
  assert.match(appSecretProof("token", "secret"), /^[0-9a-f]{64}$/);
  assert.notEqual(appSecretProof("token", "secret"), appSecretProof("token2", "secret"));
});

test("redaction removes tokens in every format", () => {
  const s = redact('GET /me?access_token=EAAabc123456789012345678901234&x=1 Authorization: OAuth EAAxyz98765432109876543210987 {"access_token":"abc"} client_secret=shh');
  assert.ok(!s.includes("EAAabc"));
  assert.ok(!s.includes("EAAxyz"));
  assert.ok(!s.includes('"abc"'));
  assert.ok(!s.includes("shh"));
  assert.match(redact(new Error("boom access_token=zzz")), /access_token=\[REDACTED\]/);
});

test("error classification", () => {
  const g = (code: number, subcode?: number, status = 400, transient?: boolean) => new GraphApiError("m", status, code, subcode, "OAuthException", transient);
  assert.equal(classify(g(190, 460)).kind, "reconnect");
  assert.match(classify(g(190, 460)).userMessage, /password changed/);
  assert.equal(classify(g(10)).kind, "reconnect");
  assert.equal(classify(g(230)).kind, "reconnect");
  assert.equal(classify(g(4)).kind, "retryable");
  assert.equal(classify(g(80001)).kind, "retryable");
  assert.equal(classify(g(2)).kind, "retryable");
  assert.equal(classify(g(999, undefined, 500)).kind, "retryable");
  assert.equal(classify(g(999, undefined, 400, true)).kind, "retryable");
  assert.equal(classify(g(368)).kind, "permanent");
  assert.equal(classify(g(100, 33)).kind, "permanent");
  assert.equal(classify(g(6001)).kind, "permanent");
  assert.equal(classify(g(6000)).kind, "retryable");
  assert.equal(classify(Object.assign(new Error("x"), { code: "ECONNRESET" })).kind, "retryable");
  assert.equal(classify(new ReconnectRequiredError("r")).kind, "reconnect");
  assert.equal(classify(new PermanentError("p")).kind, "permanent");
});

test("Graph responses: errors are parsed and redacted", () => {
  assert.deepEqual(parseGraphResponse(200, '{"id":"1"}'), { id: "1" });
  assert.throws(() => parseGraphResponse(400, '{"error":{"message":"bad access_token=EAA123","code":190,"error_subcode":463}}'),
    (e: GraphApiError) => e.code === 190 && e.subcode === 463 && !e.message.includes("EAA123"));
  assert.throws(() => parseGraphResponse(502, "<html>"), (e: GraphApiError) => e.httpStatus === 502 && e.isTransient === true);
});

test("Reel status interpretation", () => {
  assert.equal(interpretStatus({ uploading_phase: { status: "in_progress" } }).state, "uploading");
  assert.equal(interpretStatus({ uploading_phase: { status: "complete" }, publishing_phase: { status: "not_started" } }).state, "uploaded");
  assert.equal(interpretStatus({ uploading_phase: { status: "complete" }, publishing_phase: { status: "in_progress" } }).state, "publishing");
  assert.equal(interpretStatus({ video_status: "ready", uploading_phase: { status: "complete" }, publishing_phase: { status: "complete", publish_status: "published" } }).state, "published");
  const e = interpretStatus({ processing_phase: { status: "error", error: { message: "too long" } } });
  assert.deepEqual(e, { state: "error", message: "too long" });
  assert.equal(interpretStatus({ video_status: "expired" }).state, "error");
  assert.ok(canSendFinish({ uploading_phase: { status: "complete" }, publishing_phase: { status: "not_started" } }));
  assert.ok(!canSendFinish({ uploading_phase: { status: "complete" }, publishing_phase: { status: "in_progress" } }));
  assert.ok(!canSendFinish({ uploading_phase: { status: "in_progress" } }));
});

test("Instagram link parsing and own-media matching", () => {
  assert.equal(instagramShortcode("https://www.instagram.com/reel/C9xYz_1-AbC/?igsh=abc"), "C9xYz_1-AbC");
  assert.equal(instagramShortcode("https://instagram.com/someuser/reels/Q1w2/"), "Q1w2");
  assert.equal(instagramShortcode("https://evil.com/reel/abc"), null);
  assert.equal(instagramShortcode(42), null);
  const items = [
    { id: "1", permalink: "https://www.instagram.com/p/AAA/", media_type: "IMAGE" },
    { id: "2", permalink: "https://www.instagram.com/reel/BBB/", media_type: "VIDEO", media_product_type: "REELS" },
  ];
  assert.equal(findByShortcode(items, "BBB")?.id, "2");
  assert.equal(findByShortcode(items, "CCC"), undefined);
  assert.ok(isVideo(items[1]) && !isVideo(items[0]));
});

test("only Meta CDN media URLs may be downloaded", () => {
  assert.ok(isAllowedMediaUrl("https://scontent-xyz.cdninstagram.com/v/t50/video.mp4?x=1"));
  assert.ok(isAllowedMediaUrl("https://video.xx.fbcdn.net/v/abc.mp4"));
  assert.ok(!isAllowedMediaUrl("http://scontent.cdninstagram.com/v.mp4"));
  assert.ok(!isAllowedMediaUrl("https://169.254.169.254/latest/meta-data"));
  assert.ok(!isAllowedMediaUrl("https://cdninstagram.com.evil.com/v.mp4"));
  assert.ok(!isAllowedMediaUrl("not a url"));
});

test("Page publish capability and required permissions", () => {
  assert.ok(canPublish({ id: "1", name: "a", tasks: ["CREATE_CONTENT", "ANALYZE"] }));
  assert.ok(!canPublish({ id: "1", name: "a", tasks: ["ANALYZE"] }));
  assert.deepEqual(missingPermissions(["pages_show_list"]), ["pages_read_engagement", "pages_manage_posts"]);
  assert.deepEqual(missingPermissions(["pages_show_list", "pages_read_engagement", "pages_manage_posts"]), []);
});

test("retry backoff mirrors the Kotlin RetryPolicy", () => {
  assert.equal(retryDelayMs(1), 60_000);
  assert.equal(retryDelayMs(2), 120_000);
  assert.equal(retryDelayMs(50), 30 * 60_000);
});
