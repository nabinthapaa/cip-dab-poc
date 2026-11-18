# Firebase setup

Requires the **Blaze (pay-as-you-go)** plan: Cloud Functions (2nd gen), Secret Manager, Cloud Tasks
and Cloud Scheduler are not available on Spark.

## 1. Project and apps

1. Create a project at <https://console.firebase.google.com>.
2. Add **two Android apps**: `com.reelbridge.app` and `com.reelbridge.app.debug` (add each with its
   SHA-1/SHA-256 fingerprint: `./gradlew :app:signingReport`).
3. Download `google-services.json` (it contains both clients) to `reelbridge/app/google-services.json`.
   It is git-ignored. For CI, store it base64-encoded as the repository secret `GOOGLE_SERVICES_JSON_B64`:
   `base64 -w0 app/google-services.json`.

Without this file the app still builds; it shows **Setup required** and publishes nothing.

## 2. Enable products

- **Authentication → Sign-in method → Facebook**: enable, paste the Meta App ID and App secret, copy the
  OAuth redirect URI into Meta (see META_SETUP.md).
- **Firestore**: create the database (production mode).
- **Storage**: create the default bucket.
- **App Check**: register the Android apps with **Play Integrity**. For debug builds, run the app once,
  copy the debug token printed in Logcat (`DebugAppCheckProvider`) into **App Check → Manage debug tokens**.
  Then enforce App Check for Firestore, Storage and Cloud Functions.

Optional: add a Storage lifecycle rule deleting `users/*/videos/*` older than 7 days (videos are already
deleted after a successful publish when `DELETE_VIDEO_AFTER_PUBLISH=true`).

## 3. Deploy the backend

```bash
npm install -g firebase-tools
cd reelbridge/backend
cp .firebaserc.example .firebaserc         # set your project id
cp functions/.env.example functions/.env.<project-id>   # set META_APP_ID etc.
firebase functions:secrets:set META_APP_SECRET
openssl rand -base64 32 | firebase functions:secrets:set TOKEN_ENCRYPTION_KEY --data-file=-
(cd functions && npm ci && npm test)
firebase deploy --only firestore:rules,firestore:indexes,storage,functions
```

Deployed functions:

| Function | Type | Purpose |
|---|---|---|
| `connectFacebook` | callable | Verify login token, exchange for long-lived, store tokens + Pages |
| `refreshFacebookPages` | callable | Re-read the Pages list |
| `selectFacebookPage` | callable | Choose the destination Page (checks publish rights) |
| `checkFacebookConnection` | callable | Token validity / permissions status |
| `disconnectFacebook` | callable | Delete all tokens; optionally revoke at Facebook |
| `resolveInstagramReel` | callable | Match a shared Instagram link against the user's own IG media |
| `importInstagramReel` | callable | Create a job for the user's own IG Reel |
| `retryPublishingJob` | callable | Re-queue a failed job (via Cloud Tasks) |
| `onPublishingJobCreated` | Firestore trigger | Validate + run a new job (START → UPLOAD → FINISH) |
| `publishJobTask` | Cloud Tasks queue | Runs retried jobs outside client requests |
| `publishingMaintenance` | every 5 min | Follow up on Meta processing, recover stale leases, auto-retry |

If you use `REELS_UPLOAD_MODE=hosted`, grant the functions' service account
`roles/iam.serviceAccountTokenCreator` on itself so it can sign Storage URLs.

The Cloud Tasks function needs the Cloud Functions service account to be allowed to enqueue
(`roles/cloudtasks.enqueuer`) and invoke (`roles/run.invoker`) – `firebase deploy` sets this up for
the default service account; if you use a custom one, grant both.

## 4. Region

Functions default to `us-central1`. To change it, set `RB_REGION` in
`functions/.env.<project-id>` **and** build the app with `reelbridge.functionsRegion=<region>`.
