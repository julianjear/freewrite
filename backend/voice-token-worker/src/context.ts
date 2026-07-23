// JWT metadata must remain comfortably below proxy/header limits.
export const MAX_ENTRY_BYTES = 6144;
export const MAX_CHAT_HISTORY_BYTES = 5120;
export const MAX_STARTING_QUESTION_BYTES = 1200;

export interface CapResult { text: string; truncated: boolean }

export function capEntryText(input: string | null | undefined,
                             maxBytes: number = MAX_ENTRY_BYTES): CapResult {
  const text = input ?? "";
  const bytes = Buffer.byteLength(text, "utf8");
  if (bytes <= maxBytes) return { text, truncated: false };
  const buf = Buffer.from(text, "utf8");
  let start = buf.length - maxBytes;
  while (start < buf.length && (buf[start] & 0xc0) === 0x80) start++;
  return { text: buf.toString("utf8", start), truncated: true };
}

export interface VoiceContext {
  entryType: "text" | "video";
  entryDate: string;
  entryText: string;
  hasTranscript: boolean;
  chatHistory: string;
  startingQuestion: string | null;
  truncated: boolean;
  modality: "voice";
}

export const VOICE_PROFILES = {
  "cascade-gemini-3.5-flash": ["cascade", "google", "gemini-3.5-flash"],
  "cascade-gemini-3.1-flash-lite": ["cascade", "google", "gemini-3.1-flash-lite"],
  "cascade-gemini-3-flash-preview": ["cascade", "google", "gemini-3-flash-preview"],
  "cascade-gemini-2.5-flash": ["cascade", "google", "gemini-2.5-flash"],
  "cascade-gpt-5.6-terra": ["cascade", "openai", "gpt-5.6-terra"],
  "cascade-claude-haiku-4.5": ["cascade", "anthropic", "claude-haiku-4-5"],
  "realtime-gpt-2.1": ["realtime", "openai", "gpt-realtime-2.1"],
  "realtime-gpt-2.1-mini": ["realtime", "openai", "gpt-realtime-2.1-mini"],
  "realtime-gemini-3.1-flash-live-preview": ["realtime", "google", "gemini-3.1-flash-live-preview"],
  "realtime-grok-think-fast": ["realtime", "xai", "grok-voice-think-fast-1.0"],
} as const;

export type VoiceProfileId = keyof typeof VOICE_PROFILES;
export type ReasoningEffort = "minimal" | "low" | "medium";
export type SupervisorEffort = "low" | "medium" | "high" | "xhigh" | "max";
export type TurnStrategy = "livekit-audio" | "flux";

export interface VoiceSessionConfig {
  version: 1;
  profileId: VoiceProfileId;
  reasoningEffort: ReasoningEffort;
  supervisorEnabled: boolean;
  supervisorModel: "gemini-3.1-pro-preview" | "gemini-3.5-flash" | "claude-sonnet-5" | "claude-opus-4-8" | "gpt-5.6-sol";
  supervisorEffort: SupervisorEffort;
  supervisorIntervalSeconds: 15 | 20 | 30;
  observabilityEnabled: boolean;
  turnStrategy: TurnStrategy;
}

export const DEFAULT_VOICE_CONFIG: VoiceSessionConfig = {
  version: 1,
  profileId: "cascade-gemini-3.5-flash",
  reasoningEffort: "low",
  supervisorEnabled: true,
  supervisorModel: "gemini-3.1-pro-preview",
  supervisorEffort: "high",
  supervisorIntervalSeconds: 30,
  observabilityEnabled: true,
  turnStrategy: "livekit-audio",
};

function ownString(value: unknown, key: string): string | undefined {
  if (!value || typeof value !== "object") return undefined;
  const found = (value as Record<string, unknown>)[key];
  return typeof found === "string" ? found : undefined;
}

export function parseVoiceConfig(value: unknown): VoiceSessionConfig {
  if (value === undefined || value === null) return { ...DEFAULT_VOICE_CONFIG };
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("voiceConfig must be an object");
  }
  const raw = value as Record<string, unknown>;
  if ((raw.version ?? 1) !== 1) throw new Error("unsupported voiceConfig version");

  const profileId = ownString(raw, "profileId") ?? DEFAULT_VOICE_CONFIG.profileId;
  if (!(profileId in VOICE_PROFILES)) throw new Error("unsupported voice profile");
  const typedProfile = profileId as VoiceProfileId;

  const reasoning = ownString(raw, "reasoningEffort") ?? DEFAULT_VOICE_CONFIG.reasoningEffort;
  if (!(["minimal", "low", "medium"] as string[]).includes(reasoning)) {
    throw new Error("unsupported reasoning effort");
  }
  const supervisorModel = ownString(raw, "supervisorModel") ?? DEFAULT_VOICE_CONFIG.supervisorModel;
  if (!(supervisorModel === "gemini-3.1-pro-preview" || supervisorModel === "gemini-3.5-flash" || supervisorModel === "claude-sonnet-5" || supervisorModel === "claude-opus-4-8" || supervisorModel === "gpt-5.6-sol")) {
    throw new Error("unsupported supervisor model");
  }
  const supervisorEffort = ownString(raw, "supervisorEffort") ?? DEFAULT_VOICE_CONFIG.supervisorEffort;
  const allowedEfforts = supervisorModel.startsWith("gemini-")
    ? ["low", "medium", "high"]
    : ["low", "medium", "high", "xhigh", "max"];
  if (!allowedEfforts.includes(supervisorEffort)) throw new Error("unsupported supervisor effort");
  const interval = raw.supervisorIntervalSeconds ?? DEFAULT_VOICE_CONFIG.supervisorIntervalSeconds;
  if (!(interval === 15 || interval === 20 || interval === 30)) {
    throw new Error("unsupported supervisor interval");
  }
  const turnStrategy = ownString(raw, "turnStrategy") ?? DEFAULT_VOICE_CONFIG.turnStrategy;
  if (!(turnStrategy === "livekit-audio" || turnStrategy === "flux")) {
    throw new Error("unsupported turn strategy");
  }
  if (VOICE_PROFILES[typedProfile][0] === "realtime" && turnStrategy === "flux") {
    throw new Error("Flux requires a cascade profile");
  }

  return {
    version: 1,
    profileId: typedProfile,
    reasoningEffort: reasoning as ReasoningEffort,
    supervisorEnabled: raw.supervisorEnabled !== false,
    supervisorModel,
    supervisorEffort: supervisorEffort as SupervisorEffort,
    supervisorIntervalSeconds: interval,
    observabilityEnabled: raw.observabilityEnabled !== false,
    turnStrategy,
  };
}

export function sanitizeEntryId(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new Error("entryId must be a UUID");
  }
  return value.toLowerCase();
}

export function buildRoomName(nonce: string, nowMs: number): string {
  const safeNonce = nonce.toLowerCase().replace(/[^a-z0-9-]/g, "").slice(0, 40);
  if (!safeNonce) throw new Error("invalid room nonce");
  return `freewrite-${safeNonce}-${nowMs}`;
}

export function buildMetadata(
  userId: string,
  context: VoiceContext,
  voiceConfig: VoiceSessionConfig,
  entryId: string | null,
): string {
  return JSON.stringify({ userId, entryId, context, voiceConfig });
}
