// claude-bridge: OpenAI-compatible shim over the Claude Agent SDK (subscription/OAuth login).
//
// Serves /v1/chat/completions and /v1/models. Every request is a fresh, isolated Agent
// SDK session (no shared state, so requests can run concurrently). By default no tools
// are available: the service behaves like a plain chat model (text only).
//
// Claude authentication comes from the Claude Code login in ~/.claude/.credentials.json
// (the bridge's own home). This is the supported way for the Agent SDK to use a
// subscription, not an imitation of the Anthropic API.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { query } from '@anthropic-ai/claude-agent-sdk';

const PORT = Number(process.env.PORT || 8088);
const HOST = process.env.CLAUDE_OAI_HOST || '127.0.0.1';   // 0.0.0.0 to accept connections from outside
const API_KEY = process.env.CLAUDE_OAI_KEY || '';          // Bearer token LiteLLM authenticates with
const DEFAULT_MODEL = process.env.CLAUDE_MODEL || undefined; // undefined => Claude Code's default model
const MAX_BODY = 2 * 1024 * 1024;

// Fixed system prompt appended to EVERY request (the file wins over the inline value).
// Gives the stateless sessions context (e.g. that this is your lab); it does not and
// cannot switch off the model's safeguards.
const SYSTEM_PROMPT = (() => {
  const f = process.env.CLAUDE_OAI_SYSTEM_PROMPT_FILE;
  if (f) {
    try { return fs.readFileSync(f, 'utf8').trim(); }
    catch (e) { console.error('claude-bridge: cannot read CLAUDE_OAI_SYSTEM_PROMPT_FILE:', e.message); }
  }
  return (process.env.CLAUDE_OAI_SYSTEM_PROMPT || '').trim();
})();

// --- tools (default: NONE, a text-only chat) ---
// CLAUDE_OAI_ALLOWED_TOOLS: comma-separated tools, e.g. "Bash,Read,Edit,Write,Grep,Glob".
//   Empty => no built-in tool is available at all (tools: []).
// CLAUDE_OAI_DISALLOWED_TOOLS: tools to block (wins over the allowed list).
// CLAUDE_OAI_PERMISSION_MODE: default | acceptEdits | bypassPermissions | plan | dontAsk.
//   Executor mode without a human in the loop usually means "bypassPermissions".
const splitList = (v) => (v || '').split(',').map((s) => s.trim()).filter(Boolean);
const ALLOWED_TOOLS = splitList(process.env.CLAUDE_OAI_ALLOWED_TOOLS);
const DISALLOWED_TOOLS = splitList(process.env.CLAUDE_OAI_DISALLOWED_TOOLS);
const PERMISSION_MODE = process.env.CLAUDE_OAI_PERMISSION_MODE || 'default';
const TOOLS_ON = ALLOWED_TOOLS.length > 0;

// --- shared memory (optional) ---
// CLAUDE_OAI_MEMORY_DIR: auto-memory directory (MEMORY.md + *.md notes). When set, the
// MEMORY.md index goes into the system prompt, and the agent (with the Read tool) can
// open the full notes. Read per request, so changes apply without a restart.
const MEMORY_DIR = process.env.CLAUDE_OAI_MEMORY_DIR || '';
function loadMemoryIndex() {
  if (!MEMORY_DIR) return '';
  try {
    const idx = fs.readFileSync(path.join(MEMORY_DIR, 'MEMORY.md'), 'utf8').trim();
    if (!idx) return '';
    return `## Project memory (index)\nThe full notes are in ${MEMORY_DIR}; open them with the Read tool when you need details.\n\n${idx}`;
  } catch { return ''; }
}

if (!API_KEY || API_KEY.length < 16) {
  console.error('claude-bridge: CLAUDE_OAI_KEY must be set (at least 16 characters)');
  process.exit(1);
}

