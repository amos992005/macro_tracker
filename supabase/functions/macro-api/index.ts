// Secure username + PIN API for Macro Tracker.
// The service-role credential is read only from the Edge Function environment;
// it must never be shipped in Flutter or GitHub Pages assets.
const PROJECT_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const encoder = new TextEncoder();
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json; charset=utf-8',
};

type Json = Record<string, unknown>;
const json = (body: Json, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function digest(value: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value))));
}

async function pinHash(pin: string, saltHex: string): Promise<string> {
  const salt = Uint8Array.from(saltHex.match(/.{2}/g) ?? [], (part) => parseInt(part, 16));
  const key = await crypto.subtle.importKey('raw', encoder.encode(pin), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: 310_000 }, key, 256);
  return hex(new Uint8Array(bits));
}

async function db(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${PROJECT_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  });
}

async function dbJson(path: string, init: RequestInit = {}): Promise<any> {
  const response = await db(path, init);
  const text = await response.text();
  if (!response.ok) throw new Error(`Database request failed (${response.status}): ${text}`);
  return text ? JSON.parse(text) : null;
}

async function requestClientKey(request: Request): Promise<string> {
  const address = request.headers.get('cf-connecting-ip') ??
    request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'unknown-client';
  return await digest(address);
}

async function auth(request: Request, body: Json): Promise<Response> {
  const action = body.action;
  const username = typeof body.username === 'string' ? body.username.trim().toLowerCase() : '';
  const pin = typeof body.pin === 'string' ? body.pin : '';
  if (!/^[a-z0-9_.-]{3,32}$/.test(username) || !/^\d{4,6}$/.test(pin)) {
    return json({ error: 'שם משתמש או PIN אינם תקינים.' }, 400);
  }

  if (action !== 'signup' && action !== 'login') return json({ error: 'פעולה לא מוכרת.' }, 400);
  const clientKey = await requestClientKey(request);
  const rateKey = action === 'signup' ? `signup:${clientKey}` : username;
  // Enforce both per-client and account-wide limits so rotating IP addresses
  // cannot turn a short PIN into an unlimited online guessing target.
  const rateClientKeys = action === 'login' ? [clientKey, 'account-wide'] : [clientKey];
  const attemptRows = await Promise.all(rateClientKeys.map(async (key) => {
    const filter = `username=eq.${encodeURIComponent(rateKey)}&client_key=eq.${key}&select=locked_until`;
    const rows = await dbJson(`macro_login_attempts?${filter}`);
    return rows?.[0];
  }));
  if (attemptRows.some((row) => row?.locked_until && Date.parse(row.locked_until) > Date.now())) {
    return json({ error: 'יותר מדי ניסיונות. נסו שוב בעוד 15 דקות.' }, 429);
  }

  if (action === 'signup') {
    const salt = hex(crypto.getRandomValues(new Uint8Array(16)));
    const hash = await pinHash(pin, salt);
    const created = await dbJson('macro_users?select=id,username', {
      method: 'POST',
      headers: { Prefer: 'return=representation' },
      body: JSON.stringify({ username, pin_salt: salt, pin_hash: hash }),
    }).catch((error) => {
      if (String(error).includes('23505') || String(error).includes('409')) return null;
      throw error;
    });
    if (!created?.[0]) {
      await dbJson('rpc/macro_record_login_failure', {
        method: 'POST',
        body: JSON.stringify({ p_username: rateKey, p_client_key: clientKey }),
      });
      return json({ error: 'לא ניתן ליצור פרופיל בשם הזה. ייתכן שהוא כבר קיים.' }, 409);
    }
    // Count successful profile creations too, to discourage scripted account spam.
    await dbJson('rpc/macro_record_login_failure', {
      method: 'POST',
      body: JSON.stringify({ p_username: rateKey, p_client_key: clientKey }),
    });
    return await createSession(created[0]);
  }

  const users = await dbJson(`macro_users?username=eq.${encodeURIComponent(username)}&select=id,username,pin_salt,pin_hash`);
  const user = users?.[0];
  const suppliedHash = user ? await pinHash(pin, user.pin_salt) : await pinHash(pin, '00000000000000000000000000000000');
  if (!user || suppliedHash !== user.pin_hash) {
      for (const key of rateClientKeys) {
        await dbJson('rpc/macro_record_login_failure', {
          method: 'POST',
          body: JSON.stringify({ p_username: username, p_client_key: key }),
        });
      }
      return json({ error: 'שם המשתמש או ה-PIN שגויים.' }, 401);
    }

    for (const key of rateClientKeys) {
      await dbJson('rpc/macro_clear_login_failures', {
        method: 'POST',
        body: JSON.stringify({ p_username: username, p_client_key: key }),
      });
    }
  return await createSession(user);
}

async function createSession(user: { id: string; username: string }): Promise<Response> {
  const token = hex(crypto.getRandomValues(new Uint8Array(32)));
  const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
  await dbJson('macro_sessions', {
    method: 'POST',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify({ token_hash: await digest(token), user_id: user.id, expires_at: expiresAt }),
  });
  return json({ token, expires_at: expiresAt, profile: { id: user.id, username: user.username } });
}

