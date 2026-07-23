import { describe, expect, it } from "vitest";
import { generateKeyPair, SignJWT } from "jose";
import { HTML_ARTIFACT_INSTRUCTION, handleChat, type ChatEnv, type WaitUntilContext } from "./chat";

async function es256() {
  const { publicKey, privateKey } = await generateKeyPair("ES256");
  return { publicKey: publicKey as CryptoKey, privateKey: privateKey as CryptoKey };
}

const testEnv = {
  SUPABASE_URL: "https://test.supabase.co",
  ALLOWED_ORIGIN: "*",
  OPENAI_API_KEY: "test-key",
  CHAT_RATE_LIMITER: { limit: async () => ({ success: true }) },
} satisfies ChatEnv;

async function token(privateKey: CryptoKey): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ role: "authenticated", email: "writer@example.com" })
    .setProtectedHeader({ alg: "ES256" })
    .setSubject("user-123")
    .setIssuer(`${testEnv.SUPABASE_URL}/auth/v1`)
    .setAudience("authenticated")
    .setIssuedAt(now)
    .setExpirationTime(now + 600)
    .sign(privateKey);
}

function context(): WaitUntilContext {
  return {
    waitUntil(promise: Promise<unknown>) { void promise; },
  };
}

function request(accessToken?: string, body: unknown = {}) {
  return new Request("https://worker.example/chat/stream", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(accessToken ? { authorization: `Bearer ${accessToken}` } : {}),
    },
    body: JSON.stringify(body),
  });
}

const validBody = {
  conversationId: "123e4567-e89b-42d3-a456-426614174000",
  entryId: "123e4567-e89b-42d3-a456-426614174001",
  entryType: "text",
  entryDate: "Jul 18",
  entryText: "I keep avoiding the hard conversation.",
  messages: [{ role: "user", content: "What do you notice?" }],
  model: "gpt-5.6-terra",
  reasoningEffort: "low",
};