// The Claude Code process (and any Bash it runs in executor mode) gets the environment
// without the bridge's own settings, so the API key cannot be read back through a prompt.
const CHILD_ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('CLAUDE_OAI_')));

const now = () => Math.floor(Date.now() / 1000);
const genId = () => 'chatcmpl-' + crypto.randomBytes(16).toString('hex');
const approxTokens = (s) => Math.ceil((s || '').length / 4); // rough fallback when the SDK reports no usage

function authorized(req) {
  const m = /^Bearer (.+)$/.exec(req.headers.authorization || '');
  if (!m) return false;
  const a = crypto.createHash('sha256').update(m[1]).digest();
  const b = crypto.createHash('sha256').update(API_KEY).digest();
  return crypto.timingSafeEqual(a, b);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(Object.assign(new Error('body too large'), { status: 413 })); req.destroy(); }
      else chunks.push(c);
    });
    req.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch { reject(Object.assign(new Error('invalid JSON'), { status: 400 })); } });
    req.on('error', reject);
  });
}

function send(res, status, body) {
  const data = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(data);
}
const oaiError = (res, status, message, type = 'invalid_request_error') => send(res, status, { error: { message, type } });

// model from the request: only real Claude ids (claude-opus/sonnet/haiku-*) pass through;
// anything else (e.g. the alias "claude-sub") gets Claude Code's default model
const resolveModel = (m) => (typeof m === 'string' && /^claude-(opus|sonnet|haiku)/i.test(m) ? m : DEFAULT_MODEL);

// messages (OpenAI) -> { systemText, promptText }
function buildPrompt(messages) {
  const sys = [];
  const turns = [];
  for (const m of messages || []) {
    const content = Array.isArray(m.content)
      ? m.content.map((p) => (typeof p === 'string' ? p : p.text || '')).join('')
      : String(m.content ?? '');
    if (m.role === 'system') sys.push(content);
    else if (m.role === 'assistant') turns.push(`Assistant: ${content}`);
    else turns.push(`User: ${content}`); // user and anything else
  }
  // A single user turn goes as plain text, without labels.
  const onlyOneUser = turns.length === 1 && turns[0].startsWith('User: ');
  const promptText = onlyOneUser ? turns[0].slice(6) : turns.join('\n\n');
  return { systemText: sys.join('\n\n').trim(), promptText };
}

// Runs one Agent SDK session and returns its event stream.
function runClaude({ promptText, systemText, model, signal }) {
  return query({
    prompt: promptText,
    options: {
      model,
      cwd: process.env.CLAUDE_OAI_CWD || '/tmp',
      env: CHILD_ENV,
      permissionMode: PERMISSION_MODE,
      ...(PERMISSION_MODE === 'bypassPermissions' ? { allowDangerouslySkipPermissions: true } : {}),
      // tools decides what exists; allowedTools only what runs without asking.
      // [] for both = no built-in tool at all (allowedTools: [] alone would not do that).
      tools: ALLOWED_TOOLS,
      allowedTools: ALLOWED_TOOLS,
      ...(DISALLOWED_TOOLS.length ? { disallowedTools: DISALLOWED_TOOLS } : {}),
      settingSources: [],                   // no CLAUDE.md or settings from anywhere
      ...(systemText ? { appendSystemPrompt: systemText } : {}),
      abortController: signal ? { signal } : undefined,
    },
  });
}

