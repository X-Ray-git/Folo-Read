import fs from 'node:fs/promises';
import path from 'pathe';
import { rimraf } from 'rimraf';
import { glob } from 'glob';
import { intro, outro, multiselect, isCancel, spinner } from '@clack/prompts';
import picocolors from 'picocolors';
import { loadState, saveState } from './lib/state-manager';

// Ensure .env.export is thoroughly loaded to grab API URLs and Session Token
async function initEnv() {
  try {
    const envPath = path.join(process.cwd(), '.env.export');
    const content = await fs.readFile(envPath, 'utf-8');
    for (const line of content.split('\n')) {
      const match = line.match(/^([^#\s=]+)=(.*)$/);
      if (match && match[1]) process.env[match[1]] = match[2].trim();
    }
  } catch (e) {}
}

const getApiConfig = () => {
  const API_URL = process.env.FOLO_API_URL || 'https://api.follow.is';
  const TOKEN = process.env.FOLO_SESSION_TOKEN;
  const COOKIE_HEADER = API_URL.includes("https")
      ? `__Secure-better-auth.session_token=${decodeURIComponent(TOKEN || '')}`
      : `better-auth.session_token=${decodeURIComponent(TOKEN || '')}`;
  return { API_URL, TOKEN, COOKIE_HEADER };
}

/**
 * Trigger Cloud API 'Mark As Read' to keep cross-device consistency.
 * Best effort: we'll use a commonly structured endpoint based on the standard Folo tRPC.
 */
async function markAsReadInFolo(entryIds: string[], state: any) {
  const { API_URL, COOKIE_HEADER } = getApiConfig();
  if (!COOKIE_HEADER) return;

  const inboxIds = entryIds.filter(id => state[id] && state[id].category === 'inbox');
  const normalIds = entryIds.filter(id => !(state[id] && state[id].category === 'inbox'));

  const sendBatch = async (ids: string[], isInbox: boolean) => {
    for (let i = 0; i < ids.length; i += 50) {
      const batch = ids.slice(i, i + 50);
      try {
        const response = await fetch(`${API_URL}/reads`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Cookie': COOKIE_HEADER,
            'User-Agent': 'Folo-Local-AI-Reviewer/1.0',
          },
          body: JSON.stringify({
            entryIds: batch,
            isInbox
          })
        });
        if (!response.ok) {
          console.error(picocolors.red(`⚠️ Folo API markAsRead failed: ${response.status} ${response.statusText}`));
        }
      } catch (e) {
        console.error(picocolors.red(`⚠️ Network error during markAsRead: ${(e as Error).message}`));
      }
    }
  };

  if (inboxIds.length > 0) await sendBatch(inboxIds, true);
  if (normalIds.length > 0) await sendBatch(normalIds, false);
}

async function markLocallyRead(entryIds: string[]) {
   try {
     const readEntriesPath = path.join(process.cwd(), 'unread-articles', 'read-entries.json');
     let readData: { entries: Record<string, number> } = { entries: {} };
     try {
       const content = await fs.readFile(readEntriesPath, 'utf-8');
       const parsed = JSON.parse(content);
       if (parsed.entries) {
         readData = parsed;
       } else {
         // Migration from older flat format if necessary
         readData.entries = parsed;
       }
     } catch(e) {}
     
     entryIds.forEach(id => {
       readData.entries[id] = Date.now();
     });
     await fs.writeFile(readEntriesPath, JSON.stringify(readData, null, 2), 'utf-8');
   } catch (e) {
     console.log(picocolors.yellow(`\n⚠️ Failed to update local read-entries.json: ${(e as Error).message}`));
   }
}

async function deleteArticleFolders(entryIds: string[]) {
   const baseDir = path.join(process.cwd(), 'unread-articles');
   const dirs = ['feeds', 'social', 'inbox'];
   for (const folder of dirs) {
     const dirPath = path.join(baseDir, folder);
     try {
       const subDirs = await fs.readdir(dirPath);
       for (const subDir of subDirs) {
         const htmlPath = path.join(dirPath, subDir, 'index.html');
         try {
           const html = await fs.readFile(htmlPath, 'utf-8');
           const metaMatch = html.match(/<meta\s+name="folo-entry-id"\s+content="(\d+)"/i);
           if (metaMatch && entryIds.includes(metaMatch[1])) {
             const target = path.join(dirPath, subDir);
             await rimraf(target);
           }
         } catch {}
       }
     } catch (e) {}
   }
}

async function main() {
  await initEnv();
  intro(picocolors.bgCyan(picocolors.black(' Folo AI Reviewer ')));

  const state = await loadState();
  
  const analyzedEntries = Object.entries(state)
    .filter(([_, data]) => data.status === 'analyzed')
    .map(([id, data]) => ({ id, ...data }));

  const entriesToShow = analyzedEntries.filter(e => e.should_reject);
  const autoKeptEntries = analyzedEntries.filter(e => !e.should_reject);

  if (entriesToShow.length === 0) {
    if (autoKeptEntries.length > 0) {
      for (const e of autoKeptEntries) {
        if (state[e.id]) state[e.id].status = 'kept';
      }
      await saveState(state);
      outro(picocolors.green(`🎉 AI 没有拦截任何垃圾！已在幕后悄悄放行剩余的 ${autoKeptEntries.length} 篇优选文章。`));
    } else {
      outro(picocolors.green('🎉 所有文章均已审查完毕！没有剩余的待确认新闻。'));
    }
    return;
  }

  // Hot-patch missing URLs or Local URLs to Public URLs on the fly
  for (const item of entriesToShow) {
    if (!item.url || item.url.startsWith('file://')) {
      try {
        let filePath = item.url ? item.url.replace('file://', '') : '';
        if (!filePath) {
           const matches = await glob(`unread-articles/*/*-${item.id}/index.html`, { cwd: process.cwd(), absolute: true });
           if (matches.length > 0) filePath = matches[0];
        }
        
        if (filePath) {
          const content = await fs.readFile(filePath, 'utf-8');
          const urlMatch = content.match(/<span class="meta-label">原文链接：<\/span>\s*<a href="([^"]+)"/i);
          if (urlMatch && urlMatch[1]) {
            item.url = urlMatch[1];
            if (state[item.id]) state[item.id].url = item.url; // Save for next time
          }
        }
      } catch(e) {}
    }
  }

  // Pre-calculate display options for MultiSelect TUI
  const options = entriesToShow.map((item) => {
    let titleStr = item.title || 'Unknown Title';
    
    // UI Format optimization: Truncate very long titles so Clack layout does not break
    if (titleStr.length > 50) titleStr = titleStr.substring(0, 47) + '...';
    
    const cat = item.category ? picocolors.dim(`[${item.category}] `) : '';
    const reason = item.reject_reason 
       ? picocolors.red(` [拦截: ${item.reject_reason}]`) 
       : picocolors.gray(` [拦截]`);
    const summary = item.summary ? picocolors.cyan(` 📝 ${item.summary}`) : '';
    
    return {
      value: item.id,
      label: `${cat}${titleStr}${reason}${summary}${item.url ? `  🔗 ${picocolors.dim(item.url)}` : ''}`,
      hint: '',
    };
  });

  const initialValues = entriesToShow.map(item => item.id);

  console.log(picocolors.cyan(`在分析的 ${analyzedEntries.length} 篇文章中，有 ${entriesToShow.length} 篇疑似垃圾资讯。`));
  console.log(picocolors.gray(`列表中仅展示【被 AI 建议拦截】的内容。按 Space(空格) 反选可以挽回。其余正常文章将在提交后自动放行。`));
  
  const selectedToReject = await multiselect({
    message: '请审查被拦截的新闻流（可上下滚动），回车提交：',
    options,
    initialValues,
    required: false
  });

  if (isCancel(selectedToReject)) {
    outro(picocolors.gray('👋 人工放弃审查。进度已保留，下次启动 TUI 时它们仍会出现在这里。'));
    process.exit(0);
  }

  const rejectedIds = selectedToReject as string[];
  const rescuedIds = entriesToShow.map(e => e.id).filter(id => !rejectedIds.includes(id));
  const keptIds = [...rescuedIds, ...autoKeptEntries.map(e => e.id)];

  // Change state (the Atomic Save)
  for (const id of rejectedIds) {
    if (state[id]) state[id].status = 'rejected';
  }
  for (const id of keptIds) {
    if (state[id]) state[id].status = 'kept';
  }
  await saveState(state);

  const s = spinner();
  
  if (rejectedIds.length > 0) {
    s.start(`正在清理 ${rejectedIds.length} 篇被拒绝文章，同时向 Folo 云端推送全系已读指令...`);
    await deleteArticleFolders(rejectedIds);
    await markLocallyRead(rejectedIds);
    await markAsReadInFolo(rejectedIds, state);
    s.stop(`🗑️ 成功处理并同步了这批垃圾文章。`);
  }

  if (keptIds.length > 0) {
    console.log(picocolors.green(`✨ 你保留了 ${keptIds.length} 篇优质文章。它们已安全存放于本地并标记为 kept。`));
  }

  outro(picocolors.cyan('自动化审查流水线执行完毕。'));
}

main().catch(console.error);
