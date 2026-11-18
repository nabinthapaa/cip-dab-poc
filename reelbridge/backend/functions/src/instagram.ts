/** Mirrors com.reelbridge.core.share.InstagramUrls (identifier extraction only, no fetching). */
const INSTAGRAM = /^https?:\/\/(?:www\.|m\.)?(?:instagram\.com|instagr\.am)\/(?:[A-Za-z0-9._]+\/)?(reels?|p|tv)\/([A-Za-z0-9_\-.]+)\/?/i;

export function instagramShortcode(url: unknown): string | null {
  if (typeof url !== "string" || url.length > 2048) return null;
  const m = INSTAGRAM.exec(url.trim());
  return m ? m[2] : null;
}

export interface IgMedia {
  id: string;
  caption?: string;
  media_type?: string;
  media_product_type?: string;
  permalink?: string;
  media_url?: string;
  thumbnail_url?: string;
  timestamp?: string;
}

export function findByShortcode(items: IgMedia[], shortcode: string): IgMedia | undefined {
  return items.find((m) => m.permalink && instagramShortcode(m.permalink) === shortcode);
}

export function isVideo(m: IgMedia): boolean {
  return m.media_type === "VIDEO" || m.media_product_type === "REELS";
}