describe("handleChat", () => {
  it("requires a bearer token", async () => {
    const keys = await es256();
    const response = await handleChat(request(), testEnv, context(), keys.publicKey);
    expect(response.status).toBe(401);
  });

  it("validates the last history message", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const response = await handleChat(
      request(accessToken, { ...validBody, messages: [{ role: "assistant", content: "hi" }] }),
      testEnv,
      context(),
      keys.publicKey,
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "last message must be from the user" });
  });

  it("streams text, usage, and finish events from the model", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const modelFetch: typeof fetch = async (_input, init) => {
      const sent = JSON.parse(String(init?.body)) as Record<string, unknown>;
      expect(sent.store).toBe(false);
      expect(sent.stream).toBe(true);
      expect(sent.instructions).toContain("current_note");
      expect(String(sent.instructions).endsWith(HTML_ARTIFACT_INSTRUCTION)).toBe(true);
      expect(sent.tools).toBeUndefined();
      const events = [
        { type: "response.output_text.delta", delta: "You already named it." },
        {
          type: "response.completed",
          response: {
            id: "resp_test",
            model: "gpt-5.6-terra",
            output: [{ type: "message", role: "assistant", content: [] }],
            usage: {
              input_tokens: 100,
              input_tokens_details: { cached_tokens: 40 },
              output_tokens: 10,
              output_tokens_details: { reasoning_tokens: 3 },
              total_tokens: 110,
            },
          },
        },
      ].map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
      return new Response(events, { status: 200, headers: { "content-type": "text/event-stream" } });
    };
    const response = await handleChat(
      request(accessToken, validBody), testEnv, context(), keys.publicKey, modelFetch,
    );
    expect(response.status).toBe(200);
    const stream = await response.text();
    expect(stream).toContain('"type":"text-delta"');
    expect(stream).toContain('"type":"usage"');
    expect(stream).toContain('"cachedInputTokens":40');
    expect(stream).toContain('"reasoningTokens":3');
    expect(stream).toContain('"type":"finish"');
    expect(stream).toContain('"responseId":"resp_test"');
  });

  it("serializes replayed assistant history as output text", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const modelFetch: typeof fetch = async (_input, init) => {
      const sent = JSON.parse(String(init?.body)) as Record<string, unknown>;
      const input = sent.input as Array<{
        role: string;
        content: Array<{ type: string; text: string }>;
      }>;
      expect(input.slice(-2)).toMatchObject([
        { role: "assistant", content: [{ type: "output_text", text: "Earlier reflection" }] },
        { role: "user", content: [{ type: "input_text", text: "Help me go further" }] },
      ]);
      return new Response([
        { type: "response.output_text.delta", delta: "<!doctype html><html></html>" },
        { type: "response.completed", response: { id: "resp_followup", model: "gpt-5.6-sol", output: [], usage: {} } },
      ].map((event) => `data: ${JSON.stringify(event)}\n\n`).join(""));
    };
    const response = await handleChat(
      request(accessToken, {
        ...validBody,
        model: "gpt-5.6-sol",
        messages: [
          { role: "assistant", content: "Earlier reflection" },
          { role: "user", content: "Help me go further" },
        ],
      }),
      testEnv, context(), keys.publicKey, modelFetch,
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("resp_followup");
  });

  it("accepts an empty opening history and injects the friend turn privately", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const modelFetch: typeof fetch = async (_input, init) => {
      const sent = JSON.parse(String(init?.body)) as Record<string, unknown>;
      const input = sent.input as Array<{ role: string; content: Array<{ text: string }> }>;
      expect(input).toHaveLength(1);
      expect(input[0].role).toBe("user");
      expect(input[0].content[0].text).toContain("old friend");
      return new Response([
        { type: "response.output_text.delta", delta: "<!doctype html><html></html>" },
        { type: "response.completed", response: { id: "resp_open", model: "gpt-5.6-terra", output: [], usage: {} } },
      ].map((event) => `data: ${JSON.stringify(event)}\n\n`).join(""));
    };
    const response = await handleChat(
      request(accessToken, { ...validBody, mode: "opening", messages: [] }),
      testEnv, context(), keys.publicKey, modelFetch,
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("resp_open");
  });

  it("runs reflection questions as a separate structured call after the opening", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const modelFetch: typeof fetch = async (_input, init) => {
      const sent = JSON.parse(String(init?.body)) as Record<string, unknown>;
      expect(sent.instructions).toContain("REFLECTION QUESTIONS TO GO DEEPER");
      expect(sent.instructions).toContain("additional_recent_writing");
      expect(sent.instructions).not.toContain(HTML_ARTIFACT_INSTRUCTION);
      expect(sent.tools).toBeUndefined();
      expect(sent.text).toMatchObject({ format: { type: "json_schema", name: "reflection_questions" } });
      const content = JSON.stringify({ questions: ["One?", "Two?", "Three?", "Four?", "Five?", "Six?"] });
      return new Response([
        { type: "response.output_text.delta", delta: content },
        { type: "response.completed", response: { id: "resp_questions", model: "gpt-5.6-terra", output: [], usage: {} } },
      ].map((event) => `data: ${JSON.stringify(event)}\n\n`).join(""));
    };
    const response = await handleChat(
      request(accessToken, {
        ...validBody,
        mode: "questions",
        recentWriting: "Yesterday I said the decision could not keep waiting.",
        messages: [{ role: "assistant", content: "The opening reflection." }],
      }),
      testEnv, context(), keys.publicKey, modelFetch,
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("resp_questions");
  });

  it("automatically opens an empty note without inventing note content", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const modelFetch: typeof fetch = async (_input, init) => {
      const sent = JSON.parse(String(init?.body)) as Record<string, unknown>;
      const input = sent.input as Array<{ role: string; content: Array<{ text: string }> }>;
      expect(input[0].content[0].text).toContain("blank page");
      expect(input[0].content[0].text).toContain("do not invent");
      return new Response([
        { type: "response.output_text.delta", delta: "<!doctype html><html></html>" },
        { type: "response.completed", response: { id: "resp_blank", model: "gpt-5.6-terra", output: [], usage: {} } },
      ].map((event) => `data: ${JSON.stringify(event)}\n\n`).join(""));
    };
    const response = await handleChat(
      request(accessToken, { ...validBody, entryText: "", mode: "opening", messages: [] }),
      testEnv, context(), keys.publicKey, modelFetch,
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("resp_blank");
  });

  it("returns a configuration error for Claude without an Anthropic key", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const response = await handleChat(
      request(accessToken, { ...validBody, model: "claude-sonnet-5" }),
      testEnv, context(), keys.publicKey,
    );
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ code: "provider_not_configured", provider: "anthropic" });
  });

  it("streams Claude HTML and its detailed usage envelope", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const anthropicEnv = { ...testEnv, ANTHROPIC_API_KEY: "anthropic-test-key" };
    const modelFetch: typeof fetch = async (_input, init) => {
      const sent = JSON.parse(String(init?.body)) as Record<string, unknown>;
      expect(sent.model).toBe("claude-sonnet-5");
      expect(sent.thinking).toEqual({ type: "adaptive", display: "omitted" });
      expect(sent.output_config).toEqual({ effort: "low" });
      expect(sent.tools).toBeUndefined();
      expect(sent.tool_choice).toBeUndefined();
      expect(sent.max_tokens).toBe(7_000);
      const events = [
        { type: "message_start", message: { id: "msg_test", model: "claude-sonnet-5", usage: { input_tokens: 80, cache_read_input_tokens: 20, cache_creation_input_tokens: 10, output_tokens: 1 } } },
        { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "<!doctype html><html></html>" } },
        { type: "content_block_stop", index: 0 },
        { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 30, output_tokens_details: { thinking_tokens: 9 } } },
        { type: "message_stop" },
      ].map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join("");
      return new Response(events, { status: 200, headers: { "content-type": "text/event-stream" } });
    };
    const response = await handleChat(
      request(accessToken, {
        ...validBody,
        model: "claude-sonnet-5",
        messages: [{ role: "user", content: "Reflect this back. Do not search the web." }],
      }),
      anthropicEnv, context(), keys.publicKey, modelFetch,
    );
    expect(response.status).toBe(200);
    const stream = await response.text();
    expect(stream).toContain('"model":"claude-sonnet-5"');
    expect(stream).toContain('"cachedInputTokens":20');
    expect(stream).toContain('"cacheWriteInputTokens":10');
    expect(stream).toContain('"reasoningTokens":9');
  });

  it("constrains Claude reflection questions to the required JSON schema", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const anthropicEnv = { ...testEnv, ANTHROPIC_API_KEY: "anthropic-test-key" };
    const modelFetch: typeof fetch = async (_input, init) => {
      const sent = JSON.parse(String(init?.body)) as Record<string, unknown>;
      expect(sent.tools).toBeUndefined();
      expect(sent.output_config).toMatchObject({
        effort: "low",
        format: {
          type: "json_schema",
          schema: {
            type: "object",
            properties: {
              questions: {
                type: "object",
                properties: {
                  question1: { type: "string" },
                  question2: { type: "string" },
                  question3: { type: "string" },
                  question4: { type: "string" },
                  question5: { type: "string" },
                  question6: { type: "string" },
                },
                required: [
                  "question1", "question2", "question3",
                  "question4", "question5", "question6",
                ],
                additionalProperties: false,
              },
            },
            required: ["questions"],
            additionalProperties: false,
          },
        },
      });
      const content = JSON.stringify({
        questions: {
          question1: "One?",
          question2: "Two?",
          question3: "Three?",
          question4: "Four?",
          question5: "Five?",
          question6: "Six?",
        },
      });
      return new Response([
        { type: "message_start", message: { id: "msg_questions", model: "claude-sonnet-5", usage: {} } },
        { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: content } },
        { type: "content_block_stop", index: 0 },
        { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: {} },
        { type: "message_stop" },
      ].map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(""));
    };
    const response = await handleChat(
      request(accessToken, {
        ...validBody,
        mode: "questions",
        model: "claude-sonnet-5",
        recentWriting: "Yesterday I said the decision could not keep waiting.",
        messages: [{ role: "assistant", content: "The opening reflection." }],
      }),
      anthropicEnv, context(), keys.publicKey, modelFetch,
    );
    expect(response.status).toBe(200);
    const stream = await response.text();
    expect(stream).toContain("msg_questions");
    const outputEvents = stream.split("\n")
      .filter((line) => line.startsWith("data: "))
      .map((line) => JSON.parse(line.slice(6)) as { type: string; delta?: string });
    let visible = "";
    for (const event of outputEvents) {
      if (event.type === "text-reset") visible = "";
      if (event.type === "text-delta") visible += event.delta ?? "";
    }
    expect(JSON.parse(visible)).toEqual({
      questions: ["One?", "Two?", "Three?", "Four?", "Five?", "Six?"],
    });
  });

  it("offers only explicitly relevant tools to a Claude reply", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const anthropicEnv = { ...testEnv, ANTHROPIC_API_KEY: "anthropic-test-key" };
    const modelFetch: typeof fetch = async (_input, init) => {
      const sent = JSON.parse(String(init?.body)) as Record<string, unknown>;
      expect(sent.tools).toEqual([
        { type: "web_search_20250305", name: "web_search", max_uses: 3 },
      ]);
      expect(sent.tool_choice).toEqual({ type: "auto", disable_parallel_tool_use: true });
      return new Response([
        { type: "message_start", message: { id: "msg_research", model: "claude-sonnet-5", usage: {} } },
        { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "<!doctype html><html></html>" } },
        { type: "content_block_stop", index: 0 },
        { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: {} },
        { type: "message_stop" },
      ].map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(""));
    };
    const response = await handleChat(
      request(accessToken, {
        ...validBody,
        model: "claude-sonnet-5",
        messages: [{ role: "user", content: "Search the web for current sources about voice latency." }],
      }),
      anthropicEnv, context(), keys.publicKey, modelFetch,
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("msg_research");
  });

  it("hides Anthropic server implementation helpers and normalizes plain text to HTML", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const anthropicEnv = { ...testEnv, ANTHROPIC_API_KEY: "anthropic-test-key" };
    const modelFetch: typeof fetch = async () => {
      const events = [
        { type: "message_start", message: { id: "msg_internal", model: "claude-sonnet-5", usage: {} } },
        { type: "content_block_start", index: 0, content_block: { type: "server_tool_use", id: "srv_internal", name: "bash_code_execution", input: {} } },
        { type: "content_block_stop", index: 0 },
        { type: "content_block_start", index: 1, content_block: { type: "bash_code_execution_tool_result", tool_use_id: "srv_internal", content: [] } },
        { type: "content_block_stop", index: 1 },
        { type: "content_block_start", index: 2, content_block: { type: "text", text: "" } },
        { type: "content_block_delta", index: 2, delta: { type: "text_delta", text: "A direct answer without markup." } },
        { type: "content_block_stop", index: 2 },
        { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: {} },
        { type: "message_stop" },
      ].map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join("");
      return new Response(events, { status: 200, headers: { "content-type": "text/event-stream" } });
    };
    const response = await handleChat(
      request(accessToken, {
        ...validBody,
        model: "claude-sonnet-5",
        messages: [{ role: "user", content: "Search the web for current voice agent research." }],
      }),
      anthropicEnv, context(), keys.publicKey, modelFetch,
    );
    const stream = await response.text();
    expect(stream).not.toContain("bash_code_execution");
    const outputEvents = stream.split("\n")
      .filter((line) => line.startsWith("data: "))
      .map((line) => JSON.parse(line.slice(6)) as { type: string; delta?: string });
    let visible = "";
    for (const event of outputEvents) {
      if (event.type === "text-reset") visible = "";
      if (event.type === "text-delta") visible += event.delta ?? "";
    }
    expect(visible).toContain("<!doctype html>");
    expect(visible).toContain("A direct answer without markup.");
  });

  it("continues an Anthropic pause_turn response", async () => {
    const keys = await es256();
    const accessToken = await token(keys.privateKey);
    const anthropicEnv = { ...testEnv, ANTHROPIC_API_KEY: "anthropic-test-key" };
    let requestCount = 0;
    const modelFetch: typeof fetch = async (_input, init) => {
      requestCount += 1;
      const sent = JSON.parse(String(init?.body)) as Record<string, unknown>;
      if (requestCount === 2) {
        const messages = sent.messages as Array<Record<string, unknown>>;
        expect(messages.at(-1)?.role).toBe("assistant");
        expect((sent.tools as Array<Record<string, unknown>>)[0]).toMatchObject({
          type: "web_search_20250305", name: "web_search",
        });
      }
      const stopReason = requestCount === 1 ? "pause_turn" : "end_turn";
      const text = requestCount === 1 ? "" : "<!doctype html><html></html>";
      const events = [
        { type: "message_start", message: { id: `msg_${requestCount}`, model: "claude-sonnet-5", usage: {} } },
        { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } },
        { type: "content_block_stop", index: 0 },
        { type: "message_delta", delta: { stop_reason: stopReason }, usage: {} },
        { type: "message_stop" },
      ].map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join("");
      return new Response(events, { status: 200, headers: { "content-type": "text/event-stream" } });
    };
    const response = await handleChat(
      request(accessToken, {
        ...validBody,
        model: "claude-sonnet-5",
        messages: [{ role: "user", content: "Search the web for current voice agent research." }],
      }),
      anthropicEnv, context(), keys.publicKey, modelFetch,
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("<!doctype html>");
    expect(requestCount).toBe(2);
  });
});
