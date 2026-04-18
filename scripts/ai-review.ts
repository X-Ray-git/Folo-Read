import fs from 'node:fs/promises';
import path from 'pathe';
import { rimraf } from 'rimraf';
import { glob } from 'glob';
import { intro, outro, multiselect, isCancel, spinner, confirm } from '@clack/prompts';
import picocolors from 'picocolors';
import { loadState, saveState, ArticleState } from './lib/state-manager.js';
import { markAsReadInFolo, markLocallyRead, deleteArticleFolders } from './lib/actions.js';

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

async function main() {
  await initEnv();
  intro(picocolors.bgCyan(picocolors.black(' Folo AI Reviewer ')));

  const state = await loadState();
  
  const analyzedEntries = Object.entries(state)
    .filter(([_, data]: [string, ArticleState]) => data.status === 'analyzed')
    .map(([id, data]: [string, ArticleState]) => ({ id, ...data }));

  let entriesToShow = analyzedEntries.filter(e => e.should_reject);
  const autoKeptEntries = analyzedEntries.filter(e => !e.should_reject);

  // Auto keep good articles that we haven't touched yet
  let autoKeptHandled = false;
  if (autoKeptEntries.length > 0) {
    for (const e of autoKeptEntries) {
      if (state[e.id]) state[e.id].status = 'kept';
    }
    await saveState(state);
    autoKeptHandled = true;
  }

  if (entriesToShow.length === 0) {
    if (autoKeptHandled) {
      outro(picocolors.green(`🎉 AI 没有拦截任何垃圾！已在幕后悄悄放行剩余的 ${autoKeptEntries.length} 篇优选文章。`));
    } else {
      outro(picocolors.green('🎉 所有文章均已审查完毕！没有剩余的待确认新闻。'));
    }
    return;
  }

  console.log(picocolors.cyan(`在分析的文章中，有 ${entriesToShow.length} 篇疑似垃圾资讯需要人工复核。`));
  if (autoKeptHandled) {
    console.log(picocolors.green(`（已在幕后悄悄放行未被拦截的 ${autoKeptEntries.length} 篇优选文章）`));
  }

  const BATCH_SIZE = 20;
  let batchIndex = 1;
  let totalSavedRescueCount = 0;

  while (entriesToShow.length > 0) {
    const currentBatch = entriesToShow.slice(0, BATCH_SIZE);
    
    // Hot-patch missing URLs or Local URLs to Public URLs on the fly for the current batch
    for (const item of currentBatch) {
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
    const options = currentBatch.map((item) => {
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

    const initialValues = currentBatch.map(item => item.id);

    console.log(picocolors.cyan(`\n📦 第 ${batchIndex} 批 (共 ${currentBatch.length} 篇，剩余 ${entriesToShow.length - currentBatch.length} 篇)`));
    console.log(picocolors.gray(`列表中展示【被 AI 建议拦截】的内容。按 Space(空格) 取消勾选可挽回放行。`));

    const selectedToReject = await multiselect({
      message: '请审查这一批被拦截的新闻，回车提交：',
      options,
      initialValues,
      required: false,
      maxItems: 15
    });

    if (isCancel(selectedToReject)) {
      outro(picocolors.gray('👋 人工放弃审查。剩余进度已保留，下次启动 TUI 时它们仍会出现在这里。'));
      process.exit(0);
    }

    const rejectedIds = selectedToReject as string[];
    const rescuedIds = currentBatch.map(e => e.id).filter(id => !rejectedIds.includes(id));
    totalSavedRescueCount += rescuedIds.length;

    // Change state (the Atomic Save)
    for (const id of rejectedIds) {
      if (state[id]) state[id].status = 'rejected';
    }
    for (const id of rescuedIds) {
      if (state[id]) state[id].status = 'kept';
    }
    await saveState(state);

    const s = spinner();

    if (rejectedIds.length > 0) {
      s.start(`正在清理本批次 ${rejectedIds.length} 篇垃圾文章，并向 Folo 云端推送已读...`);
      await deleteArticleFolders(rejectedIds);
      await markLocallyRead(rejectedIds);
      await markAsReadInFolo(rejectedIds, state);
      s.stop(`🗑️ 成功清理这批垃圾文章。`);
    }

    if (rescuedIds.length > 0) {
      console.log(picocolors.green(`✨ 你在这批中挽回了 ${rescuedIds.length} 篇文章。`));
    }

    // Remove processed items from the queue
    entriesToShow = entriesToShow.slice(BATCH_SIZE);
    batchIndex++;

    if (entriesToShow.length > 0) {
      const shouldContinue = await confirm({
        message: `本批处理完毕。还有 ${entriesToShow.length} 篇待复核，是否继续？`,
        initialValue: true,
      });
      if (isCancel(shouldContinue) || !shouldContinue) {
         outro(picocolors.gray('👋 已暂停审查。剩余文章已保存，下次可继续处理。'));
         process.exit(0);
      }
    }
  }

  outro(picocolors.cyan(`自动化审查流水线执行完毕。本次共人工挽回 ${totalSavedRescueCount} 篇文章。`));
}

main().catch(console.error);