const resources = {
  user_foods: {
    table: 'macro_user_foods', keys: ['name'],
    fields: ['name', 'calories', 'protein', 'carbs', 'fat', 'is_liquid', 'is_recipe', 'servings', 'is_favorite', 'is_deleted'],
  },
  favorites: { table: 'macro_favorites', keys: ['food_name'], fields: ['food_name', 'is_favorite'] },
  meals: {
    table: 'macro_meal_entries', keys: ['client_id'],
    fields: ['client_id', 'food_name', 'grams', 'date', 'calories', 'protein', 'carbs', 'fat', 'is_liquid', 'is_recipe', 'servings', 'is_deleted'],
  },
  targets: { table: 'macro_daily_targets', keys: ['date'], fields: ['date', 'calories', 'protein', 'carbs', 'fat'] },
  settings: {
    table: 'macro_app_settings', keys: [],
    fields: ['cal_mode', 'cal_pct', 'pro_mode', 'pro_pct', 'carb_mode', 'carb_pct', 'fat_mode', 'fat_pct'],
  },
} as const;

type ResourceName = keyof typeof resources;

async function authenticate(request: Request): Promise<{ id: string; username: string } | null> {
  const token = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '').trim();
  if (!token || token.length !== 64) return null;
  const sessions = await dbJson(`macro_sessions?token_hash=eq.${await digest(token)}&select=user_id,expires_at`);
  const session = sessions?.[0];
  if (!session || Date.parse(session.expires_at) <= Date.now()) return null;
  const users = await dbJson(`macro_users?id=eq.${session.user_id}&select=id,username`);
  return users?.[0] ?? null;
}

async function dataApi(request: Request, user: { id: string; username: string }, body: Json): Promise<Response> {
  if (body.action === 'snapshot') {
    const pairs = await Promise.all(Object.entries(resources).map(async ([key, resource]) => {
      const rows = await dbJson(`${resource.table}?user_id=eq.${user.id}&select=*`);
      return [key, rows] as const;
    }));
    return json({ profile: { id: user.id, username: user.username }, data: Object.fromEntries(pairs) });
  }

  if (body.action === 'mutate') {
    const entity = body.entity as ResourceName;
    const operation = body.operation;
    const resource = resources[entity];
    if (!resource || !['upsert', 'delete'].includes(String(operation))) return json({ error: 'בקשה לא תקינה.' }, 400);
    const base = `${resource.table}?user_id=eq.${user.id}`;
    if (operation === 'delete') {
      const key = body.key;
      if (!key || typeof key !== 'object') return json({ error: 'מפתח רשומה חסר.' }, 400);
      const filter = resource.keys.map((field) => `${field}=eq.${encodeURIComponent(String((key as Json)[field] ?? ''))}`).join('&');
      if (!filter) return json({ error: 'הפעולה אינה נתמכת.' }, 400);
      await dbJson(`${base}&${filter}`, { method: 'DELETE', headers: { Prefer: 'return=minimal' } });
      return json({ ok: true });
    }
    const inputs = Array.isArray(body.rows) ? body.rows : [body.row];
    if (inputs.length === 0 || inputs.length > 250 || inputs.some((input) => !input || typeof input !== 'object' || Array.isArray(input))) {
      return json({ error: 'כמות הרשומות או הנתונים אינה תקינה.' }, 400);
    }
    const rows = inputs.map((input) => {
      const row: Json = { user_id: user.id };
      for (const field of resource.fields) {
        if (Object.prototype.hasOwnProperty.call(input, field)) row[field] = (input as Json)[field];
      }
      return row;
    });
    const conflict = entity === 'favorites' ? 'user_id,food_name'
      : entity === 'targets' ? 'user_id,date'
      : entity === 'user_foods' ? 'user_id,name'
      : entity === 'settings' ? 'user_id'
      : entity === 'meals' ? 'user_id,client_id'
      : undefined;
    const query = conflict ? `${resource.table}?on_conflict=${conflict}` : resource.table;
    const result = await dbJson(query, {
      method: 'POST',
      headers: { Prefer: `resolution=merge-duplicates,return=representation` },
      body: JSON.stringify(rows),
    });
    return json({ ok: true, rows: result ?? [] });
  }
  return json({ error: 'פעולה לא מוכרת.' }, 400);
}

Deno.serve(async (request: Request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  if (!PROJECT_URL || !SERVICE_ROLE_KEY) return json({ error: 'Server is not configured.' }, 500);
  try {
    const body = await request.json() as Json;
    if (body.action === 'signup' || body.action === 'login') return await auth(request, body);
    if (body.action === 'logout') {
      const token = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '').trim();
      if (token) await dbJson(`macro_sessions?token_hash=eq.${await digest(token)}`, { method: 'DELETE' });
      return json({ ok: true });
    }
    const user = await authenticate(request);
    if (!user) return json({ error: 'ההתחברות פגה או אינה תקפה. התחברו שוב.' }, 401);
    return await dataApi(request, user, body);
  } catch (error) {
    console.error('macro-api request failed:', error);
    return json({ error: 'אירעה שגיאה זמנית בשרת.' }, 500);
  }
});
