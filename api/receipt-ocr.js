// API endpoint: receipt-ocr
// Works on both Vercel and Netlify
// Modes: receipt, price_compare, route, compare

// ─────────── HELPERS ───────────

const callAnthropic = async (apiKey, system, userContent, maxTokens = 1024, prefill = null) => {
  const messages = [{ role: 'user', content: userContent }];
  if (prefill) messages.push({ role: 'assistant', content: prefill });
  const resp = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'x-api-key': apiKey, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({ model: 'claude-haiku-4-5', max_tokens: maxTokens, system, messages }),
  });
  if (!resp.ok) {
    const eb = await resp.json().catch(() => ({}));
    const msg = eb?.error?.message || `HTTP ${resp.status}`;
    if (eb?.error?.type === 'overloaded_error') throw new Error('Anthropic busy — try again');
    if (resp.status === 429) throw new Error('Anthropic rate limit hit — wait a moment');
    if (resp.status === 529 || msg.toLowerCase().includes('credit')) throw new Error('Usage limit exceeded — check console.anthropic.com billing');
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

// ─────────── GOOGLE PLACES ───────────

const GOOGLE_KEY = process.env.GOOGLE_PLACES_API_KEY;

// Geocode an address → { lat, lon, formatted }
async function geocode(address) {
  if (!GOOGLE_KEY) throw new Error('GOOGLE_PLACES_API_KEY not set');
  const url = `https://maps.googleapis.com/maps/api/geocode/json?address=${encodeURIComponent(address)}&key=${GOOGLE_KEY}`;
  const resp = await fetch(url);
  const data = await resp.json();
  if (data.status !== 'OK' || !data.results?.length) throw new Error(`Geocode failed: ${data.status} ${data.error_message || ''}`);
  const r = data.results[0];
  return { lat: r.geometry.location.lat, lon: r.geometry.location.lng, formatted: r.formatted_address };
}

// Find real stores near a lat/lon. Targets specific brands relevant to the business.
// Uses Google Places Text Search (more flexible than Nearby) to find each brand.
const TARGET_BRANDS = [
  'Restaurant Depot', 'US Chef Store', 'Costco Wholesale', 'QFC', 'Safeway',
  'Fred Meyer', 'Walmart', "Trader Joe's", 'Whole Foods', 'H Mart', 'Uwajimaya',
  'Plaza Latina', 'Imrans', 'African market grocery', 'Amazon Fresh',
];

async function findStoresNearby(lat, lon, radiusMeters = 24000) {
  if (!GOOGLE_KEY) throw new Error('GOOGLE_PLACES_API_KEY not set');
  // Use Places Text Search (New) — more flexible than Nearby for branded queries
  const stores = [];
  const seen = new Set();

  // Run searches in parallel for speed
  const searches = TARGET_BRANDS.map(async (brand) => {
    try {
      const url = `https://places.googleapis.com/v1/places:searchText`;
      const resp = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': GOOGLE_KEY,
          'X-Goog-FieldMask': 'places.id,places.displayName,places.formattedAddress,places.location,places.businessStatus',
        },
        body: JSON.stringify({
          textQuery: brand,
          locationBias: {
            circle: { center: { latitude: lat, longitude: lon }, radius: radiusMeters },
          },
          maxResultCount: 3, // top 3 closest matches per brand
        }),
      });
      if (!resp.ok) return [];
      const data = await resp.json();
      return (data.places || []).map(p => ({
        id: p.id,
        name: p.displayName?.text || brand,
        brand,
        address: p.formattedAddress,
        lat: p.location?.latitude,
        lon: p.location?.longitude,
        status: p.businessStatus,
      })).filter(s => s.status === 'OPERATIONAL' && s.lat && s.lon);
    } catch { return []; }
  });

  const results = await Promise.all(searches);
  for (const arr of results) {
    for (const s of arr) {
      if (seen.has(s.id)) continue;
      seen.add(s.id);
      stores.push(s);
    }
  }
  return stores;
}

