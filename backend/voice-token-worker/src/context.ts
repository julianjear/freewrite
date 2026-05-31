// Cap embedded entry text so the signed JWT (and the HTTP header carrying it)
// stays well under practical limits. Recent writing is the most relevant, so
// we keep the TAIL of the text. ~6 KB leaves headroom for the rest of the JWT.
export const MAX_ENTRY_BYTES = 6144;

export interface CapResult {
  text: string;
  truncated: boolean;
}

export function capEntryText(input: string | null | undefined): CapResult {
  const text = input ?? "";
  const bytes = Buffer.byteLength(text, "utf8");
  if (bytes <= MAX_ENTRY_BYTES) return { text, truncated: false };

  // Keep the last MAX_ENTRY_BYTES bytes, then repair any split UTF-8 char.
  const buf = Buffer.from(text, "utf8");
  let start = buf.length - MAX_ENTRY_BYTES;
  // Advance start past continuation bytes (0b10xxxxxx) to a char boundary.
  while (start < buf.length && (buf[start] & 0xc0) === 0x80) start++;
  return { text: buf.toString("utf8", start), truncated: true };
}

export interface VoiceContext {
  entryType: "text" | "video";
  entryDate: string;
  entryText: string;
  hasTranscript: boolean;
  truncated: boolean;
  modality: "voice";
}

export function buildRoomName(
  userId: string,
  entryId: string | null,
  nowMs: number,
): string {
  const mid = entryId ?? "transient";
  return `freewrite-${userId}-${mid}-${nowMs}`;
}

export function buildMetadata(userId: string, context: VoiceContext): string {
  return JSON.stringify({ userId, context });
}
