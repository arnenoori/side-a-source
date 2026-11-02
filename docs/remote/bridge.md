# Side A Remote: bridge changes

What `bridge/sessions.py` and `bridge/sidea_bridge.py` need for Remote: transcripts with stable
positions and cursors, tool results with diffs, an index of every image in every transcript, and
Codex sessions in `live`. The wire types they feed are in [protocol](protocol.md); the server that
calls them is in [mac-server](mac-server.md). The plan is [remote.md](../remote.md), sections
"Transcripts and images" and "Codex".

Status: spec, October 2026. Line numbers are as of `b6748e1`.

The bridge stays stdlib-only. It never puts image bytes on its stdout: it says where they are, and
the app reads them.

## What the bridge does today

| Piece | Where | What it does now | Why Remote can't use it as is |
| --- | --- | --- | --- |
| `SKIP` | `sessions.py:37-38` | Byte markers checked before `json.loads` | `read_messages` uses `SKIP[:2]` (`:666`), so every line with `"toolUseResult"` is dropped unparsed: every tool result, every Read image, every diff |
| `text_of` | `:95-98` | Joins `text`, `input_text`, `output_text` blocks | Image blocks disappear; a pasted image is left as the literal `[Image #1]` |
| `read_messages` | `:650-714` | One message per prompt, reply, compaction; consecutive tool calls merge into one `tool` message of summary strings | No results, no status, text cut at 6,000 (`:658`), subagents skipped (`:691`), queued prompts (`attachment` lines) skipped |
| `update_view` | `:573-611` | Caches `read_messages` output in `views(session, seq, uuids, data)`; appends from the stored offset, re-reading the last row because a tool call can merge into it (`:587-595`) | `seq` is already dense and append-only, which protocol wants, but nothing records *which* rows changed, and a rebuild (`:596-598`) is silent |
| `show` | `:614-647` | Newest `limit` messages, or a page around a uuid | No `after`/`before`, no one-message fetch |
| `live` | `:870-904` | Claude Code's registry (`~/.claude/sessions/*.json`) plus `health` | No Codex, no hosted flag |
| `serve_sessions` | `sidea_bridge.py:1792-1810` | One JSON request per stdin line, one reply per stdout line | Fine; new actions plug in through `run_sessions` (`:1776-1789`) and the argparse block (`:1838-1851`) |

The Mac's `SessionBridge` decodes today's replies with `.convertFromSnakeCase`
(`Sources/SideA/SessionBridge.swift`). The new `--format remote` output is a **bridge DTO, not a
wire type**: it keeps `ts` and raw tool `input`, and snake_case conversion would turn
`session_id` into `sessionId`, not protocol's `sessionID`. The Swift side decodes it with explicit
`CodingKeys` and adapts it to protocol's types in `Wire+Builders` (protocol, Twins).

## What the transcripts hold

Checked read-only against the newest 250 Claude transcripts and 500 Codex rollouts on this Mac.
Only structure was read: key names, types, lengths.

### Claude Code

- **Tool images.** A `user` line whose `message.content` holds
  `{"type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":…,"media_type":…}}]}`.
  Read results (2,127 of 2,448 tool images sampled) repeat the same bytes in
  `toolUseResult.file.base64` with `dimensions`. MCP results (claude-in-chrome, Mobbin, Docs: 321)
  repeat them in `toolUseResult`, which is then a list of `{type:"image"|"text"}`. Media types seen:
  `image/png`, `image/jpeg`, `image/webp`.
- **Pasted images.** `{"type":"image","source":{"type":"base64","media_type":…,"data":…}}`
  directly in a user `message.content`, next to text blocks. Note the key order: `media_type` comes
  before `data` here and after it in tool results.
- **Queued prompts.** A prompt typed while Claude works is an `attachment` line,
  `attachment.type == "queued_command"`, with `prompt` as a string or a content list that can hold
  image blocks. In the sample, 29 of 32 queued images appear nowhere else in the transcript.
  These lines are in `SKIP` today, so neither the text nor the images reach the viewer.
- **`api-request-blob` lines** repeat whole requests (up to 3 MB a line) with every image again.
  Never index them. They aren't in `SKIP` today, so `index_claude` parses them only to drop them at
  the `kind` check (`:223`): adding them to `SKIP` is also a speed fix.
- **The base64 is verbatim in the line.** Neither writer escapes `/`, so the bytes between the
  quotes are the base64 text exactly. A raw byte scan (regex below) found the same spans, in the
  same order, as parsing for all 2,533 image lines sampled, provided it stops at the
  `"toolUseResult"` key. In every line seen, `message` comes before `toolUseResult`.
- **Edit and Write.** `toolUseResult` carries `filePath`, `structuredPatch`
  (`[{oldStart, oldLines, newStart, newLines, lines: [" …", "-…", "+…"]}]`), `oldString`,
  `newString` for Edit, and **`originalFile`, the whole file**, for both. Write is
  `{type:"create", content, structuredPatch: []}` for a new file and `{type:"update", …,
  structuredPatch: [hunks]}` for an overwrite.
- **Subagents.** `Agent` tool_use input `{description, prompt, subagent_type}`; its result's
  `toolUseResult` has `agentId`, `status` (`async_launched` for background agents), `description`,
  `resolvedModel`, `outputFile`. The subagent's own transcript is
  `<project>/<session>/subagents/agent-<agentId>.jsonl`, beside `agent-<agentId>.meta.json`
  `{agentType, description, toolUseId, spawnDepth, model, …}`. `toolUseId` links it to the call.
