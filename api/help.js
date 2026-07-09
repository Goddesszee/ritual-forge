// Vercel serverless function — POST /api/help
//
// Proxies a chat message to OpenAI so the browser never sees the API key.
// Requires an OPENAI_API_KEY environment variable set in the Vercel
// project dashboard (Settings -> Environment Variables), NOT committed
// to the repo. If it's missing, this returns a clear 500 so the
// frontend can fall back to the scripted FAQ instead of hanging.

const SYSTEM_PROMPT = `You are the help assistant embedded in Forge, a web app for
deploying autonomous AI "companies" on Ritual Chain testnet (chain ID 1979).

How Forge works, for context when answering questions:
- Users deploy a company via the "Deploy a new company" form: Company type
  (short label), System prompt (what the LLM does when paid), Fee per
  request (RITUAL), and Initial treasury funding (RITUAL).
- After deploying, the user must click "Start company" — this funds the
  company's RitualWallet and registers its first Scheduler wake-up. Before
  that, the company shows "no heartbeat yet" and "Not scheduled yet."
- Once started, the company wakes itself up on a loop via Ritual's
  Scheduler system contract, and answers paid requests through Ritual's
  LLM precompile — no server or keeper required.
- "Wake Cycles" = how many times the Scheduler has woken it up. "Requests"
  = how many times someone paid it for a response. "Treasury" = its
  current RITUAL balance.
- Users can test a company via "Test this company": paste a wallet
  address, click "Send request", confirm payment in their wallet, and
  wait for the on-chain response.
- There's a "Swap" feature in the top nav: a modal for swapping native
  testnet RITUAL against a demo token called FORGE, via a simple
  constant-product AMM pool (0.3% fee). Users can also claim 100 FORGE
  per hour for free from a faucet button in that modal.
- Everything is on Ritual Chain testnet — tokens have no real value,
  this is for testing only.

Answer briefly and plainly, like a helpful product FAQ — a few sentences,
not an essay. If a question is unrelated to Forge or blockchain/crypto
topics in general, politely redirect back to what you can help with.`;

module.exports = async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    res.status(500).json({ error: "OPENAI_API_KEY is not configured on the server." });
    return;
  }

  let body = req.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch (e) { body = {}; }
  }
  const message = (body && body.message ? String(body.message) : "").slice(0, 1000);
  const historyRaw = Array.isArray(body && body.history) ? body.history : [];

  if (!message.trim()) {
    res.status(400).json({ error: "Missing message." });
    return;
  }

  // Keep only the last few turns, and only well-formed ones, to bound cost.
  const history = historyRaw
    .filter((m) => m && (m.role === "user" || m.role === "assistant") && typeof m.content === "string")
    .slice(-8)
    .map((m) => ({ role: m.role, content: String(m.content).slice(0, 1000) }));

  try {
    const upstream = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + apiKey,
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          ...history,
          { role: "user", content: message },
        ],
        max_tokens: 350,
        temperature: 0.4,
      }),
    });

    if (!upstream.ok) {
      const detail = await upstream.text();
      console.error("OpenAI error:", upstream.status, detail);
      res.status(502).json({ error: "Upstream model error." });
      return;
    }

    const data = await upstream.json();
    const reply = data && data.choices && data.choices[0] && data.choices[0].message
      ? data.choices[0].message.content
      : "";

    if (!reply) {
      res.status(502).json({ error: "Empty response from model." });
      return;
    }

    res.status(200).json({ reply });
  } catch (e) {
    console.error("Help endpoint error:", e);
    res.status(500).json({ error: "Server error." });
  }
};
