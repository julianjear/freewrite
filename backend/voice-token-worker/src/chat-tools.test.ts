import { afterEach, describe, expect, it, vi } from "vitest";
import { executeChatTool } from "./chat-tools";

describe("chat tools", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("searches the current note without an external service", async () => {
    const result = await executeChatTool(
      "search_current_note",
      { query: "hard conversation" },
      "I keep avoiding the hard conversation.\n\nThe product work feels easy by comparison.",
    );
    expect(result.result.matches).toEqual([
      { paragraph: 1, text: "I keep avoiding the hard conversation." },
    ]);
    expect(result.summary).toContain("1 matching passage");
  });

  it("returns tool failures as data instead of throwing", async () => {
    await expect(executeChatTool("not_real", {}, "note")).resolves.toMatchObject({
      result: { error: "unknown tool: not_real" },
    });
  });

  it("keeps image results renderable and uses the descriptive fallback query", async () => {
    const responses = [
      {
        pages: [
          { key: "File:Fallingwater tour.webm", title: "Video", thumbnail: { url: "https://img/thumb/v/60px-tour.jpg" } },
          { key: "File:Fallingwater exterior.jpg", title: "Exterior", thumbnail: { url: "https://img/thumb/a/60px-exterior.jpg" } },
        ],
      },
      {
        pages: [
          { key: "File:Fallingwater waterfall.png", title: "Waterfall", thumbnail: { url: "https://img/thumb/b/60px-waterfall.png" } },
        ],
      },
    ];
    const requestedURLs: string[] = [];
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      requestedURLs.push(String(input));
      return new Response(JSON.stringify(responses.shift()), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = await executeChatTool(
      "image_search",
      { subject: "Fallingwater", query: "Fallingwater exterior waterfall" },
      "",
    );
    const images = result.result.images as Array<{ title: string }>;
    expect(images.map((image) => image.title)).toEqual(["Exterior", "Waterfall"]);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(requestedURLs[1]).toContain("Fallingwater+exterior+waterfall+filetype%3Abitmap");
  });
});
