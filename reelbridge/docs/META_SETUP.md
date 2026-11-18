# Meta (Facebook) developer setup

ReelBridge publishes through Meta's official **Reels Publishing API** on a Facebook Page
(`POST /{page-id}/video_reels`, three phases: `start` → upload to `rupload.facebook.com` → `finish`).
Nothing here can be skipped: without these steps the app can sign in to nothing and publish nothing.

> Meta changes requirements often. Before App Review, re-check the current
> [Reels Publishing API guide](https://developers.facebook.com/docs/video-api/guides/reels-publishing),
> [Permissions reference](https://developers.facebook.com/docs/permissions) and
> [Graph API changelog](https://developers.facebook.com/docs/graph-api/changelog).
> The Graph API version is configuration (`META_GRAPH_VERSION`, default `v26.0`), not code.

## 1. Create the app

1. <https://developers.facebook.com/apps> → **Create app** → use case **Manage everything on your Page**
   (or *Other* → *Business*).
2. Add the **Facebook Login** product (Android).
3. **App settings → Basic**: note the **App ID** and **App secret**.
   **App settings → Advanced → Security**: note the **Client token**.
4. Add an **Android platform**:
   - Package names: `com.reelbridge.app` (release) and `com.reelbridge.app.debug` (debug builds).
   - Class name: `com.reelbridge.app.MainActivity`.
   - Key hashes for every signing key you use:
     ```bash
     # debug key
     keytool -exportcert -alias androiddebugkey -keystore ~/.android/debug.keystore -storepass android \
       | openssl sha1 -binary | openssl base64
     # release key
     keytool -exportcert -alias reelbridge -keystore release.jks | openssl sha1 -binary | openssl base64
     ```
     For Play App Signing, also add the hash of Google's app signing key (Play Console → App integrity).
5. **Facebook Login → Settings → Valid OAuth Redirect URIs**: add the Firebase handler shown in
   Firebase Console → Authentication → Sign-in method → Facebook (`https://<project>.firebaseapp.com/__/auth/handler`).

## 2. Permissions ReelBridge requests

| Permission | Why | Required |
|---|---|---|
| `public_profile` | Default; identifies the Facebook user for Firebase sign-in. | yes |
| `pages_show_list` | List the Pages the person manages so they can pick a destination. | yes |
| `pages_read_engagement` | Read Page metadata (name, picture, linked Instagram account); Meta requires it alongside `pages_manage_posts`. | yes |
| `pages_manage_posts` | Create Reels on the Page (`/{page-id}/video_reels`). | yes |
| `instagram_basic` | **Optional.** Read the user's *own* Instagram professional account media so a shared Instagram link can be matched to their own Reel and its `media_url` used. | no |
| `business_management` | **Optional.** Needed when the Page is owned through a Business portfolio. | no |

The person must also have the **Create content** task on the Page (ReelBridge checks `tasks` and
only offers Pages where that is true).

## 3. Development mode vs. Live

- In **Development mode**, people with a role on the app (Admins, Developers, Testers under
  **App roles**) can grant all of the above without review. Use this for testing end to end.
- To let anyone else use ReelBridge you need **Advanced Access** via **App Review** for
  `pages_show_list`, `pages_read_engagement`, `pages_manage_posts` (and `instagram_basic` /
  `business_management` if used), plus **Business Verification**. Prepare:
  - a screencast: Facebook Login → Page selection → share a video to ReelBridge → Reel appears on the Page;
  - a privacy policy URL and data-deletion instructions (Disconnect in the app deletes all tokens
    and calls `DELETE /me/permissions` when the user ticks *Also remove permissions*).

## 4. Where each value goes

| Value | Where | Secret? |
|---|---|---|
| App ID | Android: `reelbridge.facebookAppId` (local.properties / CI secret `RB_FACEBOOK_APP_ID`); Functions: `META_APP_ID` in `functions/.env.<project>`; Firebase Auth Facebook provider | public |
| Client token | Android: `reelbridge.facebookClientToken` / CI secret `RB_FACEBOOK_CLIENT_TOKEN` | public (by Meta's design) |
| App secret | `firebase functions:secrets:set META_APP_SECRET`; Firebase Auth Facebook provider | **secret – never in the app** |

## 5. How tokens are handled

1. The app runs Facebook Login and receives a **short-lived user token**.
2. It signs in to Firebase with that token (Facebook provider) and calls `connectFacebook` once.
3. The function verifies the token with `debug_token` (correct app, valid, same Facebook user as the
   Firebase identity), exchanges it for a **long-lived user token**, reads `/me/accounts`, and stores
   the user token and each **Page token** encrypted (AES-256-GCM, key in Secret Manager) under
   `*/secrets/*` documents that security rules deny to every client.
4. Every Graph call from the backend includes `appsecret_proof`.
5. Page tokens derived from a long-lived user token do not expire on a schedule, but they are
   invalidated by password changes, permission removal or role changes. ReelBridge detects this
   (error 190 / 10 / 200-series), marks jobs **Reconnect Facebook**, and `checkFacebookConnection`
   shows token/permission status in the app.
