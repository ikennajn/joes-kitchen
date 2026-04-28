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

  const callClaude = async (system, userContent, maxTokens = 2000, prefill = null) => {
    const messages = [{ role: 'user', content: userContent }];
    if (prefill) messages.push({ role: 'assistant', content: prefill });
    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': apiKey, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'claude-haiku-4-5', max_tokens: maxTokens, system, messages }),
    });
    if (!resp.ok) {
      const err = await resp.text();
      throw new Error(`Anthropic API error ${resp.status}: ${err.slice(0, 300)}`);
    }
    const data = await resp.json();
    let text = (data.content || []).filter(b => b.type === 'text').map(b => b.text).join('\n');
    if (prefill) text = prefill + text;
    return text;
  };

  const extractJSON = (text) => {
    if (!text || typeof text !== 'string') throw new Error('Empty response from AI');
    let s = text.replace(/```json\s*/gi, '').replace(/```\s*/gi, '').trim();
    try { return JSON.parse(s); } catch {}
    const start = s.indexOf('{');
    if (start === -1) throw new Error(`No JSON object found. Raw: ${text.slice(0, 200)}`);
    let depth = 0, inString = false, escape = false, end = -1;
    for (let i = start; i < s.length; i++) {
      const c = s[i];
      if (escape) { escape = false; continue; }
      if (c === '\\') { escape = true; continue; }
      if (c === '"') { inString = !inString; continue; }
      if (inString) continue;
      if (c === '{') depth++;
      else if (c === '}') { depth--; if (depth === 0) { end = i; break; } }
    }
    if (end === -1) throw new Error(`Unbalanced JSON. Raw: ${text.slice(0, 200)}`);
    try { return JSON.parse(s.slice(start, end + 1)); }
    catch (e) { throw new Error(`JSON.parse failed: ${e.message}. Extracted: ${s.slice(start, end + 1).slice(0, 200)}`); }
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
      return { statusCode: 200, headers, body: JSON.stringify(extractJSON(text)) };
    }

    // ── MODE: price_compare ──
    if (mode === 'price_compare') {
      const { startAddress, startCoords, items: shoppingItems, sortMode } = context || {};
      if (!shoppingItems || !shoppingItems.length) {
        return { statusCode: 400, headers, body: JSON.stringify({ error: 'Missing items' }) };
      }
      const capped = shoppingItems.slice(0, 15);

      // Sort mode: 'proximity' = closest stores first, 'cost' = cheapest stores first
      const sortPreference = sortMode === 'proximity'
        ? `IMPORTANT: Prioritize stores by PROXIMITY to the start location. List the closest stores first. Even if a store is slightly more expensive, include it if it is much closer. Only include far-away stores (>15 miles) if they offer significant savings.`
        : `IMPORTANT: Prioritize stores by COST. Find the cheapest options across all stores in the broader Seattle/Tacoma metro area, even if some are far from the start location. List cheaper stores first.`;

      const system = `You are a grocery price and store-location assistant for the Seattle/Bellevue/Redmond, WA area.
Start location: ${startAddress || 'unspecified'}${startCoords ? ` (lat ${startCoords.lat}, lon ${startCoords.lon})` : ''}.

You know typical retail prices and approximate store locations in the Puget Sound region. For each item, suggest 2-4 stores where it can be reasonably purchased.

Available chains and rough Seattle metro locations:
- Restaurant Depot: Tukwila (south Seattle, member-only wholesale)
- US Chef Store: Tukwila, Lynnwood, Federal Way
- Costco: Issaquah, Kirkland, Seattle, Tukwila, Federal Way
- QFC: dozens of suburban locations
- Safeway: many locations
- Fred Meyer: Bellevue, Redmond, Kirkland, Renton
- Walmart: Renton, Lynnwood, Bellevue (Crossroads)
- Trader Joe's: Bellevue, Redmond, Kirkland, Bothell
- Whole Foods: Bellevue, Redmond, Kirkland
- Plaza Latina: Bellevue
- Imrans/H Mart/Uwajimaya: Bellevue, Bellevue, Seattle/Bellevue
- African specialty stores: Tukwila/Renton area
- Amazon Fresh: online delivery

${sortPreference}

For each store you recommend, include its specific neighborhood/city and approximate distance from the start location in miles. Also include lat/lon if you can estimate it.

Respond ONLY with raw JSON. No prose. No markdown.`;

      const userMsg = `Shopping list (${capped.length} items):
${capped.map(i => `- ${i.name} (currently tracked at ${i.trackedStore} for $${i.trackedPrice || 0}, id: ${i.id})`).join('\n')}

Required JSON:
{"items":[{"id":"<id>","name":"<name>","stores":[{"store":"<store name>","location":"<neighborhood/city>","distanceMiles":<number>,"lat":<number>,"lon":<number>,"price":<number>,"note":"<optional>"}]}],"storesConsidered":["<list of all store names you considered>"]}`;

      let text;
      try { text = await callClaude(system, userMsg, 5000, '{"items":['); }
      catch (e) { return { statusCode: 500, headers, body: JSON.stringify({ error: 'AI request failed: ' + e.message }) }; }

      let parsed;
      try { parsed = extractJSON(text); }
      catch (e) {
        return { statusCode: 500, headers, body: JSON.stringify({ error: 'Could not parse price data', detail: e.message, rawSample: text.slice(0, 500) }) };
      }

      if (!parsed.items || !Array.isArray(parsed.items)) {
        return { statusCode: 500, headers, body: JSON.stringify({ error: 'Response missing items', rawSample: text.slice(0, 500) }) };
      }

      // Backfill omitted items
      const outIds = new Set(parsed.items.map(i => String(i.id)));
      for (const inp of capped) {
        if (!outIds.has(String(inp.id))) {
          parsed.items.push({
            id: inp.id, name: inp.name,
            stores: [{ store: inp.trackedStore || 'Other', location: '', distanceMiles: null, price: inp.trackedPrice || 0, note: 'tracked price' }],
          });
        }
      }

      // Recalculate totals
      parsed.totalCurrentCost = capped.reduce((s, i) => s + Number(i.trackedPrice || 0), 0);
      parsed.totalBestCost = parsed.items.reduce((s, item) => {
        const prices = (item.stores || []).map(x => Number(x.price)).filter(p => p > 0);
        return s + (prices.length ? Math.min(...prices) : 0);
      }, 0);

      // Aggregate considered stores list
      if (!parsed.storesConsidered) {
        const all = new Set();
        parsed.items.forEach(it => (it.stores || []).forEach(s => all.add(s.store)));
        parsed.storesConsidered = [...all];
      }

      return { statusCode: 200, headers, body: JSON.stringify(parsed) };
    }

    // ── MODE: route ──
    if (mode === 'route') {
      const { startAddress, startCoords, destinationAddress, destinationCoords, storeGroups } = context || {};
      const storeList = Object.keys(storeGroups || {});
      if (!storeList.length) return { statusCode: 400, headers, body: JSON.stringify({ error: 'No stores' }) };

      const system = `You optimize multi-stop driving routes in the Seattle/Bellevue/Redmond, WA metro area.
Start: ${startAddress || 'unknown'}${startCoords ? ` (${startCoords.lat}, ${startCoords.lon})` : ''}
End: ${destinationAddress || 'same as start'}${destinationCoords ? ` (${destinationCoords.lat}, ${destinationCoords.lon})` : ''}

For each store in the input, return an order plus its approximate lat/lon coordinates so the route can be drawn on a map. Use real-world approximate coordinates for the specific store locations in Seattle metro.

Respond ONLY with raw JSON.`;

      const userMsg = `Stores to visit: ${storeList.join(', ')}

JSON shape:
{"route":[{"store":"<name>","order":<1,2,3>,"lat":<number>,"lon":<number>,"address":"<short street/city>","travelNote":"<short leg description>"}],"totalEstimatedMiles":<number>,"routeSummary":"<one sentence>"}`;

      const text = await callClaude(system, userMsg, 1500, '{');
      let parsed;
      try { parsed = extractJSON(text); }
      catch (e) {
        return { statusCode: 500, headers, body: JSON.stringify({ error: 'Could not parse route', detail: e.message, rawSample: text.slice(0, 500) }) };
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
