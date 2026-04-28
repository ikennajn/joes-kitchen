// Netlify Function: receipt-ocr
// Proxies receipt image → Anthropic Vision API → structured line items
// Keeps API key server-side. Deployed automatically when you push to Netlify.

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
  if (!image) return { statusCode: 400, headers, body: JSON.stringify({ error: 'Missing image' }) };

  // Two modes:
  //   "receipt"  -> extract line items from a receipt photo
  //   "compare"  -> compare item to inventory data and suggest store
  const isCompare = mode === 'compare';

  const systemPrompt = isCompare
    ? `You are a price comparison assistant for Joe's Kitchen, a meal-prep business in Redmond, WA. The user will share an inventory item and its purchase history. Suggest the best store to buy it from and any cost-saving tips. Reply in 2-3 short sentences. Be concrete and specific.`
    : `You are a receipt-parsing assistant. Extract every purchased line item from the receipt image. Reply ONLY with valid JSON in this exact shape:
{
  "store_guess": "Restaurant Depot" | "Costco" | "QFC" | "Walmart" | "Trader Joe's" | "US Chef Store" | "Plaza Latina" | "Imrans" | "African Store" | "Other",
  "total": <number or null>,
  "items": [
    { "name": "<cleaned item name>", "qty": <number, default 1>, "price": <number per unit, USD>, "raw": "<raw text from receipt>" }
  ]
}
Rules:
- Clean abbreviations: "CHKN THGH BNLS" -> "Chicken Thigh Boneless"
- Skip subtotals, taxes, fees, totals — only actual purchased items
- If qty appears as "2 @ $4.99" or "x2", set qty=2 and price=4.99
- If unsure about a value, use null
- Do not include any prose outside the JSON. No markdown fences.`;

  const userContent = isCompare
    ? [{ type: 'text', text: `Item: ${context?.itemName || 'unknown'}\nCategory: ${context?.category || 'unknown'}\nCurrent store: ${context?.currentStore || 'unknown'}\nCurrent price: $${context?.currentPrice || 0}\nPurchase history: ${JSON.stringify(context?.history || []).slice(0, 1000)}\n\nGive a brief recommendation.` }]
    : [
        { type: 'image', source: { type: 'base64', media_type: mediaType || 'image/jpeg', data: image } },
        { type: 'text', text: 'Extract all line items from this receipt as JSON.' },
      ];

  try {
    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5',
        max_tokens: 2000,
        system: systemPrompt,
        messages: [{ role: 'user', content: userContent }],
      }),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      return { statusCode: resp.status, headers, body: JSON.stringify({ error: 'Anthropic API error', detail: errText }) };
    }

    const data = await resp.json();
    const text = (data.content || []).filter(b => b.type === 'text').map(b => b.text).join('\n');

    if (isCompare) {
      return { statusCode: 200, headers, body: JSON.stringify({ recommendation: text }) };
    }

    // Parse JSON from receipt mode
    let parsed;
    try {
      const cleaned = text.replace(/```json\s*/g, '').replace(/```\s*$/g, '').trim();
      parsed = JSON.parse(cleaned);
    } catch (e) {
      return { statusCode: 500, headers, body: JSON.stringify({ error: 'Failed to parse Claude output', raw: text }) };
    }

    return { statusCode: 200, headers, body: JSON.stringify(parsed) };
  } catch (err) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: err.message }) };
  }
};