- **Plans and todos.** `ExitPlanMode` input `{plan, planFilePath}`; `AskUserQuestion` input
  `{questions}`. No `TodoWrite` or `TaskCreate` call appeared in the newest 120 transcripts; older
  Claude Code wrote `TodoWrite` input `{todos: [{content, status, activeForm}]}` and
  `toolUseResult {oldTodos, newTodos}`. Handle all three, test with synthetic lines.

### Codex

- **Event types** in current rollouts: `session_meta`, `turn_context`, `world_state`,
  `response_item` (`message`, `reasoning`, `custom_tool_call`, `custom_tool_call_output`,
  `function_call`, `function_call_output`), `event_msg` (`task_started`, `task_complete`,
  `turn_aborted`, `item_completed`, `user_message`, `token_count`, `thread_settings_applied`),
  `token_usage_record`, `compacted`.
- **Tool calls.** Codex 0.156 runs most work through one `custom_tool_call` named `exec` whose
  `input` is code; the commands it runs arrive as `event_msg` `item_completed` items:
  `CommandExecution {command, cwd, exit_code, aggregated_output, duration, status}`,
  `FileChange`, `McpToolCall {server, tool, arguments, result, status}`, `ImageView {path}`,
  `Extension {kind: "image_gen.generation", result, savedPath}`, plus `AgentMessage`,
  `Reasoning`, `UserMessage`. Each item has `turn_id`, no `call_id`.
- **File changes.** `FileChange.changes` is an object keyed by absolute path:
  `{type: "update", unified_diff, move_path}` or `{type: "add", content}` (one `add` held 251 KB).
- **Images.** `input_image` blocks with `image_url` = `data:image/png;base64,…` (also jpeg, webp)
  in `custom_tool_call_output.output` and `function_call_output.output` (screenshots) and in user
  `message.content` (pasted). The data URL is verbatim in the line (1,110 of 1,110). Pasted
  images also show up as `UserMessage` items with `{type: "local_image", path}`, a copy under a
  temporary folder. `ImageView` points at a file on disk. `Extension` image generation carries the
  whole image inline in `result` (2.7 MB in one line) and its `savedPath`.
- **Turns.** `task_started {turn_id, started_at}`, `task_complete {turn_id, completed_at,
  last_agent_message, error?}`, `turn_aborted {turn_id, reason}`.
- **No approval events.** Not one `exec_approval_request` or `apply_patch_approval_request` in
  500 rollouts: approvals are not persisted. A pending Codex approval is only visible through the
  `PermissionRequest` hook, which the island already receives.
- **Subagents.** A subagent thread has its own rollout whose `session_meta` has
  `parent_thread_id` and `source: {subagent: …}`. `index_codex` marks these `automated`
  (`:306-307`), so they never list.
