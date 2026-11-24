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

const nutritionItemSchema = {
  type: "OBJECT",
  properties: {
    name: { type: "STRING" },
    search_query: { type: "STRING" },
    grams: { type: "NUMBER" },
    is_liquid: { type: "BOOLEAN" },
    is_assumed_addition: { type: "BOOLEAN" },
    calories_per_100g: { type: "NUMBER" },
    protein_per_100g: { type: "NUMBER" },
    carbs_per_100g: { type: "NUMBER" },
    fat_per_100g: { type: "NUMBER" },
    variants: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          label: { type: "STRING" },
          calories_per_100g: { type: "NUMBER" },
          protein_per_100g: { type: "NUMBER" },
          carbs_per_100g: { type: "NUMBER" },
          fat_per_100g: { type: "NUMBER" },
        },
        required: [
          "label",
          "calories_per_100g",
          "protein_per_100g",
          "carbs_per_100g",
          "fat_per_100g",
        ],
      },
    },
  },
  required: [
    "name",
    "search_query",
    "grams",
    "is_liquid",
    "is_assumed_addition",
    "calories_per_100g",
    "protein_per_100g",
    "carbs_per_100g",
    "fat_per_100g",
  ],
};

const mealResponseSchema = {
  type: "OBJECT",
  properties: {
    meal_title: { type: "STRING" },
    servings: { type: "NUMBER" },
    confidence_note: { type: "STRING" },
    items: { type: "ARRAY", items: nutritionItemSchema },
  },
  required: ["meal_title", "servings", "confidence_note", "items"],
};

const AI_SYSTEM_INSTRUCTION = `אתה דיאטן קליני ישראלי בכיר ומומחה לראייה ממוחשבת וכימות מזון. נתח ארוחה/מתכון או תווית תזונה והחזר JSON בלבד לפי הסכמה.

כללי ניתוח תמונה: תחילה כייל קנה מידה מול עוגנים חזותיים: צלחת מנה עיקרית ישראלית בקוטר כ-26–28 ס"מ, צלחת קטנה כ-20 ס"מ, מזלג או כף כ-19 ס"מ, קופסת אוכל, כוס או כף יד. הערך לכל מזון שטח פנים כפול גובה/עומק כדי לאמוד cm³, ואז הכפל בצפיפות סבירה: אורז/קוסקוס מבושל כ-0.8 g/cm³, בשר/דג/עוף מבושל כ-1.05, חומוס/טחינה/גבינה כ-1.1, סלט קצוץ כ-0.5, עלים כ-0.2. אלה אומדנים; הבהר אי-ודאות ב-confidence_note ולעולם אל תציג דיוק מזויף.

חוק חשוב: לעולם אל תכלול שמן בישול/טיגון בערכי המזון הבסיסי. החזר למשל אורז מבושל ללא שמן כפריט נקי, והוסף שמן/רוטב בנפרד כ-is_assumed_addition=true עם כמות והסבר קצר בעברית. אם המשתמש אומר במפורש שאין שמן, אל תניח שמן. רטבים נסתרים יוצגו בנפרד כהשערה שניתנת להסרה.

כאשר ערכים משתנים משמעותית לפי מותג או הכנה (למשל חומוס תעשייתי/ביתי, שניצל אפוי/מטוגן, טחינה מוכנה/גולמית, גבינה באחוזי שומן שונים, לחם רגיל/קל), ספק 2–3 variants בעברית עם ערכים ל-100 גרם. אל תמציא מותג אם אינו ידוע.

למתכון מסיר/תבנית, חשב סך רכיבים ומשקל אכיל לאחר בישול לפי המידע שנמסר. אם צוין מספר מנות או חלק שנאכל, החזר grams של החלק שנאכל לכל רכיב והגדר servings מתאים; אם לא צוין, החזר אומדן למנה אחת עם servings=1. בתווית תזונה חלץ ערכים ל-100 גרם/מ"ל. אם נמסר רק שם מוצר בלי תווית, תן אומדן שמרני וציין זאת.

כל השמות וההערות בעברית, search_query קצר ונקי לחיפוש. הערכים מספרים לא שליליים ל-100 גרם. החזר JSON בלבד ללא Markdown.`;

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
    return (
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

async function analyzeMeal(body: Json): Promise<Response> {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) return json({ error: "שירות ניתוח ה-AI אינו מוגדר בשרת." }, 503);
  const text =
    typeof body.text === "string" ? body.text.trim().slice(0, 12000) : "";
  const image =
    typeof body.image_base64 === "string"
      ? body.image_base64.replace(/^data:[^,]+,/, "")
      : "";
  const mimeType =
    typeof body.mime_type === "string" ? body.mime_type.toLowerCase() : "";
  const mode = body.mode === "nutrition_label" ? "nutrition_label" : "meal";
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
      ? `מצב: חילוץ תווית תזונה. חלץ ערכים ל-100 גרם או מ"ל. אם התמונה כוללת תווית, קרא ממנה. תיאור/שם המוצר: ${text || "אין תיאור נוסף"}. החזר meal_title, confidence_note, servings=1 ופריט יחיד (או רכיבי תווית נדרשים) עם ערכים ל-100 גרם.`
      : `מצב: ניתוח ארוחה או מתכון. תיאור והערות המשתמש: ${text || "נתח את המזון שבתמונה בלבד."}. החזר את כל הרכיבים בנפרד.`;
  const parts: Json[] = [{ text: prompt }];
  if (image) parts.push({ inlineData: { mimeType, data: image } });
  const modelSchema = mealResponseSchema;
  const preferPro = body.pro === true;
  const models = preferPro
    ? [
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
        "gemini-2.0-flash",
      ]
    : ["gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash"];
  let lastStatus = 503;
  for (const model of models) {
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(apiKey)}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: AI_SYSTEM_INSTRUCTION }] },
          contents: [{ role: "user", parts }],
          generationConfig: {
            responseMimeType: "application/json",
            responseSchema: modelSchema,
            temperature: 0.2,
          },
        }),
      },
    );
    if (!response.ok) {
      lastStatus = response.status;
      if ([404, 429, 503].includes(response.status)) continue;
      const detail = await response.text();
      console.error(
        `Gemini ${model} failed (${response.status}):`,
        detail.slice(0, 500),
      );
      return json({ error: "ניתוח ה-AI נכשל. נסו שוב בעוד רגע." }, 502);
    }
    try {
      const responseBody = await response.json();
      const candidateText = responseBody?.candidates?.[0]?.content?.parts
        ?.map((part: Json) => part.text ?? "")
        .join("");
      const result = JSON.parse(candidateText);
      if (!validateMealResult(result))
        throw new Error("Gemini returned invalid nutrition schema");
      return json({ result, model });
    } catch (error) {
      console.error(`Could not parse Gemini ${model} response:`, error);
      return json({ error: "התקבלה תשובה לא תקינה מה-AI. נסו שוב." }, 502);
    }
  }
  return json(
    {
      error: `מודלי ה-AI אינם זמינים כרגע (${lastStatus}). נסו שוב מאוחר יותר.`,
    },
    503,
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
    if (body.action === "analyze_meal") return await analyzeMeal(body);
    return await dataApi(request, user, body);
  } catch (error) {
    console.error("macro-api request failed:", error);
    return json({ error: "אירעה שגיאה זמנית בשרת." }, 500);
  }
});
