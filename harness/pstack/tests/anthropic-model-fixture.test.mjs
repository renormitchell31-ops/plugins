import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { createAnthropicModelFixture } from "./anthropic-model-fixture.mjs";

let directory;
let fixture;

const post = (path, body) =>
  fetch(`${fixture.baseUrl}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": "secret" },
    body: JSON.stringify(body),
  });

const start = async (content) => {
  fixture = await createAnthropicModelFixture({
    directory,
    onRequest: async () => content,
  });
};

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), "anthropic-fixture-"));
});

afterEach(async () => {
  await fixture?.close();
  fixture = undefined;
  await rm(directory, { recursive: true, force: true });
});

const request = {
  model: "claude-test",
  messages: [{ role: "user", content: "hi" }],
  tools: [{ name: "lookup" }],
};

test("returns a non-streaming text message and records the request", async () => {
  await start([{ type: "text", text: "hello" }]);
  const response = await post("/v1/messages", request);
  const json = await response.json();
  assert.equal(json.stop_reason, "end_turn");
  assert.equal(json.model, "claude-test");
  assert.deepEqual(json.content, [{ type: "text", text: "hello" }]);
  assert.deepEqual(fixture.requests, [
    {
      path: "/v1/messages",
      stream: undefined,
      tools: ["lookup"],
      messageRoles: ["user"],
    },
  ]);
  assert.equal(fixture.failure, undefined);
});

test("reports tool_use stop reason", async () => {
  await start([{ type: "tool_use", id: "t1", name: "lookup", input: {} }]);
  const json = await (await post("/v1/messages", request)).json();
  assert.equal(json.stop_reason, "tool_use");
});

test("streams tool input as split input_json_delta events", async () => {
  const input = { query: "abcdef" };
  await start([
    { type: "text", text: "thinking" },
    { type: "tool_use", id: "t1", name: "lookup", input },
  ]);
  const response = await post("/v1/messages", { ...request, stream: true });
  assert.match(response.headers.get("content-type"), /text\/event-stream/u);
  const events = (await response.text())
    .split("\n\n")
    .filter(Boolean)
    .map((chunk) => JSON.parse(chunk.split("data: ")[1]));
  assert.equal(events[0].type, "message_start");
  assert.equal(events.at(-1).type, "message_stop");
  const partials = events
    .filter((e) => e.delta?.type === "input_json_delta")
    .map((e) => e.delta.partial_json);
  assert.equal(partials.length, 2);
  assert.deepEqual(JSON.parse(partials.join("")), input);
  assert(
    events.some((e) => e.delta?.text === "thinking"),
    "text delta emitted",
  );
  assert.equal(
    events.find((e) => e.type === "message_delta").delta.stop_reason,
    "tool_use",
  );
});

test("answers count_tokens probes without invoking onRequest", async () => {
  fixture = await createAnthropicModelFixture({
    directory,
    onRequest: async () => assert.fail("unexpected"),
  });
  const json = await (await post("/v1/messages/count_tokens", request)).json();
  assert.deepEqual(json, { input_tokens: 100 });
  assert.deepEqual(fixture.probes, [
    { path: "/v1/messages/count_tokens", kind: "synthetic-token-count" },
  ]);
  assert.equal(fixture.requests.length, 0);
});

test("returns 404 for unsupported endpoints", async () => {
  await start([]);
  const response = await post("/v1/other", {});
  assert.equal(response.status, 404);
  assert.deepEqual(fixture.probes, [{ path: "/v1/other", status: 404 }]);
});

test("persists incoming bodies without authentication headers", async () => {
  await start([{ type: "text", text: "x" }]);
  await post("/v1/messages", request);
  const files = await readdir(directory);
  assert.deepEqual(files, ["claude-incoming-1.json"]);
  const raw = await readFile(join(directory, files[0]), "utf8");
  assert.deepEqual(JSON.parse(raw).body, request);
  assert(!raw.includes("secret"));
});

test("rejects invalid requests with a 400 and records the failure", async () => {
  await start([]);
  const response = await post("/v1/messages", { model: "m" });
  assert.equal(response.status, 400);
  const json = await response.json();
  assert.equal(json.error.type, "invalid_request_error");
  assert.equal(typeof fixture.failure, "string");
});
