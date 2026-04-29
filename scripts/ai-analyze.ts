import fs from 'node:fs/promises';
import path from 'pathe';
import { glob } from 'glob';
import { getArticleState, updateArticleState } from './lib/state-manager.js';
import { askLLM } from './lib/llm.js';
import { getFilterSystemPrompt, buildUserPrompt } from './prompts/filter.js';

/**
 * AI Analyzer Script
 * Reads all files from unread-articles that are strictly marked as 'pending'.
 * Sends their first chunk to the SiliconFlow API.
 * Updates the state pipeline as 'analyzed'.
 */
async function main() {
  const baseDir = path.join(process.cwd(), 'unread-articles');

  // Find all article directories in subfolders
  const dirs = await glob(['feeds/*', 'social/*', 'inbox/*'], { cwd: baseDir, absolute: true });
  
  if (!dirs || dirs.length === 0) {
    console.log('No articles found in unread-articles.');
    return;
  }

  const pendingQueue: { id: string; dir: string; category: string }[] = [];

  for (const dir of dirs) {
    const stat = await fs.stat(dir);
    if (!stat.isDirectory()) continue;
    
    const htmlPath = path.join(dir, 'index.html');
    try {
      await fs.access(htmlPath);
    } catch {
      continue;
    }

    // Extract REAL 18-digit snowflake ID from HTML meta tag
    const htmlContent = await fs.readFile(htmlPath, 'utf-8');
    const metaMatch = htmlContent.match(/<meta\s+name="folo-entry-id"\s+content="(\d+)"/i);
    if (!metaMatch) continue;
    
    const entryId = metaMatch[1];
    const categoryFolder = path.basename(path.dirname(dir));
    
    const state = await getArticleState(entryId);
    
    // STRICT Check: Only analyze articles that we have never touched before
    if (state.status === 'pending') {
      pendingQueue.push({ id: entryId, dir, category: categoryFolder });
    }
  }

  if (pendingQueue.length === 0) {
    console.log('✅ No pending articles need analysis. Everything is up-to-date.');
    return;
  }

  console.log(`🤖 Found ${pendingQueue.length} pending articles. Submitting to SiliconFlow...`);

  let completed = 0;
  let failed = 0;

  const promises = pendingQueue.map(async (item) => {
    try {
      const htmlPath = path.join(item.dir, 'index.html');
      const html = await fs.readFile(htmlPath, 'utf-8');

      const titleMatch = html.match(/<title>(.*?)<\/title>/i);
      const title = titleMatch ? titleMatch[1].trim() : 'Unknown Title';
      
      let bodyText = html.replace(/<head>[\s\S]*?<\/head>/i, '');
      bodyText = bodyText.replace(/<style[^>]*>[\s\S]*?<\/style>/ig, '');
      bodyText = bodyText.replace(/<script[^>]*>[\s\S]*?<\/script>/ig, '');
      bodyText = bodyText.replace(/<[^>]+>/g, ' '); // Strip HTML
      bodyText = bodyText.replace(/\s+/g, ' ').trim(); // Normalize spaces
      
      const snippet = bodyText.substring(0, 10000);
      
      const urlMatch = html.match(/<span class="meta-label">原文链接：<\/span>\s*<a href="([^"]+)"/i);
      const originalUrl = urlMatch && urlMatch[1] ? urlMatch[1] : `file://${htmlPath}`;

      const articleState = await getArticleState(item.id);
      const result = await askLLM(getFilterSystemPrompt(), buildUserPrompt(title, snippet, originalUrl, articleState.subscription_category));
      
      if (result) {
        await updateArticleState(item.id, {
          status: 'analyzed',
          language: result.language,
          category: result.category || item.category,
          should_reject: result.should_reject,
          reject_reason: result.reject_reason,
          summary: result.summary,
          title: title,
          url: originalUrl,
        });
        completed++;
      } else {
        failed++;
      }

      process.stdout.write(`\rProgress: [✅ ${completed}] [❌ ${failed}] / ${pendingQueue.length} analyzed...`);
    } catch (e) {
      failed++;
      console.error(`\nFailed to process article in ${item.dir}`, e);
    }
  });

  // Since llm.ts uses p-limit, we can safely Promise.all here
  await Promise.all(promises);
  console.log('\n\n✅ Analysis Complete!');
  console.log('You can now run the ai-review script to interactively decide their fate.');
}

main().catch(console.error);
