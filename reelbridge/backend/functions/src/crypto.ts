import { createCipheriv, createDecipheriv, createHmac, randomBytes } from "node:crypto";

/**
 * AES-256-GCM envelope for Meta tokens at rest. The key comes from Secret Manager
 * (TOKEN_ENCRYPTION_KEY, base64 of 32 random bytes). Format: v1:<iv>:<tag>:<ciphertext> (base64).
 */
export function parseKey(base64Key: string): Buffer {
  const key = Buffer.from(base64Key.trim(), "base64");
  if (key.length !== 32) throw new Error("TOKEN_ENCRYPTION_KEY must be 32 bytes, base64 encoded");
  return key;
}

export function encrypt(plaintext: string, key: Buffer, aad = "reelbridge"): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(Buffer.from(aad));
  const ct = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return ["v1", iv.toString("base64"), cipher.getAuthTag().toString("base64"), ct.toString("base64")].join(":");
}

export function decrypt(envelope: string, key: Buffer, aad = "reelbridge"): string {
  const [version, iv, tag, ct] = envelope.split(":");
  if (version !== "v1" || !iv || !tag || ct === undefined) throw new Error("Unrecognized token envelope");
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(iv, "base64"));
  decipher.setAAD(Buffer.from(aad));
  decipher.setAuthTag(Buffer.from(tag, "base64"));
  return Buffer.concat([decipher.update(Buffer.from(ct, "base64")), decipher.final()]).toString("utf8");
}

/** Meta "appsecret_proof": HMAC-SHA256 of the access token keyed with the app secret. */
export function appSecretProof(accessToken: string, appSecret: string): string {
  return createHmac("sha256", appSecret).update(accessToken).digest("hex");
}
