// API endpoint: receipt-ocr
// Works on BOTH Vercel and Netlify Functions
// Vercel: place at /api/receipt-ocr.js — exports default handler(req, res)
// Netlify: place at /netlify/functions/receipt-ocr.js — exports.handler(event)

// ── Shared business logic ──
async function processRequest(body) {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) return { status: 500, data: { error: 'Server missing ANTHROPIC_API_KEY env var' } };

  const { image, mediaType, mode, context } = body || {};

  const callClaude = async (system, userContent, maxTokens = 1024, prefill = null) => {
    const messages = [{ role: 'user', content: userContent }];
    if (prefill) messages.push({ role: 'assistant', content: prefill });
    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': apiKey, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'claude-haiku-4-5', max_tokens: maxTokens, system, messages }),
    });
    if (!resp.ok) {
      const errBody = await resp.json().catch(() => ({}));
      const msg = errBody?.error?.message || `HTTP ${resp.status}`;
      const type = errBody?.error?.type || '';
      if (type === 'overloaded_error') throw new Error('Anthropic servers busy — try again');
      if (resp.status === 429) throw new Error('Rate limit hit — wait a moment');
      if (resp.status === 529 || msg.toLowerCase().includes('usage') || msg.toLowerCase().includes('credit')) {
        throw new Error('Usage limit exceeded — check console.anthropic.com billing');
      }
      throw new Error(`Anthropic error: ${msg}`);
    }
    const data = await resp.json();
    let text = (data.content || []).filter(b => b.type === 'text').map(b => b.text).join('\n');
    if (prefill) text = prefill + text;
    return text;
  };

  const extractJSON = (text) => {
    if (!text) throw new Error('Empty response');
    let s = text.replace(/```json\s*/gi, '').replace(/```\s*/gi, '').trim();
    try { return JSON.parse(s); } catch {}
    const start = s.indexOf('{');
    if (start === -1) throw new Error(`No JSON found. Got: ${s.slice(0, 100)}`);
    let depth = 0, inStr = false, esc = false, end = -1;
    for (let i = start; i < s.length; i++) {
      const c = s[i];
      if (esc) { esc = false; continue; }
      if (c === '\\') { esc = true; continue; }
      if (c === '"') { inStr = !inStr; continue; }
      if (inStr) continue;
      if (c === '{') depth++;
      else if (c === '}') { depth--; if (depth === 0) { end = i; break; } }
    }
    if (end === -1) throw new Error(`Unbalanced JSON. Got: ${s.slice(0, 100)}`);
    return JSON.parse(s.slice(start, end + 1));
  };

  try {
    // ── MODE: receipt ──
    if (mode === 'receipt') {
      if (!image) return { status: 400, data: { error: 'Missing image' } };
      const system = `Receipt parser. Reply ONLY with JSON: {"store_guess":"<Restaurant Depot|Costco|QFC|Walmart|Trader Joe's|US Chef Store|Plaza Latina|Imrans|African Store|Other>","total":<number|null>,"items":[{"name":"<clean name>","qty":<n>,"price":<unit price>,"raw":"<raw text>"}]}
Clean abbreviations. Skip taxes/fees. null if unsure.`;
      const text = await callClaude(system, [
        { type: 'image', source: { type: 'base64', media_type: mediaType || 'image/jpeg', data: image } },
        { type: 'text', text: 'Extract line items as JSON.' },
      ], 1500, '{');
      return { status: 200, data: extractJSON(text) };
    }

    // ── MODE: price_compare ──
    if (mode === 'price_compare') {
      const { startAddress, startCoords, items: allItems, sortMode } = context || {};
      if (!allItems?.length) return { status: 400, data: { error: 'Missing items' } };
      const items = allItems.slice(0, 8);
      const location = startAddress || (startCoords ? `${startCoords.lat},${startCoords.lon}` : 'Redmond WA');
      const sortNote = sortMode === 'proximity'
        ? 'Prioritize nearby stores. Only include >15mi if much cheaper.'
        : 'Prioritize cheapest stores regardless of distance.';

      const system = `Grocery price assistant for Seattle/Redmond WA area. ${sortNote}
Stores: Restaurant Depot (Tukwila, wholesale), US Chef Store (Tukwila), Costco (Issaquah/Kirkland), QFC (widespread), Walmart (Renton/Bellevue), Trader Joe's (Redmond/Bellevue), Fred Meyer (Bellevue), Plaza Latina (Bellevue), Imrans (Bellevue), African Store (Tukwila).
Give realistic PNW prices. Reply ONLY with raw JSON starting with {`;

      const itemCSV = items.map(i => `${i.id}|${i.name}|${i.trackedStore}|${i.trackedPrice}`).join('\n');
      const userMsg = `Location: ${location}
Items (id|name|currentStore|currentPrice):
${itemCSV}

JSON: {"items":[{"id":"<id>","name":"<n>","stores":[{"store":"<s>","location":"<city>","distanceMiles":<n>,"lat":<n>,"lon":<n>,"price":<n>}]}],"storesConsidered":["<store>"]}`;

      let text;
      try { text = await callClaude(system, userMsg, 2000, '{"items":['); }
      catch (e) { return { status: 500, data: { error: e.message } }; }

      let parsed;
      try { parsed = extractJSON(text); }
      catch (e) { return { status: 500, data: { error: 'Could not parse price data', detail: e.message, rawSample: text.slice(0, 300) } }; }

      if (!Array.isArray(parsed.items)) {
        return { status: 500, data: { error: 'Bad response structure', rawSample: text.slice(0, 300) } };
      }

      const outIds = new Set(parsed.items.map(i => String(i.id)));
      for (const inp of items) {
        if (!outIds.has(String(inp.id))) {
          parsed.items.push({ id: inp.id, name: inp.name, stores: [{ store: inp.trackedStore || 'Other', location: '', distanceMiles: null, price: inp.trackedPrice || 0 }] });
        }
      }

      parsed.totalCurrentCost = items.reduce((s, i) => s + Number(i.trackedPrice || 0), 0);
      parsed.totalBestCost = parsed.items.reduce((s, item) => {
        const prices = (item.stores || []).map(x => Number(x.price)).filter(p => p > 0);
        return s + (prices.length ? Math.min(...prices) : 0);
      }, 0);
      if (!parsed.storesConsidered) {
        const all = new Set();
        parsed.items.forEach(it => (it.stores || []).forEach(s => all.add(s.store)));
        parsed.storesConsidered = [...all];
      }
      return { status: 200, data: parsed };
    }

    // ── MODE: route ──
    if (mode === 'route') {
      const { startAddress, startCoords, destinationAddress, storeGroups } = context || {};
      const stores = Object.keys(storeGroups || {});
      if (!stores.length) return { status: 400, data: { error: 'No stores' } };
      const start = startAddress || (startCoords ? `${startCoords.lat},${startCoords.lon}` : 'Redmond WA');
      const dest = destinationAddress || start;

      const system = `Route optimizer for Seattle/Redmond WA. Order stores for efficient driving from start to destination.
Locations: Restaurant Depot/US Chef Store=Tukwila, Costco=Issaquah/Kirkland, QFC=suburban, Walmart=Renton/Bellevue, Trader Joe's/Plaza Latina/Imrans=Redmond/Bellevue, Fred Meyer=Bellevue, African Store=Tukwila.
Reply ONLY with raw JSON starting with {`;

      const userMsg = `Start: ${start}
End: ${dest}
Stores: ${stores.join(', ')}
JSON: {"route":[{"store":"<n>","order":<n>,"lat":<n>,"lon":<n>,"address":"<city>","travelNote":"<short>"}],"totalEstimatedMiles":<n>,"routeSummary":"<1 sentence>"}`;

      let text;
      try { text = await callClaude(system, userMsg, 800, '{'); }
      catch (e) { return { status: 500, data: { error: e.message } }; }

      let parsed;
      try { parsed = extractJSON(text); }
      catch (e) { return { status: 500, data: { error: 'Could not parse route', detail: e.message } }; }
      return { status: 200, data: parsed };
    }

    // ── MODE: compare (legacy) ──
    if (mode === 'compare') {
      const system = `Price advisor for Joe's Kitchen, Redmond WA. 2-3 sentences, be specific.`;
      const userMsg = `Item: ${context?.itemName}, Store: ${context?.currentStore}, Price: $${context?.currentPrice}`;
      const text = await callClaude(system, userMsg, 200);
      return { status: 200, data: { recommendation: text } };
    }

    return { status: 400, data: { error: `Unknown mode: ${mode}` } };
  } catch (err) {
    return { status: 500, data: { error: err.message } };
  }
}

// ── Vercel handler (default export) ──
// Place this file at /api/receipt-ocr.js
module.exports = async (req, res) => {
  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  // Vercel auto-parses JSON, but be defensive
  const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
  const result = await processRequest(body);
  return res.status(result.status).json(result.data);
};

// ── Netlify handler (named export) ──
// Place this file at /netlify/functions/receipt-ocr.js
// Netlify will call exports.handler — Vercel will call module.exports above
module.exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Content-Type': 'application/json',
  };
  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers, body: '' };
  if (event.httpMethod !== 'POST') return { statusCode: 405, headers, body: JSON.stringify({ error: 'Method not allowed' }) };

  let body;
  try { body = JSON.parse(event.body); }
  catch { return { statusCode: 400, headers, body: JSON.stringify({ error: 'Invalid JSON' }) }; }

  const result = await processRequest(body);
  return { statusCode: result.status, headers, body: JSON.stringify(result.data) };
};

// Vercel needs a larger body size limit for receipt images
module.exports.config = {
  api: { bodyParser: { sizeLimit: '5mb' } },
};
