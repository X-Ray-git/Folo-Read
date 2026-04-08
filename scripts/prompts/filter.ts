import fs from 'node:fs';
import path from 'pathe';
import YAML from 'yaml';

interface PromptConfig {
  filter: {
    system: string;
  };
}

let _config: PromptConfig | null = null;

function loadPromptConfig(): PromptConfig {
  if (_config) return _config;
  const configPath = path.join(process.cwd(), 'prompts.yaml');
  const raw = fs.readFileSync(configPath, 'utf-8');
  _config = YAML.parse(raw) as PromptConfig;
  return _config;
}

export function getFilterSystemPrompt(): string {
  return loadPromptConfig().filter.system;
}

export const buildUserPrompt = (title: string, content: string) => {
  return `请针对以下文章的内容特征，返回要求的 JSON 判定结果：
【文章标题】：${title}
【内容截取】：
${content}
`;
};