async function handleCompletions(req, res) {
  const body = await readJson(req);
  if (!body || typeof body !== 'object') return oaiError(res, 400, 'expected JSON object');
  if (!Array.isArray(body.messages) || body.messages.length === 0) return oaiError(res, 400, 'messages[] required');

  const model = resolveModel(body.model);
  const reportModel = model || 'claude-subscription';
  const { systemText: reqSystem, promptText } = buildPrompt(body.messages);
  // fixed prompt from env + shared memory index + system messages of the request
  const systemText = [SYSTEM_PROMPT, loadMemoryIndex(), reqSystem].filter(Boolean).join('\n\n');
  const stream = body.stream === true;
  const id = genId();
  const created = now();
  const ac = new AbortController();
  res.on('close', () => ac.abort());

  let text = '';
  let sdkUsage = null;
  let errored = null;

  const consume = async () => {
    const q = runClaude({ promptText, systemText, model, signal: ac.signal });
    for await (const msg of q) {
      if (msg.type === 'assistant' && msg.parent_tool_use_id == null) {
        for (const block of msg.message.content) {
          if (block.type === 'text' && block.text) {
            text += block.text;
            if (stream) writeChunk(res, { id, created, model: reportModel, delta: { content: block.text } });
          }
        }
        if (msg.message.usage) sdkUsage = msg.message.usage;
      } else if (msg.type === 'result') {
        if (msg.usage) sdkUsage = msg.usage;
        if (msg.subtype && msg.subtype !== 'success') errored = msg.subtype;
      }
    }
  };

  if (stream) {
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-store', connection: 'keep-alive' });
    try {
      await consume();
      if (errored) writeChunk(res, { id, created, model: reportModel, delta: { content: `\n[error: ${errored}]` } });
      writeChunk(res, { id, created, model: reportModel, delta: {}, finish_reason: 'stop' });
    } catch (err) {
      // the stream is already open: send the error as a last chunk
      writeChunk(res, { id, created, model: reportModel, delta: { content: `\n[error: ${err.message}]` }, finish_reason: 'stop' });
    }
    res.write('data: [DONE]\n\n');
    res.end();
    return;
  }

  try {
    await consume();
  } catch (err) {
    return oaiError(res, err.status || 500, `claude error: ${err.message}`, 'api_error');
  }
  if (errored && !text) return oaiError(res, 502, `claude session ended with ${errored}`, 'api_error');

  const prompt_tokens = sdkUsage?.input_tokens ?? approxTokens(systemText + promptText);
  const completion_tokens = sdkUsage?.output_tokens ?? approxTokens(text);
  send(res, 200, {
    id, object: 'chat.completion', created, model: reportModel,
    choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }],
    usage: { prompt_tokens, completion_tokens, total_tokens: prompt_tokens + completion_tokens },
  });
}

function writeChunk(res, { id, created, model, delta, finish_reason = null }) {
  const chunk = {
    id, object: 'chat.completion.chunk', created, model,
    choices: [{ index: 0, delta, finish_reason }],
  };
  res.write(`data: ${JSON.stringify(chunk)}\n\n`);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://shim');
    if (req.method === 'GET' && url.pathname === '/healthz') return send(res, 200, { ok: true });

    if (!authorized(req)) return oaiError(res, 401, 'invalid api key', 'authentication_error');

    if (req.method === 'GET' && url.pathname === '/v1/models') {
      return send(res, 200, {
        object: 'list',
        data: [{ id: DEFAULT_MODEL || 'claude-subscription', object: 'model', created: now(), owned_by: 'anthropic-subscription' }],
      });
    }
    if (req.method === 'POST' && url.pathname === '/v1/chat/completions') return await handleCompletions(req, res);
    return oaiError(res, 404, 'not found', 'not_found');
  } catch (err) {
    if (!res.headersSent) oaiError(res, err.status || 500, err.status ? err.message : 'internal error', 'api_error');
    if (!err.status) console.error(err);
  }
});

server.requestTimeout = 300_000;
server.headersTimeout = 305_000;
server.listen(PORT, HOST, () => console.log(
  `claude-bridge listening on http://${HOST}:${PORT}  (model: ${DEFAULT_MODEL || "Claude Code's default"}` +
  `, tools: ${TOOLS_ON ? ALLOWED_TOOLS.join(',') + ' / ' + PERMISSION_MODE : 'NONE (chat)'}` +
  `, memory: ${MEMORY_DIR ? MEMORY_DIR : 'none'})`,
));

for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { server.close(); process.exit(0); });
