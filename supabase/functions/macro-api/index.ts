// Secure username + PIN API for Macro Tracker.
// The service-role credential is read only from the Edge Function environment;
// it must never be shipped in Flutter or GitHub Pages assets.
const PROJECT_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const encoder = new TextEncoder();
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

type Json = Record<string, unknown>;
const json = (body: Json, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

async function digest(value: string): Promise<string> {
  return hex(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(value)),
    ),
  );
}

async function pinHash(pin: string, saltHex: string): Promise<string> {
  const salt = Uint8Array.from(saltHex.match(/.{2}/g) ?? [], (part) =>
    parseInt(part, 16),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(pin),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt, iterations: 310_000 },
    key,
    256,
  );
  return hex(new Uint8Array(bits));
}

async function db(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${PROJECT_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
}

async function dbJson(path: string, init: RequestInit = {}): Promise<any> {
  const response = await db(path, init);
  const text = await response.text();
  if (!response.ok)
    throw new Error(`Database request failed (${response.status}): ${text}`);
  return text ? JSON.parse(text) : null;
}

async function requestClientKey(request: Request): Promise<string> {
  const address =
    request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    "unknown-client";
  return await digest(address);
}

async function auth(request: Request, body: Json): Promise<Response> {
  const action = body.action;
  const username =
    typeof body.username === "string" ? body.username.trim().toLowerCase() : "";
  const pin = typeof body.pin === "string" ? body.pin : "";
  if (!/^[a-z0-9_.-]{3,32}$/.test(username) || !/^\d{4,6}$/.test(pin)) {
    return json({ error: "שם משתמש או PIN אינם תקינים." }, 400);
  }

  if (action !== "signup" && action !== "login")
    return json({ error: "פעולה לא מוכרת." }, 400);
  const clientKey = await requestClientKey(request);
  const rateKey = action === "signup" ? `signup:${clientKey}` : username;
  // Enforce both per-client and account-wide limits so rotating IP addresses
  // cannot turn a short PIN into an unlimited online guessing target.
  const rateClientKeys =
    action === "login" ? [clientKey, "account-wide"] : [clientKey];
  const attemptRows = await Promise.all(
    rateClientKeys.map(async (key) => {
      const filter = `username=eq.${encodeURIComponent(rateKey)}&client_key=eq.${key}&select=locked_until`;
      const rows = await dbJson(`macro_login_attempts?${filter}`);
      return rows?.[0];
    }),
  );
  if (
    attemptRows.some(
      (row) => row?.locked_until && Date.parse(row.locked_until) > Date.now(),
    )
  ) {
    return json({ error: "יותר מדי ניסיונות. נסו שוב בעוד 15 דקות." }, 429);
  }

  if (action === "signup") {
    const salt = hex(crypto.getRandomValues(new Uint8Array(16)));
    const hash = await pinHash(pin, salt);
    const created = await dbJson("macro_users?select=id,username", {
      method: "POST",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({ username, pin_salt: salt, pin_hash: hash }),
    }).catch((error) => {
      if (String(error).includes("23505") || String(error).includes("409"))
        return null;
      throw error;
    });
    if (!created?.[0]) {
      await dbJson("rpc/macro_record_login_failure", {
        method: "POST",
        body: JSON.stringify({ p_username: rateKey, p_client_key: clientKey }),
      });
      return json(
        { error: "לא ניתן ליצור פרופיל בשם הזה. ייתכן שהוא כבר קיים." },
        409,
      );
    }
    // Count successful profile creations too, to discourage scripted account spam.
    await dbJson("rpc/macro_record_login_failure", {
      method: "POST",
      body: JSON.stringify({ p_username: rateKey, p_client_key: clientKey }),
    });
    return await createSession(created[0]);
  }

  const users = await dbJson(
    `macro_users?username=eq.${encodeURIComponent(username)}&select=id,username,pin_salt,pin_hash`,
  );
  const user = users?.[0];
  const suppliedHash = user
    ? await pinHash(pin, user.pin_salt)
    : await pinHash(pin, "00000000000000000000000000000000");
  if (!user || suppliedHash !== user.pin_hash) {
    for (const key of rateClientKeys) {
      await dbJson("rpc/macro_record_login_failure", {
        method: "POST",
        body: JSON.stringify({ p_username: username, p_client_key: key }),
      });
    }
    return json({ error: "שם המשתמש או ה-PIN שגויים." }, 401);
  }

  for (const key of rateClientKeys) {
    await dbJson("rpc/macro_clear_login_failures", {
      method: "POST",
      body: JSON.stringify({ p_username: username, p_client_key: key }),
    });
  }
  return await createSession(user);
}

async function createSession(user: {
  id: string;
  username: string;
}): Promise<Response> {
  const token = hex(crypto.getRandomValues(new Uint8Array(32)));
  const expiresAt = new Date(
    Date.now() + 30 * 24 * 60 * 60 * 1000,
  ).toISOString();
  await dbJson("macro_sessions", {
    method: "POST",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({
      token_hash: await digest(token),
      user_id: user.id,
      expires_at: expiresAt,
    }),
  });
  return json({
    token,
    expires_at: expiresAt,
    profile: { id: user.id, username: user.username },
  });
}

const resources = {
  user_foods: {
    table: "macro_user_foods",
    keys: ["name"],
    fields: [
      "name",
      "calories",
      "protein",
      "carbs",
      "fat",
      "is_liquid",
      "is_recipe",
      "servings",
      "is_favorite",
      "is_deleted",
    ],
  },
  favorites: {
    table: "macro_favorites",
    keys: ["food_name"],
    fields: ["food_name", "is_favorite"],
  },
  meals: {
    table: "macro_meal_entries",
    keys: ["client_id"],
    fields: [
      "client_id",
      "food_name",
      "grams",
      "date",
      "calories",
      "protein",
      "carbs",
      "fat",
      "is_liquid",
      "is_recipe",
      "servings",
      "is_deleted",
      "meal_title",
      "components_json",
    ],
  },
  targets: {
    table: "macro_daily_targets",
    keys: ["date"],
    fields: ["date", "calories", "protein", "carbs", "fat"],
  },
  settings: {
    table: "macro_app_settings",
    keys: [],
    fields: [
      "cal_mode",
      "cal_pct",
      "pro_mode",
      "pro_pct",
      "carb_mode",
      "carb_pct",
      "fat_mode",
      "fat_pct",
    ],
  },
} as const;

type ResourceName = keyof typeof resources;

async function authenticate(
  request: Request,
): Promise<{ id: string; username: string } | null> {
  const token = request.headers
    .get("authorization")
    ?.replace(/^Bearer\s+/i, "")
    .trim();
  if (!token || token.length !== 64) return null;
  const sessions = await dbJson(
    `macro_sessions?token_hash=eq.${await digest(token)}&select=user_id,expires_at`,
  );
  const session = sessions?.[0];
  if (!session || Date.parse(session.expires_at) <= Date.now()) return null;
  const users = await dbJson(
    `macro_users?id=eq.${session.user_id}&select=id,username`,
  );
  return users?.[0] ?? null;
}

async function dataApi(
  request: Request,
  user: { id: string; username: string },
  body: Json,
): Promise<Response> {
  if (body.action === "snapshot") {
    const pairs = await Promise.all(
      Object.entries(resources).map(async ([key, resource]) => {
        const rows = await dbJson(
          `${resource.table}?user_id=eq.${user.id}&select=*`,
        );
        return [key, rows] as const;
      }),
    );
    return json({
      profile: { id: user.id, username: user.username },
      data: Object.fromEntries(pairs),
    });
  }

  if (body.action === "mutate") {
    const entity = body.entity as ResourceName;
    const operation = body.operation;
    const resource = resources[entity];
    if (!resource || !["upsert", "delete"].includes(String(operation)))
      return json({ error: "בקשה לא תקינה." }, 400);
    const base = `${resource.table}?user_id=eq.${user.id}`;
    if (operation === "delete") {
      const key = body.key;
      if (!key || typeof key !== "object")
        return json({ error: "מפתח רשומה חסר." }, 400);
      const filter = resource.keys
        .map(
          (field) =>
            `${field}=eq.${encodeURIComponent(String((key as Json)[field] ?? ""))}`,
        )
        .join("&");
      if (!filter) return json({ error: "הפעולה אינה נתמכת." }, 400);
      await dbJson(`${base}&${filter}`, {
        method: "DELETE",
        headers: { Prefer: "return=minimal" },
      });
      return json({ ok: true });
    }
    const inputs = Array.isArray(body.rows) ? body.rows : [body.row];
    if (
      inputs.length === 0 ||
      inputs.length > 250 ||
      inputs.some(
        (input) => !input || typeof input !== "object" || Array.isArray(input),
      )
    ) {
      return json({ error: "כמות הרשומות או הנתונים אינה תקינה." }, 400);
    }
    const rows = inputs.map((input) => {
      const row: Json = { user_id: user.id };
      for (const field of resource.fields) {
        if (Object.prototype.hasOwnProperty.call(input, field))
          row[field] = (input as Json)[field];
      }
      return row;
    });
    const conflict =
      entity === "favorites"
        ? "user_id,food_name"
        : entity === "targets"
          ? "user_id,date"
          : entity === "user_foods"
            ? "user_id,name"
            : entity === "settings"
              ? "user_id"
              : entity === "meals"
                ? "user_id,client_id"
                : undefined;
    const query = conflict
      ? `${resource.table}?on_conflict=${conflict}`
      : resource.table;
    const result = await dbJson(query, {
      method: "POST",
      headers: { Prefer: `resolution=merge-duplicates,return=representation` },
      body: JSON.stringify(rows),
    });
    return json({ ok: true, rows: result ?? [] });
  }
  return json({ error: "פעולה לא מוכרת." }, 400);
}

const AI_SYSTEM_INSTRUCTION = `You are a careful nutrition analyst. Return valid JSON only, without Markdown.
Required root: meal_title, servings, confidence_note, items.
Each item must include name, search_query, grams, is_liquid, is_assumed_addition, calories_per_100g, protein_per_100g, carbs_per_100g, fat_per_100g. For countable foods where the user gives a number of pieces or units, also include positive numeric count and grams_per_unit; set grams to count multiplied by grams_per_unit. Omit both optional fields when no count-based portion is stated.
Use numeric nutrition values and estimate edible portion weights in grams; explain uncertainty briefly. Default to grams; is_liquid is only a hint for clearly liquid foods and the client resolves units using its food database.
Separate cooking oil and sauces from base foods; never include assumed oil in the base food values.
If oil or sauce is not explicitly confirmed, return it separately with is_assumed_addition=true; never assume oil when user says none.
For recipes, estimate cooked edible amounts and scale grams to the stated servings or portion.
For labels, extract nutrition per 100 g or ml; for product names alone, provide a cautious estimate.
Add variants only for a genuinely ambiguous ingredient or preparation, such as hummus or schnitzel.
Provide at most two short variants for that ambiguous item; omit variants for all other items.
Use concise Hebrew names and confidence_note. The search_query must be a short, clean Hebrew food term, preferably copied from the Hebrew name; never return an English-only search_query when the name contains Hebrew.
Return one item per distinct food component, with 1 to 40 items.
Example shape: {"meal_title":"ארוחה","servings":1,"confidence_note":"הערכה","items":[{"name":"פריכיית אורז","search_query":"פריכיית אורז","count":2,"grams_per_unit":10,"grams":20,"is_liquid":false,"is_assumed_addition":false,"calories_per_100g":380,"protein_per_100g":8,"carbs_per_100g":81,"fat_per_100g":3}]}`;

function normalizeHebrewSearchQuery(name: string, searchQuery: string): string {
  const query = searchQuery.trim().replace(/\s+/g, " ");
  if (/[\u05D0-\u05EA]/.test(query)) return query;

  const hebrewName = (name.match(/[\u05D0-\u05EA]+/g) ?? []).join(" ");
  return hebrewName || query;
}

function isNonNegativeNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function validateMealResult(value: unknown): value is {
  meal_title: string;
  servings: number;
  confidence_note: string;
  items: Json[];
} {
  if (!value || typeof value !== "object") return false;
  const result = value as Json;
  if (
    typeof result.meal_title !== "string" ||
    typeof result.confidence_note !== "string" ||
    !isNonNegativeNumber(result.servings) ||
    !Array.isArray(result.items) ||
    result.items.length < 1 ||
    result.items.length > 40
  )
    return false;
  return result.items.every((raw) => {
    if (!raw || typeof raw !== "object") return false;
    const item = raw as Json;
    const hasCount = Object.prototype.hasOwnProperty.call(item, "count");
    const hasGramsPerUnit = Object.prototype.hasOwnProperty.call(
      item,
      "grams_per_unit",
    );
    const hasValidOptionalPortion =
      hasCount === hasGramsPerUnit &&
      (!hasCount ||
        (isNonNegativeNumber(item.count) &&
          item.count > 0 &&
          isNonNegativeNumber(item.grams_per_unit) &&
          item.grams_per_unit > 0));
    return (
      hasValidOptionalPortion &&
      typeof item.name === "string" &&
      typeof item.search_query === "string" &&
      isNonNegativeNumber(item.grams) &&
      typeof item.is_liquid === "boolean" &&
      typeof item.is_assumed_addition === "boolean" &&
      isNonNegativeNumber(item.calories_per_100g) &&
      isNonNegativeNumber(item.protein_per_100g) &&
      isNonNegativeNumber(item.carbs_per_100g) &&
      isNonNegativeNumber(item.fat_per_100g)
    );
  });
}

function safeAiText(value: unknown, apiKey?: string): string {
  let text =
    typeof value === "string" ? value : String(value ?? "Unknown error");
  if (apiKey) text = text.split(apiKey).join("[redacted]");
  return text
    .replace(/([?&]key=)[^&\s"']+/gi, "$1[redacted]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 1200);
}

function geminiErrorMessage(raw: string, apiKey: string): string {
  try {
    const parsed = JSON.parse(raw);
    const message = parsed?.error?.message ?? parsed?.message ?? raw;
    return safeAiText(message, apiKey);
  } catch (_) {
    return safeAiText(raw, apiKey);
  }
}

async function recordAiFailure(input: {
  requestId: string;
  userId: string;
  mode: string;
  model: string;
  status?: number;
  type: string;
  message: string;
  detail?: string;
  apiKey?: string;
}): Promise<void> {
  const errorMessage = safeAiText(input.message, input.apiKey);
  const errorDetail = input.detail
    ? safeAiText(input.detail, input.apiKey)
    : null;
  try {
    await dbJson("macro_ai_logs", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      signal: AbortSignal.timeout(2000),
      body: JSON.stringify({
        request_id: input.requestId,
        user_id: input.userId,
        mode: input.mode,
        model: input.model,
        http_status: input.status ?? null,
        error_type: input.type,
        error_message: errorMessage,
        error_detail: errorDetail,
      }),
    });
  } catch (error) {
    console.error("[macro-ai] Could not persist failure log", {
      requestId: input.requestId,
      error: safeAiText(error, input.apiKey),
    });
  }
}

async function recordAiSuccess(input: {
  requestId: string;
  userId: string;
  mode: string;
  model: string;
  durationMs: number;
}): Promise<void> {
  try {
    await dbJson("macro_ai_logs", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      signal: AbortSignal.timeout(2000),
      body: JSON.stringify({
        request_id: input.requestId,
        user_id: input.userId,
        mode: input.mode,
        model: input.model,
        http_status: 200,
        error_type: "success",
        error_message: "Gemini response parsed and validated",
        error_detail: `duration_ms=${input.durationMs}`,
      }),
    });
  } catch (error) {
    console.error("[macro-ai] Could not persist success log", {
      requestId: input.requestId,
      error: safeAiText(error),
    });
  }
}