// Get real driving distance + duration matrix from origins to destinations.
// Returns 2D array: matrix[i][j] = { miles, minutes } for origin i to destination j
async function getDistanceMatrix(origins, destinations) {
  if (!GOOGLE_KEY) throw new Error('GOOGLE_PLACES_API_KEY not set');
  if (!origins.length || !destinations.length) return [];

  // Google limits to 25 origins × 25 destinations per request
  const oCoords = origins.map(o => `${o.lat},${o.lon}`).join('|');
  const dCoords = destinations.map(d => `${d.lat},${d.lon}`).join('|');
  const url = `https://maps.googleapis.com/maps/api/distancematrix/json?origins=${encodeURIComponent(oCoords)}&destinations=${encodeURIComponent(dCoords)}&units=imperial&key=${GOOGLE_KEY}`;
  const resp = await fetch(url);
  const data = await resp.json();
  if (data.status !== 'OK') throw new Error(`Distance Matrix failed: ${data.status} ${data.error_message || ''}`);

  const matrix = [];
  for (let i = 0; i < data.rows.length; i++) {
    const row = [];
    for (const el of data.rows[i].elements) {
      if (el.status === 'OK') {
        row.push({
          miles: el.distance.value / 1609.344,
          minutes: el.duration.value / 60,
        });
      } else {
        row.push({ miles: null, minutes: null });
      }
    }
    matrix.push(row);
  }
  return matrix;
}

// ─────────── TSP ROUTE OPTIMIZATION ───────────
// Nearest-neighbor + 2-opt improvement. Optimal for ≤10 stops in practice.

function solveTSP(points, distFn, returnToStart = true) {
  // points: [{ lat, lon, index, ... }]
  // distFn(i, j) returns distance (miles or minutes)
  // returnToStart: include leg from last point back to start
  const n = points.length;
  if (n <= 1) return points.map((_, i) => i);

  // Nearest neighbor starting from index 0 (assumed to be the start)
  const visited = new Array(n).fill(false);
  visited[0] = true;
  const tour = [0];
  for (let step = 1; step < n; step++) {
    const last = tour[tour.length - 1];
    let bestJ = -1, bestD = Infinity;
    for (let j = 0; j < n; j++) {
      if (visited[j]) continue;
      const d = distFn(last, j);
      if (d < bestD) { bestD = d; bestJ = j; }
    }
    if (bestJ === -1) break;
    visited[bestJ] = true;
    tour.push(bestJ);
  }

  // 2-opt improvement
  const tourLen = (t) => {
    let total = 0;
    for (let i = 0; i < t.length - 1; i++) total += distFn(t[i], t[i + 1]);
    if (returnToStart) total += distFn(t[t.length - 1], t[0]);
    return total;
  };

  let improved = true;
  let bestLen = tourLen(tour);
  while (improved) {
    improved = false;
    for (let i = 1; i < tour.length - 1; i++) {
      for (let j = i + 1; j < tour.length; j++) {
        // Reverse segment [i..j]
        const newTour = [...tour.slice(0, i), ...tour.slice(i, j + 1).reverse(), ...tour.slice(j + 1)];
        const newLen = tourLen(newTour);
        if (newLen < bestLen - 0.01) {
          tour.splice(0, tour.length, ...newTour);
          bestLen = newLen;
          improved = true;
        }
      }
    }
  }
  return tour;
}

// ─────────── MAIN HANDLER ───────────

