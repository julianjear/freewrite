const TOOL_TIMEOUT_MS = 15_000;
const MAX_TOOL_TEXT_BYTES = 48 * 1024;

export interface ImageSearchResult {
  title: string;
  imageUrl: string;
  thumbnailUrl: string;
  sourceUrl: string;
}

export interface ToolExecutionResult {
  result: Record<string, unknown>;
  summary: string;
}

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

async function readBoundedText(response: Response, maxBytes: number): Promise<string> {
  const declaredLength = Number(response.headers.get("content-length") ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    throw new Error("response was too large");
  }
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new Error("response was too large");
    }
    chunks.push(value);
  }
  const all = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    all.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(all);
}

function publicURL(raw: string): URL | null {
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return null;
    // URL canonicalizes alternate IPv4 spellings (integer, hex, octal, and
    // abbreviated dotted forms), so reject every canonical IP literal rather
    // than trying to maintain an incomplete private-range list. Normal web
    // pages use domain hosts; this also covers IPv4-mapped and scoped IPv6.
    const host = parsed.hostname.toLowerCase()
      .replace(/^\[|\]$/g, "")
      .replace(/\.+$/, "");
    const isIPv4 = /^(?:\d{1,3}\.){3}\d{1,3}$/.test(host);
    const isIPv6 = host.includes(":");
    const blockedName = [
      "localhost", "local", "internal", "home", "lan", "test", "invalid",
      "example", "onion",
    ].some((suffix) => host === suffix || host.endsWith(`.${suffix}`));
    if (!host || isIPv4 || isIPv6 || blockedName) return null;
    return parsed;
  } catch {
    return null;
  }
}

function paragraphs(noteText: string): string[] {
  return noteText
    .split(/\n\s*\n|(?<=[.!?])\s+(?=[A-Z0-9])/)
    .map((part) => part.trim())
    .filter(Boolean);
}

function searchNote(noteText: string, query: string): ToolExecutionResult {
  const terms = query.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter((term) => term.length > 2);
  const matches = paragraphs(noteText)
    .map((text, index) => ({
      text,
      index,
      score: terms.reduce((score, term) => score + (text.toLowerCase().includes(term) ? 1 : 0), 0),
    }))
    .filter((item) => item.score > 0)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .slice(0, 5)
    .map(({ text, index }) => ({ paragraph: index + 1, text: text.slice(0, 1_600) }));
  return {
    result: { query, matches },
    summary: matches.length === 1 ? "Found 1 matching passage" : `Found ${matches.length} matching passages`,
  };
}

async function wikimediaPages(searchQuery: string): Promise<unknown[]> {
  const url = new URL("https://api.wikimedia.org/core/v1/commons/search/page");
  url.search = new URLSearchParams({
    q: searchQuery,
    limit: "12",
  }).toString();

  const response = await fetch(url, {
    headers: {
      // Wikimedia requires an identifying user agent for API clients.
      "User-Agent": "FreewriteAI/1.0 (https://freewrite-voice-token.infinite-0b9.workers.dev)",
      Accept: "application/json",
    },
    signal: AbortSignal.timeout(TOOL_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`image search failed (HTTP ${response.status})`);
  const raw = JSON.parse(await readBoundedText(response, MAX_TOOL_TEXT_BYTES)) as unknown;
  const root = raw && typeof raw === "object" ? raw as Record<string, unknown> : {};
  return Array.isArray(root.pages) ? root.pages : [];
}

async function imageSearch(query: string, subject: string): Promise<ToolExecutionResult> {
  // `incategory:` requires a real Commons category page name. The model gives
  // us a free-text subject, so use it as a ranked term and constrain results
  // to renderable bitmap files instead of guessing a category.
  const primary = await wikimediaPages(`${subject} filetype:bitmap`);
  const images: ImageSearchResult[] = [];
  const seen = new Set<string>();
  const appendPages = (pages: unknown[]) => {
    for (const page of pages) {
      if (!page || typeof page !== "object") continue;
      const record = page as Record<string, unknown>;
      const key = asString(record.key);
      const thumbnail = record.thumbnail && typeof record.thumbnail === "object"
        ? record.thumbnail as Record<string, unknown>
        : {};
      const smallThumbnail = asString(thumbnail.url);
      const lowerKey = key.toLowerCase();
      if (
        !key.startsWith("File:") || !smallThumbnail || seen.has(key) ||
        !/\.(?:jpe?g|png|webp|gif|tiff?)$/i.test(key) ||
        /(logo|marker|sign|souvenir|prohibition)/.test(lowerKey)
      ) continue;
      seen.add(key);
      const thumbnailUrl = smallThumbnail.replace(/\/60px-/, "/900px-");
      const imageUrl = thumbnailUrl
        .replace("/thumb/", "/")
        .replace(/\/\d+px-[^/]+$/, "");
      const sourceUrl = `https://commons.wikimedia.org/wiki/${encodeURIComponent(key.replaceAll(" ", "_"))}`;
      images.push({
        title: (asString(record.title) || key).replace(/^File:/, ""),
        imageUrl,
        thumbnailUrl,
        sourceUrl,
      });
      if (images.length === 4) break;
    }
  };
  appendPages(primary);
  if (images.length < 4) appendPages(await wikimediaPages(`${query} filetype:bitmap`));
  return {
    result: { query, subject, provider: "Wikimedia Commons", images },
    summary: images.length === 1 ? "Found 1 image" : `Found ${images.length} images`,
  };
}

async function extractURL(rawURL: string): Promise<ToolExecutionResult> {
  const parsed = publicURL(rawURL);
  if (!parsed) throw new Error("only public http(s) URLs can be read");
  const readerURL = `https://r.jina.ai/${parsed.toString()}`;
  const response = await fetch(readerURL, {
    headers: { Accept: "text/markdown" },
    signal: AbortSignal.timeout(TOOL_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`could not read the page (HTTP ${response.status})`);
  const markdown = (await readBoundedText(response, MAX_TOOL_TEXT_BYTES)).trim();
  if (markdown.length < 100) throw new Error("the page had too little readable content");
  const titleMatch = markdown.match(/^Title:\s*(.+)$/m) ?? markdown.match(/^#\s+(.+)$/m);
  const title = titleMatch?.[1]?.trim() || parsed.hostname;
  return {
    result: { url: parsed.toString(), title, content: markdown.slice(0, 40_000), source: "Jina Reader" },
    summary: `Read ${title}`,
  };
}

export async function executeChatTool(
  name: string,
  args: Record<string, unknown>,
  noteText: string,
): Promise<ToolExecutionResult> {
  try {
    if (name === "search_current_note") {
      const query = asString(args.query);
      if (!query) throw new Error("query is required");
      return searchNote(noteText, query);
    }
    if (name === "image_search") {
      const query = asString(args.query);
      if (!query) throw new Error("query is required");
      const subject = asString(args.subject) || query.split(/[,;:\-]/)[0].trim();
      return await imageSearch(query, subject.slice(0, 120));
    }
    if (name === "read_url") {
      const url = asString(args.url);
      if (!url) throw new Error("url is required");
      return await extractURL(url);
    }
    return { result: { error: `unknown tool: ${name}` }, summary: "Tool is unavailable" };
  } catch (error) {
    const message = error instanceof Error ? error.message : "tool failed";
    return { result: { error: message }, summary: message };
  }
}
