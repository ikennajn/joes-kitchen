// Netlify Function: receipt-ocr
// Handles four modes:
//   receipt       → OCR a receipt photo, return structured line items
//   compare       → text recommendation for a single item (legacy)
//   price_compare → JSON price comparison across stores for a shopping list
//   route         → JSON ordered store route for efficiency

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

  // Helper: call Claude and return raw text
  const callClaude = async (system, userContent, maxTokens = 2000) => {
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
        messages: [{ role: 'user', content: userContent }],
      }),
    });
    if (!resp.ok) {
      const err = await resp.text();
      throw new Error(`Anthropic API error ${resp.status}: ${err.slice(0, 200)}`);
    }
    const data = await resp.json();
    return (data.content || []).filter(b => b.type === 'text').map(b => b.text).join('\n');
  };

  // Helper: extract JSON from text that may have prose or markdown around it
  const extractJSON = (text) => {
    // Strip markdown fences
    let s = text.replace(/```json\s*/gi, '').replace(/```\s*/gi, '').trim();
    // Try direct parse
    try { return JSON.parse(s); } catch {}
    // Find outermost { ... } or [ ... ]
    const fi = s.indexOf('{');
    const fib = s.indexOf('[');
    let start = -1;
    if (fi === -1 && fib === -1) throw new Error('No JSON object found in response');
    if (fi === -1) start = fib;
    else if (fib === -1) start = fi;
    else start = Math.min(fi, fib);
    const isArr = s[start] === '[';
    const end = isArr ? s.lastIndexOf(']') : s.lastIndexOf('}');
    if (end === -1) throw new Error('Malformed JSON in response');
    return JSON.parse(s.slice(start, end + 1));
  };

  try {

    // ── MODE: receipt ──
    if (mode === 'receipt') {
      if (!image) return { statusCode: 400, headers, body: JSON.stringify({ error: 'Missing image' }) };

      const system = `You are a receipt-parsing assistant. Extract every purchased line item from the receipt image.
Reply ONLY with a raw JSON object — no prose, no markdown fences, no explanation. Start your response with {
Use this exact shape:
{"store_guess":"<store name>","total":<number or null>,"items":[{"name":"<cleaned name>","qty":<number>,"price":<number per unit USD>,"raw":"<raw receipt text>"}]}
Rules:
- store_guess must be one of: Restaurant Depot, Costco, QFC, Walmart, Trader Joe's, US Chef Store, Plaza Latina, Imrans, African Store, Other
- Clean abbreviations: CHKN THGH BNLS → Chicken Thigh Boneless
- Skip subtotals, taxes, fees — only actual purchased items
- qty "2 @ $4.99" → qty=2, price=4.99
- Use null for any value you are unsure about`;

      const text = await callClaude(system, [
        { type: 'image', source: { type: 'base64', media_type: mediaType || 'image/jpeg', data: image } },
        { type: 'text', text: 'Extract all line items from this receipt as JSON.' },
      ]);
      const parsed = extractJSON(text);
      return { statusCode: 200, headers, body: JSON.stringify(parsed) };
    }

    // ── MODE: price_compare ──
    if (mode === 'price_compare') {
      const { zipCode, items: shoppingItems } = context || {};
      if (!shoppingItems || !shoppingItems.length) {
        return { statusCode: 400, headers, body: JSON.stringify({ error: 'Missing items' }) };
      }

      const system = `You are a grocery price comparison assistant for Joe's Kitchen, a Nigerian/fusion meal-prep business near ZIP ${zipCode || '98052'} in the Seattle/Redmond, WA area.
Use your knowledge of typical retail and wholesale prices in the Pacific Northwest.
Available stores: Restaurant Depot (wholesale bulk), US Chef Store (wholesale), Costco (bulk), QFC (grocery), Walmart (grocery/general), Trader Joe's (specialty grocery), Plaza Latina (Latin grocery), Imrans (halal/international), African Store (West African specialty), Amazon (online).
Provide realistic price estimates at 2-4 relevant stores per item based on what each store actually stocks.
You MUST respond with ONLY a raw JSON object. No prose. No explanation. No markdown. No code fences. Your entire response must be valid JSON starting with { and ending with }.`;

      const itemsSummary = shoppingItems.map(i =>
        `{"id":"${i.id}","name":"${i.name}","trackedStore":"${i.trackedStore}","trackedPrice":${i.trackedPrice || 0}}`
      ).join(',\n');

      const userMsg = `Shopping list for ZIP ${zipCode} (${shoppingItems.length} items):
[${itemsSummary}]

Return this exact JSON structure:
{
  "items": [
    {
      "id": "<same id as input>",
      "name": "<item name>",
      "stores": [
        { "store": "<store name>", "price": <number>, "note": "<optional: bulk only, per lb, etc>" }
      ]
    }
  ],
  "totalCurrentCost": <sum of all trackedPrice values>,
  "totalBestCost": <sum of cheapest price per item>
}`;

      const text = await callClaude(system, userMsg, 4000);
      let parsed;
      try {
        parsed = extractJSON(text);
      } catch (e) {
        // Log raw response for debugging
        console.log('price_compare raw response:', text.slice(0, 500));
        throw new Error('Could not parse price data: ' + e.message);
      }

      if (!parsed.items || !Array.isArray(parsed.items)) {
        throw new Error('Response missing items array');
      }

      // Ensure every input item is represented
      const outputIds = new Set(parsed.items.map(i => String(i.id)));
      for (const inp of shoppingItems) {
        if (!outputIds.has(String(inp.id))) {
          parsed.items.push({
            id: inp.id, name: inp.name,
            stores: [{ store: inp.trackedStore || 'Other', price: inp.trackedPrice || 0, note: 'tracked price' }],
          });
        }
      }

      // Recalculate totals server-side (don't trust Claude's math)
      parsed.totalCurrentCost = shoppingItems.reduce((s, i) => s + (i.trackedPrice || 0), 0);
      parsed.totalBestCost = parsed.items.reduce((s, item) => {
        const prices = (item.stores || []).map(s => Number(s.price)).filter(p => p > 0);
        return s + (prices.length ? Math.min(...prices) : 0);
      }, 0);

      return { statusCode: 200, headers, body: JSON.stringify(parsed) };
    }

    // ── MODE: route ──
    if (mode === 'route') {
      const { zipCode, destination, storeGroups } = context || {};
      const storeList = Object.keys(storeGroups || {});

      const system = `You are a route optimization assistant for a shopper starting from ZIP ${zipCode || '98052'} in the Seattle/Redmond, WA area.
Order the provided stores for the most efficient driving route, ending at: ${destination || 'back to ZIP ' + (zipCode || '98052')}.
Store locations in Seattle metro (approximate):
- Restaurant Depot: Tukwila (south, ~15mi from Redmond)
- US Chef Store: near Restaurant Depot or Bellevue
- Costco: Issaquah, Kirkland, or Seattle
- QFC: widespread suburban, close to residential
- Walmart: Renton, Lynnwood, Bellevue
- Trader Joe's: Redmond Town Center, Bellevue, Kirkland
- Plaza Latina: Redmond/Bellevue corridor
- Imrans: Bellevue
- African Store: varies
You MUST respond with ONLY a raw JSON object. No prose. No markdown. Start with {`;

      const userMsg = `ZIP: ${zipCode}, Destination: ${destination || 'back to ZIP ' + zipCode}
Stores to visit: ${storeList.join(', ')}

Return:
{
  "route": [
    { "store": "<name>", "order": <1,2,3...>, "travelNote": "<short leg description, e.g. '10 min south on I-405'>" }
  ],
  "totalEstimatedMiles": <number>,
  "routeSummary": "<one sentence>"
}`;

      const text = await callClaude(system, userMsg, 1000);
      const parsed = extractJSON(text);
      return { statusCode: 200, headers, body: JSON.stringify(parsed) };
    }

    // ── MODE: compare (legacy) ──
    if (mode === 'compare') {
      const system = `You are a price comparison assistant for Joe's Kitchen in Redmond, WA. Suggest the best store to buy the item from. Reply in 2-3 short sentences.`;
      const userMsg = `Item: ${context?.itemName}\nStore: ${context?.currentStore}\nPrice: $${context?.currentPrice}\nHistory: ${JSON.stringify(context?.history || []).slice(0, 500)}`;
      const text = await callClaude(system, userMsg, 300);
      return { statusCode: 200, headers, body: JSON.stringify({ recommendation: text }) };
    }

    return { statusCode: 400, headers, body: JSON.stringify({ error: `Unknown mode: ${mode}` }) };

  } catch (err) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: err.message }) };
  }
};