async function processRequest(body) {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) return { status: 500, data: { error: 'Server missing ANTHROPIC_API_KEY' } };

  const { image, mediaType, mode, context } = body || {};

  try {
    // ── MODE: receipt ──
    if (mode === 'receipt') {
      if (!image) return { status: 400, data: { error: 'Missing image' } };
      // images may be a single base64 string OR an array (multi-photo receipt)
      const images = Array.isArray(body.images) && body.images.length ? body.images : [image];
      const system = `Receipt parser. Reply ONLY with JSON: {"store_guess":"<Restaurant Depot|Costco|QFC|Walmart|Trader Joe's|US Chef Store|Plaza Latina|Imrans|African Store|Other>","subtotal":<number|null>,"tax":<number|null>,"total":<number|null>,"items":[{"name":"<clean name>","qty":<n>,"price":<unit price>,"raw":"<raw text>"}]}
Clean abbreviations. Skip taxes/fees from items list. subtotal = sum of food/goods before tax. tax = total tax/fees. total = final amount paid. null if unsure.${images.length > 1 ? ' Multiple images are pages of ONE receipt — merge them into a single result.' : ''}`;
      const userContent = [];
      images.forEach((img, idx) => {
        if (images.length > 1) userContent.push({ type: 'text', text: `Page ${idx + 1}/${images.length}:` });
        userContent.push({ type: 'image', source: { type: 'base64', media_type: mediaType || 'image/jpeg', data: img } });
      });
      userContent.push({ type: 'text', text: images.length > 1 ? 'Combine all pages into ONE JSON result.' : 'Extract line items as JSON.' });
      const text = await callAnthropic(apiKey, system, userContent, 2500, '{');
      return { status: 200, data: extractJSON(text) };
    }

    // ── MODE: price_compare (NEW: real stores via Google) ──
    if (mode === 'price_compare') {
      if (!GOOGLE_KEY) return { status: 500, data: { error: 'Server missing GOOGLE_PLACES_API_KEY' } };
      const { startAddress, startCoords, items: allItems, sortMode, radiusMiles } = context || {};
      if (!allItems?.length) return { status: 400, data: { error: 'Missing items' } };

      const items = allItems.slice(0, 12);
      const radius = Math.min(Math.max(Number(radiusMiles) || 15, 5), 40) * 1609.344; // meters

      // Step 1: Get user lat/lon
      let origin;
      if (startCoords?.lat && startCoords?.lon) {
        origin = { lat: startCoords.lat, lon: startCoords.lon, formatted: startAddress || 'Current location' };
      } else if (startAddress) {
        origin = await geocode(startAddress);
      } else {
        return { status: 400, data: { error: 'Need start address or coords' } };
      }

      // Step 2: Find real stores nearby via Google Places
      const nearby = await findStoresNearby(origin.lat, origin.lon, radius);
      if (!nearby.length) {
        return { status: 200, data: {
          items: items.map(i => ({ id: i.id, name: i.name, stores: [{ store: i.trackedStore || 'Other', location: '', distanceMiles: null, price: i.trackedPrice || 0 }] })),
          totalCurrentCost: items.reduce((s, i) => s + Number(i.trackedPrice || 0), 0),
          totalBestCost: items.reduce((s, i) => s + Number(i.trackedPrice || 0), 0),
          storesConsidered: [],
          warning: `No matching stores found within ${(radius/1609.344).toFixed(0)} miles of ${origin.formatted}`,
        }};
      }

      // Step 3: Get real driving distances from origin to each store
      let distMatrix;
      try {
        distMatrix = await getDistanceMatrix([origin], nearby);
      } catch (e) {
        // Fall back to bird's-eye distance using Haversine
        distMatrix = [nearby.map(s => {
          const R = 3958.8; // miles
          const dLat = (s.lat - origin.lat) * Math.PI / 180;
          const dLon = (s.lon - origin.lon) * Math.PI / 180;
          const a = Math.sin(dLat/2)**2 + Math.cos(origin.lat*Math.PI/180) * Math.cos(s.lat*Math.PI/180) * Math.sin(dLon/2)**2;
          return { miles: 2 * R * Math.asin(Math.sqrt(a)), minutes: null };
        })];
      }

      const storesWithDist = nearby.map((s, i) => ({
        ...s,
        distanceMiles: distMatrix[0][i]?.miles ?? null,
        durationMinutes: distMatrix[0][i]?.minutes ?? null,
      })).filter(s => s.distanceMiles != null)
        .sort((a, b) => a.distanceMiles - b.distanceMiles);

      // Step 4: Pick top stores to send to Claude for pricing.
      // Group by brand and take the closest of each brand.
      const closestByBrand = {};
      for (const s of storesWithDist) {
        if (!closestByBrand[s.brand] || s.distanceMiles < closestByBrand[s.brand].distanceMiles) {
          closestByBrand[s.brand] = s;
        }
      }
      const candidateStores = Object.values(closestByBrand);

      // Step 5: Ask Claude ONLY for prices (no location guessing)
      const brandList = candidateStores.map(s => s.brand).join(', ');
      const itemCSV = items.map(i => `${i.id}|${i.name}`).join('\n');

      const system = `Grocery price estimator for Pacific Northwest. Given a list of items and a list of stores, estimate realistic per-unit prices for each item at each relevant store.
Skip stores that don't typically carry an item. Reply ONLY with raw JSON starting with {`;

      const userMsg = `Stores: ${brandList}
Items (id|name):
${itemCSV}

For each item, list 2-4 stores that realistically carry it, with estimated prices.
JSON: {"items":[{"id":"<id>","prices":[{"brand":"<brand>","price":<n>,"note":"<optional>"}]}]}`;

      let priceData;
      try {
        const text = await callAnthropic(apiKey, system, userMsg, 2000, '{"items":[');
        priceData = extractJSON(text);
      } catch (e) {
        return { status: 500, data: { error: 'Price estimation failed: ' + e.message } };
      }

      // Step 6: Merge real store data with Claude's price estimates
      const storeByBrand = {};
      candidateStores.forEach(s => { storeByBrand[s.brand] = s; });

      const mergedItems = items.map(inp => {
        const claudeItem = (priceData.items || []).find(x => String(x.id) === String(inp.id));
        const claudePrices = claudeItem?.prices || [];
        const stores = claudePrices.map(p => {
          const realStore = storeByBrand[p.brand];
          if (!realStore) return null;
          return {
            store: realStore.brand,
            storeName: realStore.name,
            location: realStore.address,
            distanceMiles: realStore.distanceMiles,
            durationMinutes: realStore.durationMinutes,
            lat: realStore.lat,
            lon: realStore.lon,
            placeId: realStore.id,
            price: Number(p.price) || 0,
            note: p.note || '',
          };
        }).filter(Boolean);

        // If Claude returned nothing for this item, use the tracked store as fallback
        if (!stores.length) {
          stores.push({
            store: inp.trackedStore || 'Other',
            storeName: inp.trackedStore || 'Other',
            location: '',
            distanceMiles: null,
            price: inp.trackedPrice || 0,
            note: 'tracked price',
          });
        }
        return { id: inp.id, name: inp.name, stores };
      });

      const totalCurrent = items.reduce((s, i) => s + Number(i.trackedPrice || 0), 0);
      const totalBest = mergedItems.reduce((s, item) => {
        const prices = (item.stores || []).map(x => Number(x.price)).filter(p => p > 0);
        return s + (prices.length ? Math.min(...prices) : 0);
      }, 0);

      return { status: 200, data: {
        items: mergedItems,
        totalCurrentCost: totalCurrent,
        totalBestCost: totalBest,
        storesConsidered: candidateStores.map(s => ({
          brand: s.brand, name: s.name, address: s.address,
          distanceMiles: s.distanceMiles, durationMinutes: s.durationMinutes,
        })),
        origin,
      }};
    }

    // ── MODE: route (NEW: TSP optimization with real distances) ──
    if (mode === 'route') {
      if (!GOOGLE_KEY) return { status: 500, data: { error: 'Server missing GOOGLE_PLACES_API_KEY' } };
      const { startAddress, startCoords, destinationAddress, destSameAsStart, storeStops } = context || {};
      // storeStops: [{ brand, lat, lon, address, items: [...] }]
      if (!storeStops?.length) return { status: 400, data: { error: 'No stores' } };

      // Geocode start
      let origin;
      if (startCoords?.lat && startCoords?.lon) {
        origin = { lat: startCoords.lat, lon: startCoords.lon, address: startAddress || 'Start' };
      } else {
        const g = await geocode(startAddress);
        origin = { lat: g.lat, lon: g.lon, address: g.formatted };
      }

      let destination;
      if (destSameAsStart || !destinationAddress) {
        destination = origin;
      } else {
        const g = await geocode(destinationAddress);
        destination = { lat: g.lat, lon: g.lon, address: g.formatted };
      }

      // Build full point list: [origin, ...stops, destination]
      // For TSP, we want to find the best ORDER of stops between origin and destination
      const allPoints = [
        { ...origin, kind: 'start' },
        ...storeStops.map(s => ({ ...s, kind: 'stop' })),
        { ...destination, kind: 'end' },
      ];

      // Get full distance matrix between all points
      const matrix = await getDistanceMatrix(allPoints, allPoints);
      const distFn = (i, j) => matrix[i]?.[j]?.minutes ?? matrix[i]?.[j]?.miles ?? 0;

      // TSP: find optimal order of intermediate stops (indices 1 to n-2)
      // We want a tour: origin → ... → destination
      // Use nearest-neighbor + 2-opt on the stops only, fixing origin at start and destination at end
      const stopIndices = storeStops.map((_, i) => i + 1); // 1..n-1

      // Nearest neighbor from origin
      const visited = new Set();
      const orderedStopIdxs = [];
      let current = 0; // origin
      while (orderedStopIdxs.length < stopIndices.length) {
        let best = -1, bestD = Infinity;
        for (const idx of stopIndices) {
          if (visited.has(idx)) continue;
          const d = distFn(current, idx);
          if (d < bestD) { bestD = d; best = idx; }
        }
        if (best === -1) break;
        visited.add(best);
        orderedStopIdxs.push(best);
        current = best;
      }

      // 2-opt improvement (with origin and destination fixed)
      const destIdx = allPoints.length - 1;
      const totalCost = (order) => {
        let cost = distFn(0, order[0]); // origin → first stop
        for (let i = 0; i < order.length - 1; i++) cost += distFn(order[i], order[i + 1]);
        cost += distFn(order[order.length - 1], destIdx); // last stop → destination
        return cost;
      };

      let bestOrder = orderedStopIdxs.slice();
      let bestCost = totalCost(bestOrder);
      let improved = true;
      while (improved) {
        improved = false;
        for (let i = 0; i < bestOrder.length - 1; i++) {
          for (let j = i + 1; j < bestOrder.length; j++) {
            const newOrder = [...bestOrder.slice(0, i), ...bestOrder.slice(i, j + 1).reverse(), ...bestOrder.slice(j + 1)];
            const newCost = totalCost(newOrder);
            if (newCost < bestCost - 0.01) {
              bestOrder = newOrder;
              bestCost = newCost;
              improved = true;
            }
          }
        }
      }

      // Build ordered route output
      let totalMiles = 0;
      let totalMinutes = 0;
      const sequence = [0, ...bestOrder, destIdx];
      for (let i = 0; i < sequence.length - 1; i++) {
        const m = matrix[sequence[i]]?.[sequence[i + 1]];
        if (m) {
          totalMiles += m.miles || 0;
          totalMinutes += m.minutes || 0;
        }
      }

      const route = bestOrder.map((idx, i) => {
        const stop = allPoints[idx];
        const prevIdx = i === 0 ? 0 : bestOrder[i - 1];
        const leg = matrix[prevIdx]?.[idx];
        return {
          store: stop.brand,
          storeName: stop.name,
          order: i + 1,
          lat: stop.lat,
          lon: stop.lon,
          address: stop.address,
          items: stop.items || [],
          travelNote: leg ? `${(leg.miles || 0).toFixed(1)} mi · ${Math.round(leg.minutes || 0)} min` : '',
        };
      });

      return { status: 200, data: {
        route,
        origin: { lat: origin.lat, lon: origin.lon, address: origin.address },
        destination: { lat: destination.lat, lon: destination.lon, address: destination.address },
        totalEstimatedMiles: Math.round(totalMiles * 10) / 10,
        totalEstimatedMinutes: Math.round(totalMinutes),
        routeSummary: `${route.length} stop${route.length !== 1 ? 's' : ''} · ${totalMiles.toFixed(1)} mi · ~${Math.round(totalMinutes)} min driving`,
      }};
    }

    // ── MODE: compare (legacy) ──
    if (mode === 'compare') {
      const system = `Price advisor for Joe's Kitchen, Redmond WA. 2-3 sentences, be specific.`;
      const userMsg = `Item: ${context?.itemName}, Store: ${context?.currentStore}, Price: $${context?.currentPrice}`;
      const text = await callAnthropic(apiKey, system, userMsg, 200);
      return { status: 200, data: { recommendation: text } };
    }

    return { status: 400, data: { error: `Unknown mode: ${mode}` } };
  } catch (err) {
    return { status: 500, data: { error: err.message } };
  }
}

// ── Vercel handler ──
module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
  const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
  const result = await processRequest(body);
  return res.status(result.status).json(result.data);
};

// ── Netlify handler ──
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
  try { body = JSON.parse(event.body); } catch { return { statusCode: 400, headers, body: JSON.stringify({ error: 'Invalid JSON' }) }; }
  const result = await processRequest(body);
  return { statusCode: result.status, headers, body: JSON.stringify(result.data) };
};

module.exports.config = {
  api: { bodyParser: { sizeLimit: '5mb' } },
};