function extractJsonObject(candidateText: string): unknown {
  // Gemini may wrap the JSON in prose or Markdown fences. Find balanced object
  // boundaries while respecting braces inside quoted strings and escaped quotes.
  for (let start = 0; start < candidateText.length; start++) {
    if (candidateText[start] !== "{") continue;
    let depth = 0;
    let inString = false;
    let escaped = false;
    for (let end = start; end < candidateText.length; end++) {
      const character = candidateText[end];
      if (inString) {
        if (escaped) escaped = false;
        else if (character === "\\") escaped = true;
        else if (character === '"') inString = false;
        continue;
      }
      if (character === '"') inString = true;
      else if (character === "{") depth++;
      else if (character === "}" && --depth === 0) {
        try {
          return JSON.parse(candidateText.slice(start, end + 1));
        } catch (_) {
          break;
        }
      }
    }
  }
  throw new Error("No complete valid JSON object in Gemini response");
}

type GeminiModel = { name?: string; supportedGenerationMethods?: string[] };

async function listGeminiModels(apiKey: string): Promise<string[]> {
  const fetchModels = async (): Promise<string[]> => {
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models?key=${encodeURIComponent(apiKey)}&pageSize=100`,
      { signal: AbortSignal.timeout(2000) },
    );
    if (!response.ok) throw new Error(`ListModels HTTP ${response.status}`);
    const data = await response.json();
    if (!Array.isArray(data?.models)) return [];
    return data.models
      .filter(
        (model: GeminiModel) =>
          typeof model.name === "string" &&
          model.supportedGenerationMethods?.includes("generateContent"),
      )
      .map((model: GeminiModel) => String(model.name).replace(/^models\//, ""))
      .filter((name: string) => /^gemini-[a-z0-9.-]+$/i.test(name))
      .sort((a: string, b: string) => a.localeCompare(b));
  };
  cachedGeminiModels ??= fetchModels().catch((error) => {
    cachedGeminiModels = undefined;
    throw error;
  });
  return await cachedGeminiModels;
}

function recommendedGeminiModel(message: string): string | null {
  const modelReferences = Array.from(
    message.matchAll(/models\/(gemini-[a-z0-9.-]+)/gi),
    (match) => match[1],
  ).reverse();
  const candidates = [
    ...modelReferences,
    ...Array.from(
      message.matchAll(/\b(gemini-[a-z0-9.-]*flash[a-z0-9.-]*)\b/gi),
      (match) => match[1],
    ).reverse(),
  ];
  return candidates.find((name) => /^gemini-[a-z0-9.-]+$/i.test(name)) ?? null;
}

let cachedGeminiModels: Promise<string[]> | undefined;
let modelDiscoveryLogged = false;

async function logAvailableModelsOnce(input: {
  requestId: string;
  userId: string;
  mode: string;
  apiKey: string;
  models: string[];
}): Promise<void> {
  if (modelDiscoveryLogged) return;
  modelDiscoveryLogged = true;
  await recordAiFailure({
    requestId: input.requestId,
    userId: input.userId,
    mode: input.mode,
    model: "ListModels",
    status: 200,
    type: "model_discovery",
    message: `Callable Gemini models: ${input.models.join(", ") || "none returned"}`,
    apiKey: input.apiKey,
  });
}

async function analyzeMeal(
  body: Json,
  user: { id: string },
): Promise<Response> {
  const requestId = crypto.randomUUID();
  const startedAt = Date.now();
  const mode = body.mode === "nutrition_label" ? "nutrition_label" : "meal";
  const apiKey = Deno.env.get("GEMINI_API_KEY")?.trim();
  if (!apiKey) {
    await recordAiFailure({
      requestId,
      userId: user.id,
      mode,
      model: "configuration",
      type: "missing_api_key",
      message:
        "Missing API key: GEMINI_API_KEY is not set in the Edge Function environment",
    });
    return json(
      {
        error:
          "ניתוח ה-AI נכשל (Missing API key: GEMINI_API_KEY אינו מוגדר בשרת).",
        request_id: requestId,
      },
      503,
    );
  }

  const text =
    typeof body.text === "string" ? body.text.trim().slice(0, 12000) : "";
  const image =
    typeof body.image_base64 === "string"
      ? body.image_base64.replace(/^data:[^,]+,/, "")
      : "";
  const mimeType =
    typeof body.mime_type === "string" ? body.mime_type.toLowerCase() : "";
  if (!text && !image) return json({ error: "יש להוסיף תיאור או תמונה." }, 400);
  if (
    image &&
    (!["image/jpeg", "image/png", "image/webp"].includes(mimeType) ||
      image.length > 8_500_000)
  ) {
    return json(
      { error: "התמונה חייבת להיות JPEG, PNG או WebP ובגודל קטן מ-6MB." },
      413,
    );
  }

  const prompt =
    mode === "nutrition_label"
      ? `מצב: חילוץ תווית תזונה. חלץ ערכים ל-100 גרם או מ"ל. אם התמונה כוללת תווית, קרא ממנה. תיאור/שם המוצר: ${text || "אין תיאור נוסף"}. החזר meal_title, confidence_note, servings=1 ופריט יחיד עם ערכים ל-100 גרם.`
      : `מצב: ניתוח ארוחה או מתכון. תיאור והערות המשתמש: ${text || "נתח את המזון שבתמונה בלבד."}. החזר את כל הרכיבים בנפרד.`;
  const parts: Json[] = [{ text: prompt }];
  if (image) parts.push({ inline_data: { mime_type: mimeType, data: image } });

  const preferPro = body.pro === true;
  let availableModels: string[] = [];
  try {
    availableModels = await listGeminiModels(apiKey);
    await logAvailableModelsOnce({
      requestId,
      userId: user.id,
      mode,
      apiKey,
      models: availableModels,
    });
  } catch (error) {
    console.warn(
      "[macro-ai] ListModels discovery failed",
      safeAiText(error, apiKey),
    );
  }

  const queue: Array<{ model: string; thinkingBudget?: number }> = [];
  const listModelsSet = new Set(availableModels);
  const addInitialModel = (model: string, thinkingBudget?: number) => {
    if (availableModels.length > 0 && !listModelsSet.has(model)) return;
    queue.push({ model, thinkingBudget });
  };
  if (preferPro) {
    addInitialModel("gemini-3.8-flash", 512);
  } else {
    addInitialModel("gemini-3.5-flash-lite");
    addInitialModel("gemini-3.1-flash-lite");
    addInitialModel("gemini-3.8-flash", 0);
  }
  const initialModels = new Set(queue.map(({ model }) => model));
  for (const model of availableModels) {
    if (!initialModels.has(model)) queue.push({ model });
  }
  if (queue.length === 0) {
    queue.push({
      model: "gemini-3.8-flash",
      thinkingBudget: preferPro ? 512 : 0,
    });
  }
  const queued = new Set(
    queue.map(
      ({ model, thinkingBudget }) => `${model}|${thinkingBudget ?? "none"}`,
    ),
  );
  const tried = new Set<string>();
  const requestDeadline = Date.now() + 38_000;
  let lastStatus = 502;
  let lastModel = "gemini-3.8-flash";
  let lastMessage = "No Gemini response";
  let lastType = "gemini_error";

  const enqueue = (model: string, thinkingBudget?: number, front = false) => {
    const normalized = model.replace(/^models\//, "");
    if (!/^gemini-[a-z0-9.-]+$/i.test(normalized)) return;
    const key = `${normalized}|${thinkingBudget ?? "none"}`;
    if (queued.has(key)) return;
    queued.add(key);
    const next = { model: normalized, thinkingBudget };
    if (front) queue.unshift(next);
    else queue.push(next);
  };

  while (queue.length > 0 && Date.now() < requestDeadline) {
    const attempt = queue.shift()!;
    const { model, thinkingBudget } = attempt;
    const attemptKey = `${model}|${thinkingBudget ?? "none"}`;
    if (tried.has(attemptKey)) continue;
    tried.add(attemptKey);
    lastModel = model;
    const controller = new AbortController();
    const attemptTimeout = Math.min(12_000, requestDeadline - Date.now());
    const timer = setTimeout(() => controller.abort(), attemptTimeout);
    try {
      const generationConfig: Json = {
        responseMimeType: "application/json",
        maxOutputTokens: 2048,
        temperature: 0.2,
      };
      if (thinkingBudget !== undefined) {
        generationConfig.thinkingConfig = { thinkingBudget };
      }
      const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(apiKey)}`;
      const response = await fetch(endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        signal: controller.signal,
        body: JSON.stringify({
          system_instruction: { parts: [{ text: AI_SYSTEM_INSTRUCTION }] },
          contents: [{ role: "user", parts }],
          generationConfig,
        }),
      });
      if (!response.ok) {
        lastStatus = response.status;
        const rawDetail = await response.text();
        lastMessage = geminiErrorMessage(rawDetail, apiKey);
        lastType =
          response.status === 429 ? "gemini_rate_limit" : "gemini_http_error";
        await recordAiFailure({
          requestId,
          userId: user.id,
          mode,
          model,
          status: response.status,
          type: lastType,
          message: lastMessage,
          detail: rawDetail,
          apiKey,
        });

        // Retry the same primary model without thinking parameters on a config-related 400.
        if (response.status === 400 && thinkingBudget !== undefined) {
          enqueue(model, undefined, true);
          continue;
        }
        if (response.status === 404) {
          const recommended = recommendedGeminiModel(lastMessage);
          if (recommended && recommended !== model)
            enqueue(recommended, undefined, true);
        }
        continue;
      }

      const responseBody = await response.json();
      const candidate = responseBody?.candidates?.[0];
      const candidateText =
        candidate?.content?.parts
          ?.map((part: Json) =>
            typeof part.text === "string" ? part.text : "",
          )
          .join("") ?? "";
      let result: unknown;
      try {
        if (!candidateText.trim()) {
          const reason =
            candidate?.finishReason === "MAX_TOKENS"
              ? "Gemini output truncated (MAX_TOKENS)"
              : `Gemini returned no text (finishReason=${candidate?.finishReason ?? "unknown"})`;
          throw new Error(reason);
        }
        result = extractJsonObject(candidateText);
      } catch (error) {
        lastStatus = 502;
        lastType =
          candidate?.finishReason === "MAX_TOKENS"
            ? "gemini_output_truncated"
            : "json_parse_error";
        lastMessage = safeAiText(error, apiKey);
        await recordAiFailure({
          requestId,
          userId: user.id,
          mode,
          model,
          status: 200,
          type: lastType,
          message: lastMessage,
          detail: `finishReason=${candidate?.finishReason ?? "unknown"}`,
          apiKey,
        });
        continue;
      }
      if (!validateMealResult(result)) {
        lastStatus = 502;
        lastType = "json_validation_error";
        lastMessage =
          "JSON validation error: response does not match meal result fields";
        await recordAiFailure({
          requestId,
          userId: user.id,
          mode,
          model,
          status: 200,
          type: lastType,
          message: lastMessage,
          apiKey,
        });
        continue;
      }
      for (const rawItem of result.items) {
        const item = rawItem as Json;
        item.search_query = normalizeHebrewSearchQuery(
          String(item.name),
          String(item.search_query),
        );
      }
      await recordAiSuccess({
        requestId,
        userId: user.id,
        mode,
        model,
        durationMs: Date.now() - startedAt,
      });
      return json({ result, model, request_id: requestId });
    } catch (error) {
      lastStatus =
        error instanceof DOMException && error.name === "AbortError"
          ? 504
          : 502;
      lastType = lastStatus === 504 ? "gemini_timeout" : "gemini_network_error";
      lastMessage =
        lastStatus === 504
          ? "Gemini request timed out after 45000ms"
          : safeAiText(error, apiKey);
      await recordAiFailure({
        requestId,
        userId: user.id,
        mode,
        model,
        status: lastStatus,
        type: lastType,
        message: lastMessage,
        apiKey,
      });
    } finally {
      clearTimeout(timer);
    }
  }

  const detail = `${lastModel} ${lastStatus}: ${lastMessage}`;
  return json(
    {
      error: `ניתוח ה-AI נכשל (${safeAiText(detail, apiKey)})`,
      request_id: requestId,
      provider_status: lastStatus,
      provider_model: lastModel,
    },
    502,
  );
}
Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS")
    return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST")
    return json({ error: "Method not allowed" }, 405);
  if (!PROJECT_URL || !SERVICE_ROLE_KEY)
    return json({ error: "Server is not configured." }, 500);
  try {
    const body = (await request.json()) as Json;
    if (body.action === "signup" || body.action === "login")
      return await auth(request, body);
    if (body.action === "logout") {
      const token = request.headers
        .get("authorization")
        ?.replace(/^Bearer\s+/i, "")
        .trim();
      if (token)
        await dbJson(`macro_sessions?token_hash=eq.${await digest(token)}`, {
          method: "DELETE",
        });
      return json({ ok: true });
    }
    const user = await authenticate(request);
    if (!user)
      return json({ error: "ההתחברות פגה או אינה תקפה. התחברו שוב." }, 401);
    if (body.action === "analyze_meal") return await analyzeMeal(body, user);
    return await dataApi(request, user, body);
  } catch (error) {
    console.error("macro-api request failed:", error);
    return json({ error: "אירעה שגיאה זמנית בשרת." }, 500);
  }
});
