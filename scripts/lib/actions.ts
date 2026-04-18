import fs from 'node:fs/promises';
import path from 'pathe';
import { rimraf } from 'rimraf';
import picocolors from 'picocolors';

export const getApiConfig = () => {
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
export async function markAsReadInFolo(entryIds: string[], state: any) {
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

export async function markLocallyRead(entryIds: string[]) {
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

export async function deleteArticleFolders(entryIds: string[]) {
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
