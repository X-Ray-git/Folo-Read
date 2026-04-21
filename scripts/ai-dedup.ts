#!/usr/bin/env tsx

/**
 * AI Deduplication Script
 * 
 * Detects similar/duplicate articles using configurable similarity strategies.
 * Presents duplicate groups to user for selection of which to keep.
 * 
 * Usage:
 *   pnpm run dedup
 */

import fs from 'node:fs/promises';
import path from 'pathe';
import { glob } from 'glob';
import picocolors from 'picocolors';
import { intro, outro, multiselect, isCancel } from '@clack/prompts';
import { loadState, updateArticleState } from './lib/state-manager.js';
import { createSimilarityStrategy, SimilarityConfig } from './lib/similarity.js';
import { markAsReadInFolo, markLocallyRead, deleteArticleFolders } from './lib/actions.js';

// ============================================
// Configuration
// ============================================

function loadEnv() {
  try {
    const envPath = path.join(process.cwd(), '.env.export');
    const content = require('fs').readFileSync(envPath, 'utf-8');
    for (const line of content.split('\n')) {
      const match = line.match(/^([^#\s=]+)=(.*)$/);
      if (match) process.env[match[1]] = match[2].trim();
    }
  } catch {}
}

loadEnv();

const DEDUP_CONFIG: SimilarityConfig = {
  strategy: (process.env.DEDUP_STRATEGY as 'jaccard' | 'embedding') || 'jaccard',
  threshold: parseFloat(process.env.DEDUP_THRESHOLD || '0.85'),
  options: {
    ngramSize: parseInt(process.env.DEDUP_NGRAM_SIZE || '2', 10),
  },
};

// ============================================
// Text Extraction
// ============================================

async function extractTextFromHtml(htmlPath: string): Promise<string> {
  const html = await fs.readFile(htmlPath, 'utf-8');
  
  // Remove head, style, script tags
  let text = html.replace(/<head>[\s\S]*?<\/head>/i, '');
  text = text.replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '');
  text = text.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '');
  text = text.replace(/<[^>]+>/g, ' ');
  text = text.replace(/\s+/g, ' ').trim();
  
  return text;
}

async function extractEntryId(htmlPath: string): Promise<string | null> {
  try {
    const html = await fs.readFile(htmlPath, 'utf-8');
    const match = html.match(/<meta\s+name="folo-entry-id"\s+content="(\d+)"/i);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

async function extractUrl(htmlPath: string): Promise<string | null> {
  try {
    const html = await fs.readFile(htmlPath, 'utf-8');
    const match = html.match(/<span class="meta-label">原文链接：<\/span>\s*<a href="([^"]+)"/i);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

// ============================================
// Main Deduplication Logic
// ============================================

interface ArticleInfo {
  id: string;
  dir: string;
  title: string;
  text: string;
  url?: string;
  category: string;
}

// Union-Find for grouping similar articles
class UnionFind {
  private parent: Map<string, string> = new Map();
  
  find(x: string): string {
    if (!this.parent.has(x)) {
      this.parent.set(x, x);
    }
    if (this.parent.get(x) !== x) {
      this.parent.set(x, this.find(this.parent.get(x)!));
    }
    return this.parent.get(x)!;
  }
  
  union(x: string, y: string): void {
    const px = this.find(x);
    const py = this.find(y);
    if (px !== py) {
      this.parent.set(px, py);
    }
  }
  
  getGroups(): Map<string, string[]> {
    const groups = new Map<string, string[]>();
    for (const id of this.parent.keys()) {
      const root = this.find(id);
      if (!groups.has(root)) {
        groups.set(root, []);
      }
      groups.get(root)!.push(id);
    }
    return groups;
  }
}

async function main() {
  intro(picocolors.bgYellow(picocolors.black(' 🔍 Folo 去重检测 ')));
  
  console.log(picocolors.gray(`   策略: ${DEDUP_CONFIG.strategy}`));
  console.log(picocolors.gray(`   阈值: ${DEDUP_CONFIG.threshold}`));
  
  const baseDir = path.join(process.cwd(), 'unread-articles');
  const state = await loadState();
  
  // Find all article directories
  const dirs = await glob(['feeds/*', 'social/*', 'inbox/*'], { cwd: baseDir, absolute: true });
  
  // Load all articles that haven't been rejected or marked as duplicate
  const articles: ArticleInfo[] = [];
  const articleMap = new Map<string, ArticleInfo>();
  
  for (const dir of dirs) {
    const stat = await fs.stat(dir);
    if (!stat.isDirectory()) continue;
    
    const htmlPath = path.join(dir, 'index.html');
    const entryId = await extractEntryId(htmlPath);
    if (!entryId) continue;
    
    const articleState = state[entryId];
    
    // Skip already rejected or duplicate articles
    if (articleState?.status === 'rejected' || articleState?.duplicate_of) {
      continue;
    }
    
    try {
      const text = await extractTextFromHtml(htmlPath);
      const url = await extractUrl(htmlPath);
      const category = path.basename(path.dirname(dir));
      
      // Extract title from HTML
      const html = await fs.readFile(htmlPath, 'utf-8');
      const titleMatch = html.match(/<title>(.*?)<\/title>/i);
      const title = titleMatch ? titleMatch[1].trim() : path.basename(dir);
      
      const article: ArticleInfo = {
        id: entryId,
        dir,
        title,
        text,
        url: url || undefined,
        category,
      };
      
      articles.push(article);
      articleMap.set(entryId, article);
    } catch {
      continue;
    }
  }
  
  if (articles.length < 2) {
    outro(picocolors.green('✅ 文章数量不足，无需去重'));
    return;
  }
  
  console.log(picocolors.gray(`   正在比较 ${articles.length} 篇文章...\n`));
  
  // Create similarity strategy
  const strategy = createSimilarityStrategy(DEDUP_CONFIG);
  
  // Use Union-Find to group all similar articles together
  const uf = new UnionFind();
  
  for (let i = 0; i < articles.length; i++) {
    const a = articles[i];
    uf.find(a.id); // Initialize
    
    for (let j = i + 1; j < articles.length; j++) {
      const b = articles[j];
      const score = strategy.computeSimilarity(a.text, b.text);
      
      if (score >= DEDUP_CONFIG.threshold) {
        uf.union(a.id, b.id);
      }
    }
  }
  
  // Get duplicate groups (only groups with more than 1 article)
  const allGroups = uf.getGroups();
  const duplicateGroups: ArticleInfo[][] = [];
  
  for (const [, ids] of allGroups) {
    if (ids.length > 1) {
      const group = ids.map(id => articleMap.get(id)!).filter(Boolean);
      if (group.length > 1) {
        duplicateGroups.push(group);
      }
    }
  }
  
  if (duplicateGroups.length === 0) {
    outro(picocolors.green('✅ 未发现重复文章'));
    return;
  }
  
  console.log(picocolors.yellow(`\n⚠️  发现 ${duplicateGroups.length} 组重复文章\n`));
  
  // Process each duplicate group
  let totalDuplicates = 0;
  
  for (let i = 0; i < duplicateGroups.length; i++) {
    const group = duplicateGroups[i];
    
    console.log(picocolors.cyan(`\n${'─'.repeat(50)}`));
    console.log(picocolors.bold(`📋 重复组 ${i + 1}/${duplicateGroups.length} (${group.length} 篇)`));
    console.log(picocolors.cyan('─'.repeat(50)));
    
    // Build options for selection
    const options = group.map((article, idx) => {
      const truncTitle = article.title.length > 60 
        ? article.title.substring(0, 57) + '...' 
        : article.title;
      const urlHint = article.url ? picocolors.gray(` 🔗 ${article.url.substring(0, 40)}...`) : '';
      
      return {
        value: article.id,
        label: `${picocolors.dim(`[${article.category}]`)} ${truncTitle}${urlHint}`,
      };
    });
    
    // Auto-select the first article as default, but allow user to select 0, 1, or multiple
    const initialValues = [group[0].id];

    const selected = await multiselect({
      message: '请选择要保留的文章 (按空格多选，未选中的将被直接标记为已读并丢弃)：',
      options,
      initialValues,
      required: false,
    });
    
    if (isCancel(selected)) {
      outro(picocolors.gray('👋 已取消去重操作'));
      process.exit(0);
    }
    
    const keepIds = selected as string[];
    const rejectedIds: string[] = [];

    // Provide a reference title for the duplicate marker if there are any selected
    const referenceTitle = keepIds.length > 0
      ? articleMap.get(keepIds[0])!.title.substring(0, 20) + '...'
      : '同组其他文章';
    const keepIdForDupe = keepIds.length > 0 ? keepIds[0] : undefined;
    
    for (const article of group) {
      if (!keepIds.includes(article.id)) {
        await updateArticleState(article.id, {
          status: 'rejected', // mark directly as rejected so it skips AI review
          should_reject: true,
          reject_reason: '重复内容',
          duplicate_of: keepIdForDupe,
          title: article.title,
          summary: `与「${referenceTitle}」重复`,
          url: article.url,
          category: article.category,
        });
        rejectedIds.push(article.id);
        totalDuplicates++;
        console.log(picocolors.red(`   ✗ 标记为重复(直接已读): ${article.title.substring(0, 40)}...`));
      } else {
        console.log(picocolors.green(`   ✓ 保留: ${article.title.substring(0, 40)}...`));
      }
    }

    if (rejectedIds.length > 0) {
      const updatedState = await loadState(); // reload to get the latest state
      await deleteArticleFolders(rejectedIds);
      await markLocallyRead(rejectedIds);
      await markAsReadInFolo(rejectedIds, updatedState);
      console.log(picocolors.gray(`   清理完毕，并在 Folo 中标记已读。`));
    }
  }
  
  outro(picocolors.yellow(`\n⚠️  已标记 ${totalDuplicates} 篇重复文章，并自动清理。保留的文章将继续进入分析环节`));
}

main().catch(console.error);
