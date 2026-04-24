import pLimit from 'p-limit';
import fs from 'node:fs';
import path from 'pathe';

function loadEnv() {
  try {
    const envPath = path.join(process.cwd(), '.env.export');
    const content = fs.readFileSync(envPath, 'utf-8');
    const lines = content.split('\n');
    for (const line of lines) {
      const match = line.match(/^([^#\s=]+)=(.*)$/);
      if (match) {
        process.env[match[1]] = match[2].trim();
      }
    }
  } catch (e) {
    // Ignore if not exists
  }
}

// Load env variables dynamically so scripts work universally without prefix commands
loadEnv();

const AI_API_URL = process.env.AI_API_URL || process.env.DEEPSEEK_BASE_URL || 'https://api.deepseek.com';
const AI_API_KEY = process.env.AI_API_KEY || process.env.DEEPSEEK_API_KEY;
const AI_MODEL = process.env.AI_MODEL || process.env.DEEPSEEK_MODEL || 'deepseek-v4-flash';
const THINKING = process.env.LLM_THINKING || process.env.DEEPSEEK_THINKING;
const REASONING_EFFORT = process.env.LLM_REASONING_EFFORT || process.env.DEEPSEEK_REASONING_EFFORT;
const CONCURRENCY = parseInt(process.env.LLM_CONCURRENCY || '64', 10);

// Concurrency limit for calling LLM API
const limit = pLimit(CONCURRENCY);

export interface LLMAnalysisResult {
  language: string;
  should_reject: boolean;
  reject_reason: string | null;
  category: string;
  summary: string;
}

export async function askLLM(systemPrompt: string, userPrompt: string): Promise<LLMAnalysisResult | null> {
  return limit(async () => {
    if (!AI_API_KEY) {
      throw new Error('AI_API_KEY (or DEEPSEEK_API_KEY) is not set in .env.export');
    }

    try {
      const body: Record<string, unknown> = {
        model: AI_MODEL,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userPrompt }
        ],
        response_format: { type: 'json_object' },
        // Keep classification stable (ignored by DeepSeek in thinking mode)
        temperature: 0.1,
      };

      if (THINKING) body.thinking = { type: THINKING };
      if (REASONING_EFFORT) body.reasoning_effort = REASONING_EFFORT;

      const res = await fetch(`${AI_API_URL}/chat/completions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${AI_API_KEY}`,
        },
        body: JSON.stringify(body)
      });

      if (!res.ok) {
        console.error(`[LLM API Error]: ${res.status} ${await res.text()}`);
        return null;
      }

      const data = await res.json();
      const content = data.choices?.[0]?.message?.content;
      if (!content) return null;

      // Ensure robust JSON parsing
      try {
        return JSON.parse(content) as LLMAnalysisResult;
      } catch (e) {
        // Fallback for models that loosely wrap output in markdown codeblocks
        const match = content.match(/```(?:json)?\s*([\s\S]*?)\s*```/);
        if (match) {
          return JSON.parse(match[1]) as LLMAnalysisResult;
        }
        return null;
      }
    } catch (error) {
      console.error(`[Ask LLM Exception]: `, error);
      return null;
    }
  });
}
