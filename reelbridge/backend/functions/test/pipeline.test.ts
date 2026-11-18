import { test } from "node:test";
import assert from "node:assert/strict";
import { runJob } from "../src/pipeline";
import { JobStatus } from "../src/model";
import { FakeMeta, makeDeps, newJob, PAGE_TOKEN } from "./fakes";

test("happy path: START → UPLOAD → FINISH → published, exactly one post", async () => {
  const meta = new FakeMeta();
  const { deps, jobs, logger, removed } = makeDeps(meta);
  const job = newJob();
  jobs.jobs.set(job.id, { ...job });

  assert.equal(await runJob(deps, job.id), "published");
  const saved = jobs.jobs.get(job.id)!;
  assert.equal(saved.status, JobStatus.PUBLISHED);
  assert.equal(saved.permalinkUrl, "https://www.facebook.com/reel/900");
  assert.equal(saved.attempts, 1);
  assert.deepEqual(meta.calls.filter((c) => c !== "status"), ["start", "upload", "finish"]);
  assert.equal(meta.videos.get("900")!.finishCount, 1);
  assert.deepEqual(removed, [job.storagePath]);
  // Tokens never appear in logs or in URLs of POST requests.
  assert.ok(logger.lines.every((l) => !l.includes(PAGE_TOKEN)));
});

test("access tokens are sent in POST bodies, not query strings", async () => {
  const meta = new FakeMeta();
  const { deps, jobs } = makeDeps(meta);
  jobs.jobs.set("a".repeat(64), { ...newJob() });
  await runJob(deps, "a".repeat(64));
  const postUrls = meta.urls.filter((u) => u.includes("video_reels"));
  assert.ok(postUrls.length >= 2);
  assert.ok(postUrls.every((u) => !u.includes("access_token")));
});

test("a running job cannot be claimed twice (lease)", async () => {
  const meta = new FakeMeta();
  const { deps, jobs } = makeDeps(meta);
  const job = newJob();
  jobs.jobs.set(job.id, { ...job, status: JobStatus.PUBLISHING, leaseUntil: 10_000_000 });
  assert.equal(await runJob(deps, job.id), "skipped");
  assert.deepEqual(meta.calls, []);
});

test("published jobs are never re-run", async () => {
  const meta = new FakeMeta();
  const { deps, jobs } = makeDeps(meta);
  jobs.jobs.set("a".repeat(64), { ...newJob(), status: JobStatus.PUBLISHED });
  assert.equal(await runJob(deps, "a".repeat(64)), "skipped");
  assert.equal(await runJob(deps, "a".repeat(64), "poll"), "skipped");
  assert.deepEqual(meta.calls, []);
});

test("slow processing hands over to the poller, which completes without a second FINISH", async () => {
  const meta = new FakeMeta();
  meta.pollsUntilPublished = 20;
  const { deps, jobs } = makeDeps(meta, { publishWaitMs: 10_000 });
  const job = newJob();
  jobs.jobs.set(job.id, { ...job });

  assert.equal(await runJob(deps, job.id), "processing");
  assert.equal(jobs.jobs.get(job.id)!.status, JobStatus.PROCESSING);
  meta.videos.get("900")!.pollsUntilPublished = 0;
  assert.equal(await runJob(deps, job.id, "poll"), "published");
  assert.equal(meta.calls.filter((c) => c === "finish").length, 1);
  assert.equal(meta.calls.filter((c) => c === "start").length, 1);
});

test("crash after FINISH: recovery resumes the same video and does not finish again", async () => {
  const meta = new FakeMeta();
  meta.pollsUntilPublished = 1;
  const { deps, jobs } = makeDeps(meta);
  const job = newJob();
  // Simulate a previous invocation that died right after FINISH (lease expired).
  const start = await deps.graph.startReel(job.pageId, PAGE_TOKEN);
  meta.videos.get(start.video_id)!.uploaded = true;
  await deps.graph.finishReel(job.pageId, PAGE_TOKEN, start.video_id, job.caption);
  meta.calls = [];
  jobs.jobs.set(job.id, { ...job, status: JobStatus.PUBLISHING, fbVideoId: start.video_id, uploadComplete: true, leaseUntil: 1, attempts: 1 });

  assert.equal(await runJob(deps, job.id), "published");
  assert.ok(!meta.calls.includes("finish"));
  assert.ok(!meta.calls.includes("start"));
  assert.equal(meta.videos.get(start.video_id)!.finishCount, 1);
});

test("crash after UPLOAD but before FINISH: resumes and finishes the same video", async () => {
  const meta = new FakeMeta();
  const { deps, jobs } = makeDeps(meta);
  const job = newJob();
  const start = await deps.graph.startReel(job.pageId, PAGE_TOKEN);
  meta.videos.get(start.video_id)!.uploaded = true;
  meta.calls = [];
  jobs.jobs.set(job.id, { ...job, status: JobStatus.PUBLISHING, fbVideoId: start.video_id, uploadComplete: true, leaseUntil: 1, attempts: 1 });
  assert.equal(await runJob(deps, job.id), "published");
  assert.deepEqual(meta.calls.filter((c) => c !== "status"), ["finish"]);
});

