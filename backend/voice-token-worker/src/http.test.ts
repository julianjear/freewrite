import { describe, expect, it } from "vitest";
import { cors, json } from "./http";

describe("HTTP response helpers", () => {
  it("allows only configured origins", () => {
    const env = { ALLOWED_ORIGIN: "https://freewrite.example, https://admin.example" };
    expect(cors(env, "https://freewrite.example")["Access-Control-Allow-Origin"])
      .toBe("https://freewrite.example");
    expect(cors(env, "https://other.example")["Access-Control-Allow-Origin"])
      .toBeUndefined();
  });

  it("supports wildcard CORS and JSON responses", async () => {
    const response = json({ ok: true }, 201, { ALLOWED_ORIGIN: "*" }, "https://freewrite.example");
    expect(response.status).toBe(201);
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(await response.json()).toEqual({ ok: true });
  });
});
