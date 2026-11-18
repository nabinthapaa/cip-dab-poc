# ReelBridge

**Instagram → Share → ReelBridge → published as a Facebook Reel on your Page.**

ReelBridge is an Android app (Kotlin, Jetpack Compose, Material 3) with a Firebase backend
(Auth, Firestore, Storage, Cloud Functions, App Check). It publishes through Meta's official
**Reels Publishing API**, using the three phases START → UPLOAD → FINISH. You connect your Facebook
Page once, then share videos to ReelBridge from any app.

> **Publish only content you own or have permission to repost.** ReelBridge never scrapes
> Instagram, bypasses login, or downloads other people's media.

---

## What happens when you share

| You share… | ReelBridge does |
|---|---|
| **A video file** (from Gallery, Files, or any app that shares the actual video) | Copies it into private app storage, hashes it (SHA-256), reads duration, resolution and rotation, extracts a thumbnail, and validates it against Reel specs (MP4/MOV, 3–90 s, ≤ 1 GB; warns below 540×960 or when not 9:16). It then uploads to Firebase Storage, creates a job, and the backend publishes it. The video is never re-encoded, so its quality and aspect ratio are kept. |
| **An Instagram Reel link** (what Instagram's Share → ReelBridge sends) | Instagram only shares a link, never the video. ReelBridge asks the backend to find that Reel among the media of the **Instagram professional account linked to your Facebook Page**, using the official Instagram Graph API (`instagram_basic`). If it's your Reel, the backend copies it through the API and publishes it. If it isn't (or no account is linked), the app explains why and asks you to share the video file instead. |
| A Story, image, plain text or another website's link | Shows a clear "can't use this" message. Nothing is published. |

With **Automatic publishing** on (Settings), a valid share is queued straight away and the share
screen closes itself. With it off, you review the preview, caption and destination Page first.
You get a notification when the Reel is live or if it fails.

## Repository layout

```
reelbridge/
├── app/                      Android app (com.reelbridge.app)
│   └── src/main/kotlin/com/reelbridge/app/
│       ├── ui/               Compose screens: Home, Connect, History, Reel (publishing), Settings
│       ├── share/            Share-sheet receiver (ACTION_SEND / SEND_MULTIPLE, text/plain + video/*)
│       ├── data/             Repositories: Firebase Auth/Firestore/Storage/Functions, DataStore, drafts
│       ├── media/            Metadata + thumbnail extraction (MediaMetadataRetriever)
│       ├── work/             WorkManager queue (upload worker, status watcher), notifications
│       └── facebook/         Facebook Login (Meta SDK) and requested permissions
├── core/                     Pure-Kotlin domain layer (no Android): share classification,
│                             Instagram URL parsing, video validation, captions, idempotency keys,
│                             status model, retry policy. Unit tested.
├── backend/
│   ├── functions/            Cloud Functions (TypeScript): token custody, Graph API client,
│   │                         Reels pipeline, Instagram import, retries, maintenance
│   ├── firestore.rules       Security rules (tested in rules-tests/ on the emulators)
│   ├── storage.rules
│   └── rules-tests/
└── docs/                     META_SETUP.md, FIREBASE_SETUP.md
```

## Architecture

```
 Instagram / Gallery ──share──▶ ShareReceiverActivity ──▶ ShareClassifier (core)
                                       │
          video file ──────────────────┤                      Instagram link
          DraftStore: copy + SHA-256   │                            │
          VideoInspector + Validator   │                callable resolveInstagramReel
          PublishQueue (WorkManager) ──┘                callable importInstagramReel
          PublishWorker: Storage upload                             │
          create publishing_jobs/{idempotencyKey}                   │
                     │                                              │
                     ▼                                              ▼
            Firestore trigger onPublishingJobCreated ◀──── job (preparing → queued)
                     │  validate owner, Page, file, key
                     ▼
            pipeline.runJob (lease-protected, checkpointed)
              START   POST /{page-id}/video_reels upload_phase=start
              UPLOAD  POST rupload.facebook.com/video-upload/{ver}/{video-id}   (binary stream or file_url)
              FINISH  POST /{page-id}/video_reels upload_phase=finish video_state=PUBLISHED description=…
              poll    GET /{video-id}?fields=status  → published / processing / error
                     │
                     ▼
            publishing_jobs status ──(snapshot listener)──▶ app UI + JobWatchWorker notification
            publishingMaintenance (every 5 min): processing follow-up, stale-lease recovery, auto-retry
```

### Duplicate-publication prevention

1. **Deterministic job id.** `sha256("v1|uid|video:<file sha256>|pageId")`, or `ig:<mediaId>` for
   Instagram imports. The Kotlin and TypeScript implementations are checked against the same test vector.
2. **On the device**, WorkManager unique work (`KEEP`) means re-sharing the same file doesn't enqueue it twice.
3. **In Firestore**, the job is created inside a transaction, and security rules allow *create* only.
   A second create of the same key is rejected (tested on the emulator).
4. **On the server**, the backend recomputes the key from the stored file's hash and rejects jobs whose id doesn't match.
5. **During execution**, jobs are claimed under a lease. The Meta `video_id` is checkpointed. A resumed job asks Meta for the
   video's status first, and FINISH is sent only while publishing hasn't started. These cases are unit tested: a crash
   after FINISH, a crash after UPLOAD, concurrent runs, and a transient failure followed by a retry.

### Security

- **No credentials in the APK.** The Meta App ID and client token are public identifiers that Meta requires in the app,
  and they're injected at build time. The App secret and token encryption key live in Secret Manager.
- **Tokens are encrypted at rest.** User and Page tokens use AES-256-GCM with per-record context, stored in `*/secrets/*`
  documents that rules deny to every client.
- **Every Graph call is signed** with `appsecret_proof`. Tokens are sent in POST bodies or headers, never in logged URLs.
  Logs pass through a redactor (tested).
- **Login is cross-checked.** `connectFacebook` verifies the token's app id and that the Facebook user matches the
  caller's Firebase identity.
- **App Check** uses Play Integrity on release builds and the debug provider on debug builds. Callables enforce it
  (`ENFORCE_APP_CHECK`).
- **Storage rules** restrict uploads to `users/{uid}/videos/{key}.mp4|mov`, MP4/MOV only, at most 1 GB, and require a
  sha256 metadata field. The server re-validates all of this.
- **Instagram media downloads** only go to Meta CDN hosts over HTTPS (SSRF guard) and are size-capped.
- **The app** is HTTPS-only (network security config), with backups disabled.

## Configuration

| Setting | Where | Notes |
|---|---|---|
| `reelbridge.facebookAppId` | `local.properties` or env `RB_FACEBOOK_APP_ID` | public |
| `reelbridge.facebookClientToken` | `local.properties` or env `RB_FACEBOOK_CLIENT_TOKEN` | public |
| `reelbridge.functionsRegion` | `local.properties` or env `RB_FUNCTIONS_REGION` | default `us-central1` |
| `app/google-services.json` | download from Firebase | git-ignored |
| `META_APP_ID`, `META_GRAPH_VERSION`, `REELS_UPLOAD_MODE`, `DELETE_VIDEO_AFTER_PUBLISH`, `ENFORCE_APP_CHECK`, `RB_REGION` | `backend/functions/.env.<project>` | see `.env.example` |
| `META_APP_SECRET`, `TOKEN_ENCRYPTION_KEY` | `firebase functions:secrets:set …` | **secrets** |

A build that is missing any of these still compiles. It shows **Setup required** (no Firebase) or
disables Facebook Login (no App ID). It never pretends to publish.

## Build

Requirements: JDK 17+ and Android SDK 35 (Android Studio Ladybug or newer). Node 22 for the backend.

```bash
cd reelbridge
cp local.properties.example local.properties    # fill in, plus sdk.dir if not using Android Studio
./gradlew :core:test :app:testDebugUnitTest :app:lintDebug
./gradlew :app:assembleDebug                    # app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:connectedDebugAndroidTest        # with a device/emulator attached
```

For a signed release, copy `keystore.properties.example` to `keystore.properties`, then run
`./gradlew :app:assembleRelease` (R8 minified). Without a keystore you get
`app-release-unsigned.apk`.

**CI** (`.github/workflows/reelbridge.yml`) runs on every push that touches `reelbridge/`:

- core and app unit tests, lint, and debug + release APK builds (uploaded as the `reelbridge-apks` artifact);
- instrumented tests on an API 34 emulator;
- backend build and tests;
- Firestore/Storage rules tests on the Firebase emulators.

Optional repository secrets: `RB_FACEBOOK_APP_ID`, `RB_FACEBOOK_CLIENT_TOKEN`, `GOOGLE_SERVICES_JSON_B64`.

## Setup, step by step

1. **Meta app**: follow [docs/META_SETUP.md](docs/META_SETUP.md).
2. **Firebase project and backend deploy**: follow [docs/FIREBASE_SETUP.md](docs/FIREBASE_SETUP.md).
3. Put `google-services.json` in `app/`, fill in `local.properties`, then build and install.
4. Open ReelBridge, tap **Connect your Facebook Page**, then **Continue with Facebook**. Allow the
   permissions and select your Page. (If you manage exactly one publishable Page, it's selected automatically.)
5. Optionally turn on **Automatic publishing** in Settings.
6. In Instagram, open one of **your** Reels, tap **Share**, and choose **Post to Facebook Reels**. Or share the video file
   from your gallery.

## Testing status

| Area | How it's verified |
|---|---|
| Share classification, Instagram URL parsing, video validation, captions, idempotency keys, statuses, retry policy | `core` JUnit tests (29) |
| Share intents on a real device: text, other links, Stories, images, videos, Instagram links; Setup-required path | Instrumented Compose tests on the emulator |
| Copy + SHA-256 + MediaMetadataRetriever metadata + thumbnail + validation on real MP4 files | Instrumented tests with committed sample clips |
| Graph API client and the START/UPLOAD/FINISH pipeline: success, processing hand-off, crash recovery, retries, token expiry, permission errors, invalid Page, Meta processing errors, hosted upload, token redaction, appsecret_proof | Backend tests (27) against an in-memory Meta fake that enforces the documented flow |
| Firestore and Storage security rules | 13 tests on the real Firebase emulators |
| **Real publishing to Facebook** | **Not verified.** It needs a Meta app, a Firebase project and a Page (see setup). The code follows Meta's documented flow, but no live post was made while building this. |

## Known limitations

- **Instagram's share sheet sends only a link.** Fully automatic Instagram → Facebook publishing works for Reels on
  *your own* Instagram professional account linked to your Page (requires `instagram_basic`). It looks through roughly
  the 500 most recent posts. For anything else, share the video file itself.
- **Duration of Instagram imports isn't checked before upload.** The Instagram API doesn't report it. If a Reel is
  longer than Facebook allows, Meta rejects it and the error appears in History.
- **App Review.** For anyone without a role on your Meta app, Meta's App Review and Business Verification are required
  before the Page permissions work.
- **Notifications** come from a WorkManager status watcher on the device. They don't use push (FCM).
