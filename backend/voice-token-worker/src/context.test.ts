import { describe, it, expect } from "vitest";
import {
  capEntryText,
  MAX_ENTRY_BYTES,
  buildRoomName,
  buildMetadata,
} from "./context";

describe("capEntryText", () => {
  it("returns short text unchanged and not truncated", () => {
    const r = capEntryText("hello world");
    expect(r.text).toBe("hello world");
    expect(r.truncated).toBe(false);
  });

  it("keeps the most recent bytes when over the cap and marks truncated", () => {
    const long = "x".repeat(MAX_ENTRY_BYTES + 500) + "TAIL";
    const r = capEntryText(long);
    expect(r.truncated).toBe(true);
    expect(r.text.endsWith("TAIL")).toBe(true);
    expect(Buffer.byteLength(r.text, "utf8")).toBeLessThanOrEqual(MAX_ENTRY_BYTES);
  });

  it("handles null/undefined as empty, not truncated", () => {
    expect(capEntryText(undefined).text).toBe("");
    expect(capEntryText(null).truncated).toBe(false);
  });
});

describe("buildRoomName", () => {
  it("uses userId + entryId + timestamp", () => {
    const name = buildRoomName("user-abc", "entry-123", 1700000000000);
    expect(name).toBe("freewrite-user-abc-entry-123-1700000000000");
  });
  it("uses 'transient' when no entryId", () => {
    const name = buildRoomName("user-abc", null, 1700000000000);
    expect(name).toBe("freewrite-user-abc-transient-1700000000000");
  });
});

describe("buildMetadata", () => {
  it("nests context under a context key and stamps userId", () => {
    const meta = buildMetadata("user-abc", {
      entryType: "text",
      entryDate: "May 30",
      entryText: "hi",
      hasTranscript: true,
      truncated: false,
      modality: "voice",
    });
    const parsed = JSON.parse(meta);
    expect(parsed.userId).toBe("user-abc");
    expect(parsed.context.entryType).toBe("text");
    expect(parsed.context.entryText).toBe("hi");
  });
});
