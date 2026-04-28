// Netlify Function: receipt-ocr
// Modes: receipt, price_compare, route, compare

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json',
  };

  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers, body: '' };
  if (event.httpMethod !== 'POST') return { statusCode: 405, headers, body: JSON.stringify({ error: 'Method not allowed' }) };

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) return { statusCode: 500, headers, body: JSON.stringify({ error: 'Server missing ANTHROPIC_API_KEY env var' }) };

  let body;
  try { body = JSON.parse(event.body); }
  catch { return { statusCode: 400, headers, body: JSON.stringify({ error: 'Invalid JSON' }) }; }

  const { image, mediaType, mode, context } = body;

  // Call Claude — supports prefill (assistant pre-fills "{" so output continues as JSON)
  const callClaude = async (system, userContent, maxTokens = 2000, prefill = null) => {
    const messages = [{ role: 'user', content: userContent }];
    if (prefill) messages.push({ role: 'assistant', content: prefill });

    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5',
        max_tokens: maxTokens,
        system,
        messages,
      }),
    });
    if (!resp.ok) {
      const err = await resp.text();
      throw new Error(`Anthropic API error ${resp.status}: ${err.slice(0, 300)}`);
    }
    const data = await resp.json();
    let text = (data.content || []).filter(b => b.type === 'text').map(b => b.text).join('\n');
    // If we prefilled with "{", prepend it so the result is valid JSON
    if (prefill) text = prefill + text;
    return text;
  };

  // Robust JSON extractor — strips fences, finds balanced braces, handles trailing/leading prose
  const extractJSON = (text) => {
    if (!text || typeof text !== 'string') throw new Error('Empty response from AI');

    // 1. Try to strip markdown fences and parse directly
    let s = text.replace(/```json\s*/gi, '').replace(/```\s*/gi, '').trim();
    try { return JSON.parse(s); } catch {}

    // 2. Find the outermost balanced { ... }
    const start = s.indexOf('{');
    if (start === -1) throw new Error(`No JSON object found. Raw: ${text.slice(0, 200)}`);

    let depth = 0;
    let inString = false;
    let escape = false;
    let end = -1;
    for (let i = start; i < s.length; i++) {
      const c = s[i];
      if (escape) { escape = false; continue; }
      if (c === '\\') { escape = true; continue; }
      if (c === '"') { inString = !inString; continue; }
      if (inString) continue;
      if (c === '{') depth++;
      else if (c === '}') {
        depth--;
        if (depth === 0) { end = i; break; }
      }
    }
    if (end === -1) throw new Error(`Unbalanced JSON braces. Raw: ${text.slice(0, 200)}`);

    const jsonStr = s.slice(start, end + 1);
    try {
      return JSON.parse(jsonStr);
    } catch (e) {
      throw new Error(`JSON.parse failed: ${e.message}. Extracted: ${jsonStr.slice(0, 200)}`);
    }
  };

  try {

    // ── MODE: receipt ──
    if (mode === 'receipt') {
      if (!image) return { statusCode: 400, headers, body: JSON.stringify({ error: 'Missing image' }) };

      const system = `You are a receipt-parsing assistant. Extract every purchased line item from the receipt image and respond with JSON only.
Schema: {"store_guess":"<one of: Restaurant Depot, Costco, QFC, Walmart, Trader Joe's, US Chef Store, Plaza Latina, Imrans, African Store, Other>","total":<number|null>,"items":[{"name":"<cleaned name>","qty":<number>,"price":<number per unit USD>,"raw":"<raw receipt text>"}]}
Rules: Clean abbreviations (CHKN THGH BNLS → Chicken Thigh Boneless). Skip subtotals/taxes/fees. "2 @ $4.99" means qty=2, price=4.99. Use null when unsure.`;

      const text = await callClaude(system, [
        { type: 'image', source: { type: 'base64', media_type: mediaType || 'image/jpeg', data: image } },
        { type: 'text', text: 'Extract all line items as JSON.' },
      ], 2000, '{');
      const parsed = extractJSON(text);
      return { statusCode: 200, headers, body: JSON.stringify(parsed) };
    }

    // ── MODE: price_compare ──
    if (mode === 'price_compare') {
      const { zipCode, items: shoppingItems } = context || {};
      if (!shoppingItems || !shoppingItems.length) {
        return { statusCode: 400, headers, body: JSON.stringify({ error: 'Missing items in context' }) };
      }

      // Cap items to keep response size manageable
      const capped = shoppingItems.slice(0, 15);

      const system = `You are a grocery price comparison assistant near ZIP ${zipCode || '98052'} in Seattle/Redmond, WA.
Use your knowledge of typical retail and wholesale prices in the Pacific Northwest.
Stores: Restaurant Depot (wholesale bulk), US Chef Store (wholesale), Costco (bulk), QFC (grocery), Walmart, Trader Joe's, Plaza Latina (Latin), Imrans (halal), African Store (West African), Amazon.
Provide realistic price estimates at 2-3 relevant stores per item.

Respond ONLY with raw JSON. No markdown. No explanation. No prose. Begin your response with the opening brace and end with the closing brace.`;

      const userMsg = `Items to compare (ZIP ${zipCode}):
${capped.map(i => `- ${i.name} (currently tracked at ${i.trackedStore} for $${i.trackedPrice || 0}, id: ${i.id})`).join('\n')}

Required JSON shape:
{"items":[{"id":"<id>","name":"<name>","stores":[{"store":"<store>","price":<number>,"note":"<optional>"}]}]}`;

      let text;
      try {
        text = await callClaude(system, userMsg, 4000, '{"items":[');
      } catch (e) {
        return { statusCode: 500, headers, body: JSON.stringify({ error: 'AI request failed: ' + e.message }) };
      }

      let parsed;
      try {
        parsed = extractJSON(text);
      } catch (e) {
        // Return the raw response so the client can show debug info
        return { statusCode: 500, headers, body: JSON.stringify({
          error: 'Could not parse price data',
          detail: e.message,
          rawSample: text.slice(0, 500),
        })};
      }

      if (!parsed.items || !Array.isArray(parsed.items)) {
        return { statusCode: 500, headers, body: JSON.stringify({
          error: 'AI response missing items array',
          rawSample: text.slice(0, 500),
        })};
      }

      // Backfill any items the AI omitted
      const outIds = new Set(parsed.items.map(i => String(i.id)));
      for (const inp of capped) {
        if (!outIds.has(String(inp.id))) {
          parsed.items.push({
            id: inp.id, name: inp.name,
            stores: [{ store: inp.trackedStore || 'Other', price: inp.trackedPrice || 0, note: 'tracked price' }],
          });
        }
      }

      // Recalculate totals server-side
      parsed.totalCurrentCost = capped.reduce((s, i) => s + Number(i.trackedPrice || 0), 0);
      parsed.totalBestCost = parsed.items.reduce((s, item) => {
        const prices = (item.stores || []).map(x => Number(x.price)).filter(p => p > 0);
        return s + (prices.length ? Math.min(...prices) : 0);
      }, 0);

      return { statusCode: 200, headers, body: JSON.stringify(parsed) };
    }

    // ── MODE: route ──
    if (mode === 'route') {
      const { zipCode, destination, storeGroups } = context || {};
      const storeList = Object.keys(storeGroups || {});
      if (!storeList.length) {
        return { statusCode: 400, headers, body: JSON.stringify({ error: 'No stores to route' }) };
      }

      const system = `You order shopping stops for efficient driving from ZIP ${zipCode || '98052'} in Seattle/Redmond, WA, ending at ${destination || 'back to ZIP ' + (zipCode || '98052')}.
Approximate locations: Restaurant Depot/US Chef Store (Tukwila/south), Costco (Issaquah/Kirkland), QFC (suburban widespread), Walmart (Renton/Lynnwood), Trader Joe's (Redmond/Bellevue), Plaza Latina (Redmond/Bellevue), Imrans (Bellevue), African Store (varies).

Respond ONLY with raw JSON. No prose. No markdown.`;

      const userMsg = `From ZIP ${zipCode}, visit these stores and end at ${destination || 'ZIP ' + zipCode}: ${storeList.join(', ')}

JSON shape:
{"route":[{"store":"<name>","order":<1,2,3>,"travelNote":"<short leg note>"}],"totalEstimatedMiles":<number>,"routeSummary":"<one sentence>"}`;

      const text = await callClaude(system, userMsg, 1000, '{');
      let parsed;
      try {
        parsed = extractJSON(text);
      } catch (e) {
        return { statusCode: 500, headers, body: JSON.stringify({
          error: 'Could not parse route data',
          detail: e.message,
          rawSample: text.slice(0, 500),
        })};
      }
      return { statusCode: 200, headers, body: JSON.stringify(parsed) };
    }

    // ── MODE: compare (legacy) ──
    if (mode === 'compare') {
      const system = `You are a price comparison assistant for Joe's Kitchen in Redmond, WA. Suggest the best store. 2-3 short sentences.`;
      const userMsg = `Item: ${context?.itemName}\nStore: ${context?.currentStore}\nPrice: $${context?.currentPrice}\nHistory: ${JSON.stringify(context?.history || []).slice(0, 500)}`;
      const text = await callClaude(system, userMsg, 300);
      return { statusCode: 200, headers, body: JSON.stringify({ recommendation: text }) };
    }

    return { statusCode: 400, headers, body: JSON.stringify({ error: `Unknown mode: ${mode}` }) };

  } catch (err) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: err.message }) };
  }
};
