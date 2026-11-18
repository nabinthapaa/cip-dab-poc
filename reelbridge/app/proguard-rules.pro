# Firebase, Facebook SDK, WorkManager and Compose ship their own consumer rules.
# Keep Firestore model field names used by toObject()/reflection (we map manually, but be safe).
-keepattributes Signature,*Annotation*
-keep class com.reelbridge.app.data.model.** { *; }