- **Open files.** A running `codex` process keeps its rollout open; `lsof` showed one to five open
  rollouts per process (the extra ones are its subagents' threads).

## Transcript pages

### Shape

`show` gains a second output format, `--format remote`: a DTO with the content of protocol's
`TranscriptPage` (snake_case, `ts` for `at`, raw `input` instead of a parsed `action`), which the
app adapts. The default format stays what the Mac's `SessionDetail` decodes today, so
`SessionViewer` doesn't change.

Both formats come from one cache. The rows stay one per displayed message, as now, so `seq` keeps
its meaning: dense, 0-based, the row index within a generation. What changes is what a row holds.

```json
{
  "seq": 812, "uuid": "1f0c…", "role": "tools", "ts": 1791560012.4, "model": null,
  "inherited": false, "text": null, "text_truncated": false, "images": [],
  "tools": [{
    "id": "toolu_01…", "name": "Edit", "summary": "Edit: /code/app/Island.swift",
    "input": {"file_path": "/code/app/Island.swift", "old_string": "…", "new_string": "…"},
    "status": "ok", "started_at": 1791560010.1, "ended_at": 1791560012.4,
    "output": "The file … has been updated.", "output_truncated": false,
    "diffs": [{"path": "/code/app/Island.swift", "old_path": null, "change": "modified",
               "additions": 3, "deletions": 1, "truncated": false,
               "hunks": [{"old_start": 40, "old_count": 6, "new_start": 40, "new_count": 8,
                          "lines": [" let a = 1", "-let b = 2", "+let b = 3", "+let c = 4"]}]}],
    "images": [], "subagent": null, "agent_id": null, "todos": null, "plan": null,
    "group": false, "parent": null
  }]
}
```

- `role`: `user`, `assistant`, `tools`, `thinking` (Claude thinking blocks and Codex reasoning
  summaries, with `duration_ms`), `compact`, `error`. The default format keeps `tool` and
  turns `tools` into today's `[String]` of summaries at read time, so the stored row is the same.
- `text` is cut at 6,000 characters with `text_truncated: true` (protocol's limit).
- `tools[].input` is the raw tool input with every string cut at 64 KiB, for the app's
  `IslandAction` parse. For Codex `exec`, `{"code": …}`; for `CommandExecution`, `{"command": …,
  "cwd": …}`.
- `tools[].status`: `running` (no result yet), `ok`, `failed` (`is_error`, non-zero `exit_code`,
  `status: "failed"`), `denied` (Claude's result text starts with the permission-denied sentence,
  or the tool_result is the user-rejected marker).
- `tools[].output`: the result text, at most 4,000 characters. Over that, the first 3,000 and the
  last 900 joined by `\n…\n`, with `output_truncated: true`. Image blocks are not text; they go to
  `images`.
- `agent_id`, `todos` (`[{text, status: pending|in_progress|completed, active_form?}]`, adapted to
  `TranscriptTodo`), `plan`, `group` and `parent` map to protocol's `TranscriptTool` fields of the
  same meaning. `parent` is set on a Codex child command to its `exec` call's id, so the phone
  groups children under the right exec when several execs share a row.
- **Size.** Each tool is squeezed under 96 KiB encoded (strings in `input` cut, `output` cut as
  above, diff hunks cut with `truncated`), and a run of tool calls starts a new `tools` row every 8
  tools, so one row stays under about 800 KB (protocol, Size bounds). `message` has everything.

`ImageRef` as protocol has it: `{id, mime, bytes, width, height, source, name}`, `id` the
lowercase hex SHA-1 of the image bytes. `source`: `read`, `mcp`, `pasted`, `screenshot` (Codex tool
output), `view` (Codex `ImageView` / `local_image`), `other` (image generation, anything else).
Rows never hold base64.

### Stable seq, revisions and generations

The cache table gets two columns and its state table four:

```sql
CREATE TABLE IF NOT EXISTS views(session TEXT, seq INTEGER, uuids TEXT, data TEXT, rev INTEGER,
    PRIMARY KEY(session, seq)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS views_rev ON views(session, rev);
CREATE TABLE IF NOT EXISTS view_state(session TEXT PRIMARY KEY, path TEXT, offset INTEGER, head TEXT,
    count INTEGER, used REAL, generation TEXT, rev INTEGER, calls TEXT, agent_id TEXT);
```

- `rev` is a per-session counter. Every row written or rewritten by `update_view` gets the next
  value. A row only changes after it is written when a tool call merges into it or a tool result
  lands on it.
- `calls` (JSON) maps each tool call still `running` to the `seq` of its row, so a result that
  arrives after other rows (a background Bash, a queued prompt in between) updates the right row.
  Entries leave when their result arrives; the map is capped at 200, oldest dropped.
- `generation` is `secrets.token_hex(6)`, made new whenever `update_view` rebuilds from offset 0
  (head changed, file shrank, path changed). Nothing else changes it.
- `update_view` returns `(count, changed)` where `changed` lists the seqs below the previous
  `count` that it rewrote. `show --format remote` passes them out as `replaced`, and the server turns
  them into `transcript.replace` events.

### Cursors

Cursors are opaque strings to the app and the phone; nothing outside the bridge parses or builds
one. The bridge writes them as `<generation>.<seq>.<rev>`, and the server passes them through
unchanged in pages, `transcript.*` deltas and subscriptions.

| Arguments | Returns |
| --- | --- |
| none | The newest `limit` rows |
| `--before C` | Rows with seq < C.seq, the newest `limit` of them, ascending |
| `--after C` | Rows with seq > C.seq, ascending, at most `limit`; plus every row with seq ≤ C.seq and rev > C.rev in `replaced` |
| `--around UUID` | As now (`:625-632`): a page with the hit 40 rows in |
| `--before` and `--after` | Error `Use one cursor` |

A cursor from another generation is not an error inside the bridge: the reply has
`"reset": true` and the newest page, which the server passes on as a 200 page with `reset: true`.
`limit` defaults to 4000 in the default format (today's) and to 50, at most 200, in `remote`.

```json
{
  "session_id": "8c1d…", "generation": "a41f09c2e7b3",
  "messages": [ … ], "replaced": [ … ],
  "before": "a41f09c2e7b3.762.0", "after": "a41f09c2e7b3.812.1907",
  "has_more_after": false, "count": 813, "inherited_before": 0, "reset": false
}
```

`before` is null at the start of the conversation. `after` carries the session's current `rev`,
so a client that follows `after` sees each change once: `--after C` returns the rows past it and,
in `replaced`, every row at or before `C.seq` with a higher `rev` than `C.rev`. `replaced`,
`reset` and `agent_id` (set when paging a subagent with `--agent-id`) are protocol's
`TranscriptPage` fields; the server forwards `replaced` as REST `replaced` and as
`transcript.replace` on the stream.

### One message in full

`sessions message <session> --seq N --generation G` returns the row with nothing cut: text whole,
tool `output` up to 1 MiB, every diff hunk, and Write's whole new file as an `added` diff (up to
1 MiB, then `truncated`). It re-reads the source lines rather than storing them twice: each tool
keeps `src: [offset, length]` of its call line and result line in the row (stripped from both
output formats). Each source line is read with one `seek` and parsed with image spans blanked
(below). If the line at that offset no longer has the expected uuid or call id, the reply is
`{"error": "changed"}` and the server answers 410.

### `read_messages` rewrite

`read_messages(path, agent, offset, messages)` keeps its signature and its caller in
`update_view`, and gains `calls` (the open-call map) in and out.

1. **Line filter** (`:666`). Drop `SKIP[:2]`. New filter: skip `api-request-blob`,
   `queue-operation`, `file-history-*`, `atis-latch`, `permission-mode`, `mode`, `last-prompt`,
   and `attachment` unless the line has `"queued_command"`.
2. **Blank image spans before parsing.** A line with `"type":"base64"` or `data:image/` has its
   base64 spans replaced by empty strings (offsets kept, see Image index) and `toolUseResult`
   `file.base64` likewise, then `json.loads`. Measured on this Mac: the largest transcript
   (399 MB, 36,381 lines) parses whole in 0.96 s this way.
3. **`toolUseResult` is parsed but trimmed** before anything is kept: drop `originalFile`, `content`
   over 1 MiB, `file.base64`, `stdout`/`stderr` over 64 KiB.
4. **Claude user lines with `tool_result` blocks** look up `tool_use_id` in `calls`, set `status`,
   `ended_at`, `output`, `images` (from the image index for this line), and from `toolUseResult`:
   `diffs`, `todos`, `agent_id`. The row is rewritten and marked changed.
5. **Claude assistant `tool_use` blocks** add a tool to the last `tools` row or open one, as `add()`
   does today (`:652-657`), and enter `calls`. `Agent`/`Task` set `subagent` to the description;
   `ExitPlanMode` sets `plan`; `TodoWrite` and `TaskCreate`/`TaskUpdate` set `todos`.
6. **User text** goes through `text_of` and `prompt_text` as now. `text_of` gains an `images` out
   parameter (the `ImageRef`s of this line, in order); the literal `[Image #N]` markers stay in the
   text, because Claude Code writes them and they say where the image sat.
7. **Queued prompts** (`attachment.type == "queued_command"`) become `user` rows. `prompt` as a
   string or a content list, its images from the index. Their `uuid` is the attachment line's.
8. **Codex** (`:673-686`) adds:
   - `item_completed` `CommandExecution`, `McpToolCall`, `FileChange`, `ImageView`, `Extension`
     become tools with their own `id`, already finished (`status` from `exit_code`/`status`).
   - An `exec` `custom_tool_call` is a tool too; `item_completed` items of the same `turn_id` that
     follow it before its `custom_tool_call_output` attach to its row. When it has children, its
     own entry is marked `"group": true` and the phone folds it.
   - `function_call` `update_plan` sets `todos` from `{plan: [{step, status}]}`.
   - `*_call_output` with `input_image` blocks adds their images to that call.
   - `task_complete` with `error` adds an `error` row with `error.message`.
   - `compacted` adds a `compact` row.
9. **Subagent markers.** Rows from a subagent's own file are never mixed in. An `Agent` tool row
   carries `subagent` and, once the result says it, `agent_id`; `show <session> --agent-id <agentId>`
   opens `subagents/agent-<agentId>.jsonl` through the same cache, keyed `<session>/<agentId>`.
   Codex: `--agent-id <threadId>` opens the child rollout found by `parent_thread_id`.

### Diffs

`diff_of(tool_input, tool_use_result)` for Claude, `codex_diffs(changes)` for Codex, both
returning protocol's `FileDiff` list. Every diff stops at 2,000 lines in the page (`truncated`),
whole in `message`.

| Source | `change` | Hunks |
| --- | --- | --- |
| Claude `structuredPatch` non-empty | `modified` | Copied: `oldStart→old_start`, `oldLines→old_count`, … `lines` as is |
| Write `type: "create"` | `added` | One hunk `0,0 → 1,N` of `"+"` lines from `content` |
| No `toolUseResult` (rejected call, older Claude Code) | `modified` | Edit: one hunk from `old_string`/`new_string` with `old_start = new_start = 0` (unknown); MultiEdit: one per edit |
| Codex `type: "update"` | `modified`, or `renamed` with `old_path` when `move_path` | Parse `unified_diff`: `@@ -a,b +c,d @@` headers, lines kept with their prefix, `\ No newline` kept |
| Codex `type: "add"` | `added` | From `content`, as Write |
| Codex `type: "delete"` | `deleted` | Empty, `deletions` from the old content if present |

`additions` and `deletions` count `+` and `-` lines across all hunks, before the cut.

## Image index

### Schema

```sql
CREATE TABLE IF NOT EXISTS images(
    id TEXT NOT NULL,          -- sha1 hex of the decoded bytes
    session TEXT NOT NULL,     -- Claude session id or Codex thread id; subagents under the parent
    agent_id TEXT,             -- subagent id when it came from a subagent file or thread
    path TEXT NOT NULL,        -- the transcript that holds it
    line_offset INTEGER NOT NULL, line_length INTEGER NOT NULL,
    block INTEGER NOT NULL,    -- order of the image within its line
    data_offset INTEGER,       -- absolute file offset of the first base64 character; NULL for file images
    data_length INTEGER,       -- base64 characters
    file TEXT,                 -- Codex ImageView / local_image / savedPath
    uuid TEXT, call_id TEXT, tool TEXT,
    source TEXT, mime TEXT, bytes INTEGER, width INTEGER, height INTEGER,
    ts REAL, inherited INTEGER DEFAULT 0,
    PRIMARY KEY(path, line_offset, block)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS images_id ON images(id);
CREATE INDEX IF NOT EXISTS images_session ON images(session, ts);
```

One row per occurrence, so a transcript row can name its images; the `id` dedupes the bytes and
the thumbnail. Copies in a fork's history get rows of their own with `inherited = 1` and the same
`id`. The 3,000 images in the sample would be about 0.6 MB of rows; the whole Mac, low tens of MB.

### Detection

Images are found by the **search indexer**, not the viewer, because the indexer already reads
every new line of every transcript (`index_claude` `:197-201`, `index_codex` `:288-292`). That is
the only way a phone can ask for any image without the Mac first opening that conversation, and it
costs no extra reads.

```python
SPAN = re.compile(rb'"type":"base64","(?:media_type":"([a-z0-9/+.-]+)","data":"|data":")([A-Za-z0-9+/=]*)"(?:,"media_type":"([a-z0-9/+.-]+)")?')
DATA_URL = re.compile(rb'"(?:image_url|result)":"(?:data:(image/[a-z0-9+.-]+);base64,)?([A-Za-z0-9+/=]{256,})"')
```

`line_images(line, line_offset, agent)` returns `[(block, data_offset, data_length, mime)]`:

- **Claude:** if `b'"type":"base64"'` in the line and the line isn't `api-request-blob`, run `SPAN`
  over `line[:line.find(b'"toolUseResult"')]` (the whole line when absent). That leaves out the
  Read duplicate in `toolUseResult.file.base64` and the MCP duplicate list. Then parse the line
  with spans blanked and count image blocks in `message.content` (pasted, and inside each
  `tool_result`) or `attachment.prompt`. If the counts differ, store the rows with `data_offset`
  NULL ("parse mode": serving parses the line and takes block N) and log nothing; it hasn't
  happened in the sample.
- **Codex:** if `b'data:image/'` in the line (`response_item` messages and `*_call_output`), or
  `b'"image_gen.generation"'` (inline `result`), run `DATA_URL`. If `b'"ImageView"'`,
  `b'"local_image"'` or a non-empty `savedPath`, record a file image.
- **Metadata:** `uuid`, `call_id` (`tool_use_id`, Codex `call_id`), `tool` (the call's name, from
  a per-file map of recent `tool_use` ids kept in `state`), `source` (`Read` → `read`, `mcp__*` →
  `mcp`, user content or queued → `pasted`, Codex output → `screenshot`, `ImageView`/`local_image`
  → `view`, image generation → `other`), `ts`, `inherited` (`forkedFrom`).
- **Decode once, at index time.** `base64.b64decode` the span, `hashlib.sha1` it, read
  width and height from the header (PNG IHDR, JPEG SOFn, GIF, WebP VP8/VP8L/VP8X: a 30-line
  `image_size(data)`), keep `bytes`. Measured: scanning, decoding and hashing every image in the
  largest transcript (606 images) took 0.41 s of a 0.86 s pass, about 460 MB/s overall.
- **Codex `local_image`** is skipped when the same turn's user `message` already carried as many
  `input_image` blocks: the embedded copy outlives the temporary file. `ImageView` and `savedPath`
  files are hashed at index time if they exist, are under 50 MB and start with an image signature;
  otherwise the row is kept with `bytes` NULL and `id = sha1("missing:" + path)`, and the phone
  shows "No longer on disk".

Edit points:

- `SKIP` (`:37-38`): add `b'"type":"api-request-blob"'`. Keep `"type":"attachment"` there for the
  search index, but `index_claude` checks images **before** the `SKIP` test at `:201`, because Read
  results carry `"toolUseResult"` and queued images sit in `attachment` lines.
- `index_claude` `:201`: `if b'"type":"base64"' in line: images.extend(line_images(...))` using
  the offset before `offset += len(line)` (`:200`). Queued-prompt text also goes into the search
  index (role `user`).
- `index_codex` `:292`: widen the marker test to the Codex markers above; image lines that aren't
  `session_meta`/`response_item`/`turn_context` go to `line_images` and nowhere else.
- `add_images(db, rows)` beside `add_rows` (`:70-73`), called where `add_rows` is (`:274`, `:340`).
- `delete_rows` (`:76-82`): when `role` is None, also `DELETE FROM images WHERE session=?`.
- `_index` (`:386-391`): a gone file also runs `DELETE FROM images WHERE path=?`; a file restarted
  from offset 0 (`:401-403`) deletes its images first.

### Serving by offset

`sessions image <id>` returns a locator. The app reads the bytes; the bridge never sends them.

```json
{"id": "3f2a…", "mime": "image/png", "bytes": 140222, "width": 1280, "height": 800,
 "source": "read", "kind": "inline",
 "path": "/Users/…/.claude/projects/…/8c1d….jsonl", "data_offset": 10482211, "data_length": 186964}
```

`kind` is `inline` (seek, read `data_length`, base64-decode), `line` (parse mode: also
`line_offset`, `line_length`, `block`) or `file` (`file` path). The bridge picks the newest row for
that id whose transcript still exists and whose size is past the span. In Swift
(`RemoteServer`, see mac-server): one `FileHandle` seek and read, `Data(base64Encoded:)`, check the
SHA-1 (CryptoKit `Insecure.SHA1`) matches the id, then send with `ETag: <id>`. A mismatch means the
file was rewritten: the server asks `sessions image <id> --recheck`, which re-scans that line, fixes
or deletes the rows, and returns the next locator or `{"error": "gone"}` (404). A `file` image is
served only if its first bytes are a PNG, JPEG, GIF, WebP or HEIC signature, so a transcript can't
point the server at any other file.

### Thumbnails

**Recommendation: ImageIO in the app, not `sips`.** The server already holds the bytes in memory
after the seek. `CGImageSourceCreateThumbnailAtIndex` with
`kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceThumbnailMaxPixelSize = 320` and
`kCGImageSourceCreateThumbnailWithTransform`, then a `CGImageDestination` JPEG at quality 0.7,
takes a few milliseconds and reads WebP and HEIC. `sips` would need the full image written to a
temporary file first (remote.md: the transcript is the only copy, and nothing else is written),
plus a process per thumbnail (tens of milliseconds each, a whole page of them at once).

- Cache: `runtime/thumbs/<id>.jpg`, 0600, folder 0700, written atomically by the app.
- **Eviction by the bridge**, at the end of `_index` beside the `views` trim (`:423-429`), at most
  once an hour (timestamp in `runtime/thumbs/.swept`): delete thumbnails whose id has no row in
  `images`, then, oldest modification time first, until the folder is under 200 MB. The app
  touches a thumbnail's mtime when it serves it, so mtime is last use.

## `live_codex`

`live_codex(root, memory, children, started, ports, parents)` returns rows in the same shape as
Claude's, and `live` (`:870-904`) appends them before sorting.

1. **Find the processes.** `process_tree` (`:799-819`) adds `args=` as the last `ps` column
   (`ps -axo pid=,ppid=,rss=,lstart=,args=`; split with `split(None, 8)`, since `lstart` is five
   fields) and returns `args` and `parents` too. A Codex session is a process whose `argv[0]`
   basename is `codex` and whose first argument isn't `app-server`, `exec`, `login`, `logout`,
   `mcp`, `mcp-server` or `completion`. `codex-code-mode-host` children are its, not sessions.
   Side A's own priming runs `app-server`, so it's left out by that rule.
2. **Map each to its rollout.** One call for all of them:
   `lsof -nP -p <pid,pid,…> -Fpn` (5 s timeout), keeping names that match
   `*/sessions/**/rollout-*.jsonl`. A process with several open is the parent of its subagents:
   read each one's first line (`session_meta`) and keep the one without `parent_thread_id` as the
   session; the others give `subagents: N`. A process with none open (between turns on some
   versions): the newest rollout under the Codex homes (below) whose `session_meta.cwd` equals the
   process's cwd (`lsof -a -d cwd`, same call) and that was modified after the process started.

**Codex homes.** Side A's Codex profiles symlink `sessions`, `archived_sessions` and
`thread-writer-locks` to one shared `<root>/codex-conversations/` (`codex_bridge.prepare_profile`,
`bridge/codex_bridge.py:96-109`), and the Mac's own login uses `~/.codex`. `codex_files`
(`sessions.py:131-133`) indexes every home (`~/.codex` and each profile's), **deduplicated by
`realpath`**, so profile rollouts are searchable, image-indexed and openable with `show`, and the
shared folder is read once however many profiles point at it. Setup diagnostics check Codex hooks
per account home, not only `~/.codex/hooks.json` (`setup.py:211`).
3. **Status from the rollout tail.** Read the last 256 KB (`TAIL`, `:719`); if no turn event is in
   it, the last 4 MB.
   - Last turn event `task_started` with no later `task_complete`/`turn_aborted` for its `turn_id`:
     `busy`, `since = started_at`.
   - Last turn event `task_complete` or `turn_aborted`: `idle`, `since` = its `completed_at`.
   - **No turn event in the bounded tail** (a working turn wrote more than 4 MB since it started):
     `unknown`, never `idle`. `unknown` authorizes nothing (protocol, `SessionStatus`): no Continue
     on phone (which would kill a working process), no interrupt, no `auto` typing.
   - `busy` with an open `request_user_input*` `function_call` (no output with its `call_id` yet):
     `waiting`, `waitingFor: "question"`.
   - Pending approvals are not in the rollout. The bridge sets `pending_call: {name, since}` when
     the last tool call has no output yet and the latest `turn_context.approval_policy` isn't
     `never`; the app shows `waiting`/`permission` only when the island holds a Codex request for
     that pid, which it already knows.
4. **`codex_health(path, status, now)`** mirrors `health` (`:744-796`) on Codex items: `activity`
   from the last `CommandExecution` command (through `activity("Bash", …)`), the `exec` call, an
   `McpToolCall` tool name or "Writing a reply"; `context` from the last `token_count`
   `info.last_token_usage` (input plus cached); the same `stuck`, `loop` (same command 3 times in
   the last 6), `failing` (4 non-zero exits in a row) and `bloated` flags.

```json
{"agent": "codex", "pid": 34105, "id": "0199…", "name": null, "title": "Flaky upload",
 "cost": null, "cwd": "/code/api", "status": "busy", "waitingFor": null, "since": 1791560000.0,
 "kind": null, "activity": "Running pytest -k upload", "context": 48210, "flag": null,
 "memory": 412, "processes": 3, "ports": [], "started": 1791559000, "model": "gpt-5.5",
 "subagents": 1, "pending_call": null, "hosted": null}
```

Claude rows gain `"agent": "claude"`, `"hosted"` and nothing else. Keys keep today's mixed case
(`waitingFor`) so `LiveSession` still decodes; new keys are optional in Swift.

**`hosted`.** One `tmux -L sidea list-panes -a -F '#{pane_pid}\t#{session_name}'` per `live`
call (1 s timeout; no server running means nothing is hosted). A session is hosted when one of its
ancestors, walked up through `parents`, is a pane's pid; `hosted` is that tmux session name, else
null. The app also reads `SIDE_A_HOSTED` from the hook message and the process environment
(mac-server, "Codex hold for hosted sessions"); the two agree by construction, and `live` is the
one the session list uses.

Accounts per session stay in Swift (mac-server, "Accounts per session").

## Commands

All under `sessions`, all answered by `serve` (`sidea_bridge.py:1792`), all JSON with snake_case
keys except the existing `live` keys.

| Command | Arguments | Result |
| --- | --- | --- |
| `show <id>` | `--limit`, `--around`, as now | Today's `SessionDetail` shape, unchanged |
| `show <id> --format remote` | `--limit` (50, ≤ 200), `--before C` or `--after C`, `--around UUID`, `--agent-id A` | `TranscriptPage` plus `replaced`, `reset` |
| `message <id>` | `--seq N --generation G`, `--agent-id A` | One `TranscriptMessage`, uncut |
| `image <sha1>` | `--recheck` | Locator, or `{"error": "gone"}` |
| `images <id>` | `--limit` (200), `--before TS` | `{"images": [ImageRef + seq, uuid, ts]}` newest first, for a gallery |
| `live` | | As now, plus Codex rows, `agent`, `hosted` |

Argparse (`:1838-1851`): add `message`, `image`, `images` to `choices`; add `--format`
(`default`/`remote`), `--before`, `--after`, `--seq` (int), `--generation`, `--agent-id` (named so
it doesn't clash with `--agent`, the existing claude/codex filter), `--recheck`.
`run_sessions` (`:1776-1789`) dispatches them. `serve` keeps refusing `index` and `serve`
(`:1800`).

The server runs its own `serve` process (`remoteReader`, mac-server), so a phone paging back
through a 400 MB transcript never holds up the Mac's `live` poll, which runs every second.
SQLite in WAL mode lets the processes read together; `update_view` takes `BEGIN IMMEDIATE`, so
two of them opening the same conversation queue for the write, not corrupt it.

## Performance

Each side holds about 11 GB of transcripts on this Mac. Nothing is read twice, nothing is read
whole except on first open, and nothing scans all 22 GB in the foreground.

| Path | Budget | How |
| --- | --- | --- |
| Index pass, new lines | Within today's time plus 5% | One more `in` test per line; decode and hash only image lines |
| Image backfill after upgrade | Background, in the indexer's existing 20 s slices, newest first | ~460 MB/s measured warm, so roughly a minute of CPU for 22 GB, more on a cold disk |
| `show --format remote`, cached, nothing new | < 30 ms for 50 rows | One indexed range read |
| `show` after a few appended lines | < 50 ms | Reads from the stored offset; rewrites only touched rows |
| First open, 400 MB transcript | < 1.5 s (0.96 s measured) | Spans blanked before parsing, `originalFile` dropped |
| First open, typical (< 20 MB) | < 100 ms | |
| `message` | < 20 ms | One or two seeks, one parse with spans blanked |
| `image` locator | < 2 ms | `images_id` index |
| `live` with Codex | < 400 ms for 10 sessions | One `ps`, one `lsof` for listening ports (today), one `lsof` for Codex pids, one `tmux`, a 256 KB tail each |

The cache stays bounded as now: `views` for the 300 most recently used conversations (`:423-424`).
Rows grow with tool output (4,000 characters each at most), so expect the cache to be two to three
times today's size.

## Migration

`connect` (`:41-52`) drops every table when `user_version` isn't 3 or 4. Version 5 must not do
that: dropping `files` would reindex 22 GB.

- `VERSION = 5` (`:34`). `connect` accepts 3, 4 and 5 and drops nothing for them; anything else is
  rebuilt as today.
- `upgrade` (`:55-60`) runs 3 → 4 as now, then 4 → 5: `DROP TABLE views; DROP TABLE view_state;`
  (a cache; the next `show` rebuilds a conversation in under a second and the indexer's warm-up at
  `:416-422` refills the newest 20), recreate both with the new columns, create `images`, set
  `user_version = 5`, commit. `sources` (`:63-67`) tests `>= 4` instead of `== VERSION`.
- **Image backfill.** Each file's `state` JSON (the `files.state` column, already per file) gains
  `"img"`, the offset images are indexed to. New files index images inline and keep
  `img == offset`. After the main loop in `_index`, while time is left:
  `SELECT path, offset, state FROM files ORDER BY mtime DESC`, and for each whose `img` is missing
  or below `offset`, scan only image lines from `img` to `offset` (`line_images`, no search rows),
  then save `img`. `index` returns `"images_remaining"` so the app knows to call again, as it does
  for `remaining`.
- The default `show` output doesn't change, so the Mac app needs no release in step with the
  bridge. The bridge ships inside the app anyway.

## Tests

New file `bridge/tests/test_remote.py`, built like `test_sessions.py` (temp home, `Path.home`
patched, synthetic `user`/`reply` helpers). No real transcript content anywhere: images are made
in the test.

```python
def png(width, height, seed=0):
    raw = b''.join(b'\x00' + bytes([seed % 256] * 3 * width) for _ in range(height))
    chunk = lambda kind, data: struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + \
           chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
```

| Test | Checks |
| --- | --- |
| `test_pages_have_stable_seq_and_cursors` | 120 rows; `--before` walks back to `before: null`; appending lines and calling `--after` returns only new rows, old seqs unchanged |
| `test_a_result_rewrites_its_row_and_bumps_rev` | Call, then a user row, then the result: the call's row comes back in `replaced`, the user row doesn't |
| `test_a_rewritten_transcript_gets_a_new_generation` | Rewrite in place: the old cursor gives `reset: true` and the new page |
| `test_default_show_is_unchanged` | Default format has `role: "tool"` and string `tools`; the existing `test_sessions.py` cases pass untouched |
| `test_tool_results_are_kept_and_cut` | 10,000-line Bash output: head and tail kept, `output_truncated`; `is_error` gives `failed`; `message` returns it whole |
| `test_edit_diff_from_structured_patch` | Hunks copied with line numbers; counts right; `originalFile` never in a row |
| `test_edit_diff_without_tool_use_result` | Rejected Edit falls back to `old_string`/`new_string`; MultiEdit gives one hunk per edit |
| `test_write_create_is_an_added_file` | `type: "create"` gives `added`; 3,000 lines gives `truncated` in the page, whole in `message` |
| `test_codex_file_change_diffs` | `update` parsed from `unified_diff`; `add` from `content`; `move_path` gives `renamed` |
| `test_codex_exec_groups_its_commands` | `exec` call with two `CommandExecution` items: one row, `group: true`, children carry `parent`, exit codes as status |
| `test_tool_rows_split_and_stay_bounded` | 20 consecutive tool calls make three rows (8, 8, 4); a tool with 1 MB of input and output encodes under 96 KiB with `truncated` set |
| `test_codex_profiles_are_indexed_once` | Two profiles symlinking the same shared `sessions`, plus `~/.codex`: every rollout indexed exactly once |
| `test_todos_and_plans` | `TodoWrite`, `TaskCreate`, `ExitPlanMode`, Codex `update_plan` |
| `test_subagent_marker_and_transcript` | `Agent` call with `agentId` in its result, `subagents/agent-X.jsonl` and `.meta.json`: row has `subagent` and `agent_id`; `--agent-id X` pages the subagent |
| `test_queued_prompt_with_image_is_shown_and_indexed` | `attachment` `queued_command` with text and an image: a `user` row, one image, searchable text |
| `test_images_are_indexed_once_and_never_stored` | Read result with the duplicate in `toolUseResult.file.base64`, a pasted image, an `api-request-blob` repeating both: two rows; ids are the SHA-1s; the base64 text doesn't occur anywhere in `sessions.db` |
| `test_image_locator_points_at_the_bytes` | `seek(data_offset)`, read `data_length`, decode: equals the PNG; width and height right |
| `test_parse_mode_when_key_order_differs` | `toolUseResult` before `message`: rows fall back to `line` locators that still decode |
| `test_fork_copies_share_the_image_id` | Fork copy has its own row, `inherited = 1`, same id |
| `test_codex_images` | `input_image` data URL in a tool output and in a user message; `ImageView` to a temp PNG; a missing file gives `bytes` NULL; `local_image` skipped beside the embedded copy; a non-image file is refused by `image` |
| `test_upgrade_from_4_keeps_the_index_and_backfills_images` | Build a version 4 database, upgrade: search still answers with no reindex (`index_claude` patched to fail); backfill fills `images`; `images_remaining` reaches 0 |
| `test_large_image_lines_are_parsed_blanked` | A 5 MB image line indexes and opens with `json.loads` patched to fail on input over 1 MB |
| `test_live_codex_status` | `process_tree`, `lsof` and the file system patched: `task_started` alone is `busy`; after `task_complete`, `idle`; a 5 MB tail with no turn event is `unknown`; open `request_user_input` is `waiting`; a second open rollout with `parent_thread_id` gives `subagents: 1`; `app-server` and `exec` processes left out |
| `test_hosted_follows_tmux_panes` | Patched `tmux` output and `parents`: a session two levels under a pane is hosted; tmux missing gives null |
| `test_thumbnail_sweep` | Orphan thumbnail deleted; oldest deleted first past the cap; the sweep runs at most once an hour |

`bridge/tests/test_bridge.py` gains one test that drives `serve_sessions` with `message`, `image`
and a bad cursor through stdin and reads the replies.

## Open questions

1. ~~Protocol additions.~~ Settled: `replaced`, `reset` and `agent_id` are on protocol's
   `TranscriptPage`; `agent_id`, `todos`, `plan`, `group` and `parent` on `TranscriptTool`;
   `seq` on `ImageRef` (gallery listings).
2. ~~**Thumbnail size.**~~ Settled: 640 px (was 320 px). A 200-point-wide image on a 3x iPhone wants about
   600 px; 640 px JPEGs would be roughly 50 KB each. Worth deciding before the cache fills.
3. **Thumbnails under `runtime/`.** Agents can read `runtime/`. The images are already in
   transcripts they can read, so nothing new is exposed, but `~/Library/Caches/<bundle id>/thumbs`
   would let macOS purge them under disk pressure.
4. **Codex approvals.** Rollouts don't record them, so `live` alone can't show a Codex session
   waiting for approval. The island has them; is that enough for sessions running with
   `approval_policy: never` turned off and Side A's Codex hooks untrusted?
5. **Subagent completion.** Background agents finish later through a `<task-notification>` user
   line, which `prompt_text` drops (`:110`). Should that line set the `Agent` row's status to `ok`?
   The format of that line wasn't checked here.
6. ~~Codex reasoning summaries.~~ Settled: Claude thinking and Codex `Reasoning.summary_text` are
   emitted as `thinking` rows with `duration_ms` (protocol's `TranscriptRole.thinking`,
   `TranscriptMessage.durationMS`).
7. ~~Codex profiles.~~ Settled: every Codex home is indexed, deduplicated by realpath (Codex homes,
   above).
