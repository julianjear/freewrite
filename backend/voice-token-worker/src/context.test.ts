import { describe, it, expect } from "vitest";
import {
  capEntryText,
  MAX_ENTRY_BYTES,
  buildRoomName,
  buildMetadata,
  parseVoiceConfig,
  sanitizeEntryId,
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
  it("uses only an opaque nonce + timestamp", () => {
    const name = buildRoomName("123E4567-E89B-42D3-A456-426614174000", 1700000000000);
    expect(name).toBe("freewrite-123e4567-e89b-42d3-a456-426614174000-1700000000000");
  });
});

describe("buildMetadata", () => {
  it("nests context under a context key and stamps userId", () => {
    const config = parseVoiceConfig(null);
    const meta = buildMetadata("user-abc", {
      entryType: "text",
      entryDate: "May 30",
      entryText: "hi",
      hasTranscript: true,
      chatHistory: "Julian: I am deciding.\n\nFreewrite AI: Name the real choice.",
      startingQuestion: "What do you actually want?",
      truncated: false,
      modality: "voice",
    }, config, "123e4567-e89b-42d3-a456-426614174000");
    const parsed = JSON.parse(meta);
    expect(parsed.userId).toBe("user-abc");
    expect(parsed.context.entryType).toBe("text");
    expect(parsed.context.entryText).toBe("hi");
    expect(parsed.context.chatHistory).toContain("Name the real choice");
    expect(parsed.context.startingQuestion).toBe("What do you actually want?");
    expect(parsed.voiceConfig.profileId).toBe("cascade-gemini-3.5-flash");
  });
});

describe("voice configuration", () => {
  it("defaults to the versioned production cascade", () => {
    const config = parseVoiceConfig(undefined);
    expect(config.version).toBe(1);
    expect(config.profileId).toBe("cascade-gemini-3.5-flash");
    expect(config.turnStrategy).toBe("livekit-audio");
    expect(config.supervisorIntervalSeconds).toBe(30);
    expect(config.supervisorEffort).toBe("high");
  });

  it("accepts current deep strategists and validates provider effort", () => {
    expect(parseVoiceConfig({ supervisorModel: "claude-opus-4-8", supervisorEffort: "max" }).supervisorEffort).toBe("max");
    expect(parseVoiceConfig({ supervisorModel: "gpt-5.6-sol", supervisorEffort: "xhigh" }).supervisorModel).toBe("gpt-5.6-sol");
    expect(() => parseVoiceConfig({ supervisorModel: "gemini-3.5-flash", supervisorEffort: "max" })).toThrow();
  });

  it("rejects unknown profiles and Flux on native realtime", () => {
    expect(() => parseVoiceConfig({ profileId: "invented" })).toThrow();
    expect(() => parseVoiceConfig({ profileId: "realtime-gpt-2.1", turnStrategy: "flux" })).toThrow();
  });

  it("accepts canonical UUID entry IDs only", () => {
    expect(sanitizeEntryId("123E4567-E89B-42D3-A456-426614174000"))
      .toBe("123e4567-e89b-42d3-a456-426614174000");
    expect(() => sanitizeEntryId("entry-1")).toThrow();
  });
});
