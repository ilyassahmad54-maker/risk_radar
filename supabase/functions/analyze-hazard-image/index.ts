import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const modelName = "gemini-3.5-flash-lite";

const hazardResponseSchema = {
  type: "OBJECT",
  properties: {
    hazards: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          category: { type: "STRING" },
          description: { type: "STRING" },
          severity: { type: "STRING" },
          action: { type: "STRING" },
        },
        required: ["category", "description", "severity", "action"],
      },
    },
    summary: { type: "STRING" },
  },
  required: ["hazards", "summary"],
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const apiKey = Deno.env.get("GEMINI_API_KEY");
    if (!apiKey) {
      return jsonResponse(
        { error: "GEMINI_API_KEY is not configured on the Edge Function." },
        500,
      );
    }

    const body = await req.json();
    const imageBase64 = body?.imageBase64;
    const mimeType = body?.mimeType || "image/jpeg";

    if (typeof imageBase64 !== "string" || imageBase64.length === 0) {
      return jsonResponse({ error: "imageBase64 is required." }, 400);
    }

    if (!["image/jpeg", "image/png", "image/webp"].includes(mimeType)) {
      return jsonResponse({ error: "Unsupported image type." }, 400);
    }

    // Keep requests small enough for Edge Function and Gemini payload limits.
    if (imageBase64.length > 7_000_000) {
      return jsonResponse({ error: "Image is too large. Use a smaller photo." }, 413);
    }

    const prompt = `
You are a Senior HSE Risk Assessor for the "RiskRadar" safety platform.
Analyze the provided worksite image and identify safety violations strictly according to OSHA/ISO safety standards.

Return ONLY valid JSON. No markdown, no conversational text.
Do not include trailing commas anywhere in the JSON.

Required JSON Schema:
{
  "hazards": [
    {
      "category": "string (e.g., PPE Violation, Fall Hazard, Electrical, Housekeeping)",
      "description": "string (Max 15 words. Technical and direct.)",
      "severity": "string (Critical|High|Medium|Low)",
      "action": "string (Immediate corrective action. Max 10 words.)"
    }
  ],
  "summary": "string (One professional sentence summarizing the site safety status)"
}

Guidelines:
1. Be strict. If a hazard exists, report it.
2. Descriptions must be to-the-point and technical. No fluff.
3. Do not invent hazards. If the image is safe, return an empty hazards array.
4. Focus strictly on PPE, Working at Heights, Electrical, Fire Safety, Heavy Machinery, and Housekeeping.
`;

    const geminiResponse = await fetchGeminiWithRetry(
      `https://generativelanguage.googleapis.com/v1beta/models/${modelName}:generateContent?key=${apiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [
            {
              parts: [
                { text: prompt },
                {
                  inlineData: {
                    mimeType,
                    data: imageBase64,
                  },
                },
              ],
            },
          ],
          generationConfig: {
            responseMimeType: "application/json",
            responseSchema: hazardResponseSchema,
            temperature: 0.2,
            topK: 32,
            topP: 1,
            maxOutputTokens: 2048,
          },
        }),
      },
    );

    const geminiJson = await geminiResponse.json();
    if (!geminiResponse.ok) {
      return jsonResponse(
        {
          error: "Gemini request failed.",
          detail: geminiJson?.error?.message ?? geminiJson,
        },
        502,
      );
    }

    const text = geminiJson?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (typeof text !== "string" || text.trim().length === 0) {
      return jsonResponse({ error: "Gemini returned an empty response." }, 502);
    }

    const result = await parseAiJsonWithRepair(text, apiKey);
    validateResult(result);

    return jsonResponse(result, 200);
  } catch (error) {
    return jsonResponse(
      { error: "Hazard analysis failed.", detail: String(error?.message ?? error) },
      500,
    );
  }
});

async function parseAiJsonWithRepair(rawText: string, apiKey: string) {
  try {
    return parseAiJson(rawText);
  } catch (firstError) {
    const repairPrompt = `
Repair the following malformed JSON into valid JSON only.
Return exactly one JSON object matching this schema:
{
  "hazards": [
    {
      "category": "string",
      "description": "string",
      "severity": "Critical|High|Medium|Low",
      "action": "string"
    }
  ],
  "summary": "string"
}

Rules:
- Preserve the meaning of the original text.
- Do not add markdown.
- Do not include trailing commas.
- If a field is missing, use an empty string.

Malformed JSON:
${rawText}
`;

    const repairResponse = await fetchGeminiWithRetry(
      `https://generativelanguage.googleapis.com/v1beta/models/${modelName}:generateContent?key=${apiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [{ parts: [{ text: repairPrompt }] }],
          generationConfig: {
            responseMimeType: "application/json",
            responseSchema: hazardResponseSchema,
            temperature: 0,
            maxOutputTokens: 2048,
          },
        }),
      },
    );

    const repairJson = await repairResponse.json();
    if (!repairResponse.ok) {
      throw firstError;
    }

    const repairedText =
      repairJson?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (typeof repairedText !== "string" || repairedText.trim().length === 0) {
      throw firstError;
    }

    try {
      return parseAiJson(repairedText);
    } catch {
      throw firstError;
    }
  }
}

function parseAiJson(rawText: string) {
  const cleaned = rawText
    .replaceAll("```json", "")
    .replaceAll("```", "")
    .trim();

  const jsonStart = cleaned.indexOf("{");
  const jsonEnd = cleaned.lastIndexOf("}");
  if (jsonStart === -1 || jsonEnd === -1 || jsonEnd <= jsonStart) {
    throw new Error("AI response did not contain a JSON object.");
  }

  const jsonText = cleaned
    .slice(jsonStart, jsonEnd + 1)
    .replace(/,\s*([}\]])/g, "$1");

  return JSON.parse(jsonText);
}

function validateResult(result: unknown) {
  if (!result || typeof result !== "object") {
    throw new Error("Invalid AI response.");
  }
  const data = result as Record<string, unknown>;
  if (!Array.isArray(data.hazards)) {
    throw new Error("AI response is missing hazards array.");
  }
  if (typeof data.summary !== "string") {
    throw new Error("AI response is missing summary.");
  }
}


async function fetchGeminiWithRetry(
  url: string,
  options: RequestInit,
): Promise<Response> {
  const maxAttempts = 3;
  const retryableStatuses = [408, 429, 500, 502, 503, 504];

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const response = await fetch(url, options);

      if (
        response.ok ||
        !retryableStatuses.includes(response.status) ||
        attempt === maxAttempts
      ) {
        return response;
      }

      const waitMs = 1000 * Math.pow(2, attempt - 1);

      console.log(
        `Gemini temporary failure ${response.status}. ` +
        `Retrying after ${waitMs}ms (${attempt}/${maxAttempts})`,
      );

      await new Promise((resolve) => setTimeout(resolve, waitMs));
    } catch (error) {
      if (attempt === maxAttempts) {
        throw error;
      }

      const waitMs = 1000 * Math.pow(2, attempt - 1);

      console.log(
        `Gemini network error. Retrying after ${waitMs}ms ` +
        `(${attempt}/${maxAttempts})`,
      );

      await new Promise((resolve) => setTimeout(resolve, waitMs));
    }
  }

  throw new Error("Gemini request failed after retries.");
}

function jsonResponse(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}
