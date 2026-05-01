// Mark rejected articles as read in Folo
const fs = require('fs');
const path = require('path');

const env = fs.readFileSync('.env.export', 'utf-8');
const token = env.match(/FOLO_SESSION_TOKEN=(.+)/)[1].trim();
const clientId = env.match(/FOLO_CLIENT_ID=(.+)/)[1].trim();
const sessionId = env.match(/FOLO_SESSION_ID=(.+)/)[1].trim();
const deleteIds = JSON.parse(fs.readFileSync('/tmp/delete_ids.json', 'utf-8'));

const headers = {
  'Content-Type': 'application/json',
  'Cookie': `__Secure-better-auth.session_token=${token}; better-auth.last_used_login_method=google`,
  'Origin': 'https://app.folo.is',
  'Accept': 'application/json',
  'X-Client-Id': clientId,
  'X-Session-Id': sessionId,
  'User-Agent': 'Mozilla/5.0',
};

async function markRead(ids) {
  const res = await fetch('https://api.folo.is/reads', {
    method: 'POST',
    headers,
    body: JSON.stringify({ entryIds: ids }),
  });
  const text = await res.text();
  return { status: res.status, body: text.substring(0, 200) };
}

(async () => {
  const batchSize = 50;
  let success = 0;
  let fail = 0;

  for (let i = 0; i < deleteIds.length; i += batchSize) {
    const batch = deleteIds.slice(i, i + batchSize);
    try {
      const result = await markRead(batch);
      if (result.status === 200) {
        success += batch.length;
        console.log(`Batch ${Math.floor(i/batchSize)+1}/${Math.ceil(deleteIds.length/batchSize)}: OK (${batch.length} entries)`);
      } else {
        fail += batch.length;
        console.log(`Batch ${Math.floor(i/batchSize)+1}: FAIL ${result.status} ${result.body}`);
      }
    } catch(e) {
      fail += batch.length;
      console.log(`Batch ${Math.floor(i/batchSize)+1}: ERROR ${e.message}`);
    }
  }

  console.log(`\nDone: ${success} marked read, ${fail} failed`);
})();
