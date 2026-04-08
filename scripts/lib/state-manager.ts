import fs from 'node:fs/promises';
import path from 'pathe';

export type PipelineStatus = 'pending' | 'analyzed' | 'kept' | 'rejected' | 'read' | 'translated';

export interface ArticleState {
  status: PipelineStatus;
  language?: string;
  category?: string;
  should_reject?: boolean;
  reject_reason?: string | null;
  summary?: string;
  url?: string;
  title?: string;
}

const STATE_FILE = path.join(process.cwd(), 'unread-articles', 'pipeline-state.json');

// Memory cache for frequent reads
let stateCache: Record<string, ArticleState> | null = null;

export async function loadState(): Promise<Record<string, ArticleState>> {
  if (stateCache) return stateCache;
  try {
    const data = await fs.readFile(STATE_FILE, 'utf-8');
    stateCache = JSON.parse(data);
    return stateCache!;
  } catch (e) {
    stateCache = {};
    return stateCache!;
  }
}

export async function saveState(state: Record<string, ArticleState>): Promise<void> {
  stateCache = state;
  await fs.mkdir(path.dirname(STATE_FILE), { recursive: true });
  await fs.writeFile(STATE_FILE, JSON.stringify(state, null, 2), 'utf-8');
}

export async function getArticleState(entryId: string): Promise<ArticleState> {
  const state = await loadState();
  return state[entryId] || { status: 'pending' };
}

export async function updateArticleState(entryId: string, updates: Partial<ArticleState>): Promise<void> {
  const state = await loadState();
  state[entryId] = { ...(state[entryId] || { status: 'pending' }), ...updates };
  await saveState(state);
}

export async function fetchAllPendingArticles(articlesDirs: string[]): Promise<string[]> {
  const state = await loadState();
  return articlesDirs.filter(dir => {
    // entryId is the part after the last hyphen in the folder name, e.g., xxx-abc12345
    const match = dir.match(/-([a-zA-Z0-9_-]{8,})$/);
    if (!match) return false;
    const entryId = match[1];
    const s = state[entryId];
    return !s || s.status === 'pending';
  });
}