test("transient upload failure is retryable with backoff; the retry publishes once", async () => {
  const meta = new FakeMeta();
  meta.failUploadOnce = true;
  const { deps, jobs } = makeDeps(meta);
  const job = newJob();
  jobs.jobs.set(job.id, { ...job });

  assert.equal(await runJob(deps, job.id), "failed");
  const failed = jobs.jobs.get(job.id)!;
  assert.equal(failed.retryable, true);
  assert.equal(failed.nextRetryAt, 1_000_000 + 60_000);
  assert.match(String(failed.errorMessage), /temporary problem/);

  failed.status = JobStatus.QUEUED;
  assert.equal(await runJob(deps, job.id), "published");
  // The unfinished first session was never published; only one FINISH overall.
  assert.equal(meta.calls.filter((c) => c === "finish").length, 1);
  assert.equal(jobs.jobs.get(job.id)!.attempts, 2);
});

test("expired token → needs_reconnect, no automatic retry", async () => {
  const meta = new FakeMeta();
  meta.failStartWith = { code: 190, subcode: 463 };
  const { deps, jobs } = makeDeps(meta);
  jobs.jobs.set("a".repeat(64), { ...newJob() });
  assert.equal(await runJob(deps, "a".repeat(64)), "needs_reconnect");
  const j = jobs.jobs.get("a".repeat(64))!;
  assert.equal(j.status, JobStatus.NEEDS_RECONNECT);
  assert.equal(j.nextRetryAt, null);
  assert.match(String(j.errorMessage), /expired/);
});

test("missing Page permission → needs_reconnect", async () => {
  const meta = new FakeMeta();
  meta.failStartWith = { code: 200 };
  const { deps, jobs } = makeDeps(meta);
  jobs.jobs.set("a".repeat(64), { ...newJob() });
  assert.equal(await runJob(deps, "a".repeat(64)), "needs_reconnect");
});

test("missing stored Page token → needs_reconnect without calling Meta", async () => {
  const meta = new FakeMeta();
  const { deps, jobs } = makeDeps(meta, { token: null });
  jobs.jobs.set("a".repeat(64), { ...newJob() });
  assert.equal(await runJob(deps, "a".repeat(64)), "needs_reconnect");
  assert.deepEqual(meta.calls, []);
});

test("rate limiting stops auto-retrying after the attempt limit", async () => {
  const meta = new FakeMeta();
  meta.failStartWith = { code: 4 };
  const { deps, jobs } = makeDeps(meta);
  jobs.jobs.set("a".repeat(64), { ...newJob(), attempts: 2 });
  assert.equal(await runJob(deps, "a".repeat(64)), "failed");
  const j = jobs.jobs.get("a".repeat(64))!;
  assert.equal(j.attempts, 3);
  assert.equal(j.retryable, true);
  assert.equal(j.nextRetryAt, null);
  assert.match(String(j.errorMessage), /Tap Retry/);
});

test("invalid Page id is a permanent failure", async () => {
  const meta = new FakeMeta();
  const { deps, jobs } = makeDeps(meta);
  jobs.jobs.set("a".repeat(64), { ...newJob(), pageId: "999" });
  assert.equal(await runJob(deps, "a".repeat(64)), "failed");
  const j = jobs.jobs.get("a".repeat(64))!;
  assert.equal(j.retryable, false);
  assert.match(String(j.errorMessage), /Page wasn't found/);
});

test("Meta processing error is reported and not auto-retried", async () => {
  const meta = new FakeMeta();
  meta.processingError = "Video is longer than 90 seconds";
  const { deps, jobs } = makeDeps(meta);
  jobs.jobs.set("a".repeat(64), { ...newJob() });
  assert.equal(await runJob(deps, "a".repeat(64)), "failed");
  const j = jobs.jobs.get("a".repeat(64))!;
  assert.match(String(j.errorMessage), /longer than 90 seconds/);
  assert.equal(j.retryable, false);
  assert.equal(j.nextRetryAt, null);
});

test("missing video file fails permanently without starting a session", async () => {
  const meta = new FakeMeta();
  const { deps, jobs } = makeDeps(meta);
  jobs.jobs.set("a".repeat(64), { ...newJob(), storagePath: "elsewhere/x.mp4" });
  assert.equal(await runJob(deps, "a".repeat(64)), "failed");
  assert.deepEqual(meta.calls, ["start"]);
});

test("hosted upload mode sends a file_url instead of bytes", async () => {
  const meta = new FakeMeta();
  const seen: Record<string, string>[] = [];
  const { deps, jobs } = makeDeps(meta, { uploadMode: "hosted" });
  const origFetch = meta.fetch;
  (deps.graph as unknown as { fetchImpl: typeof meta.fetch }).fetchImpl = async (url, init) => {
    if (url.startsWith("https://rupload.facebook.com/")) {
      seen.push(init!.headers!);
      meta.videos.get(url.split("/").pop()!)!.uploaded = true;
      return { status: 200, json: async () => ({ success: true }), text: async () => '{"success":true}' };
    }
    return origFetch(url, init);
  };
  jobs.jobs.set("a".repeat(64), { ...newJob() });
  assert.equal(await runJob(deps, "a".repeat(64)), "published");
  assert.equal(seen[0].file_url, "https://storage.example/signed");
  assert.equal(seen[0].Authorization, `OAuth ${PAGE_TOKEN}`);
});
