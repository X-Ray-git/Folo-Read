#!/usr/bin/env tsx

/**
 * Folo-Read Unified Pipeline
 * 
 * A modular pipeline that orchestrates multiple stages:
 * - export: Fetch unread articles from Folo cloud
 * - analyze: AI-powered content filtering
 * - review: Interactive TUI for human confirmation
 * - (future) translate: Translation stage
 * - (future) summarize: Summarization stage
 * 
 * Usage:
 *   pnpm run pipeline              # Run all default stages
 *   pnpm run pipeline -- --only export,analyze
 *   pnpm run pipeline -- --skip review
 */

import { spawn } from 'node:child_process';
import path from 'pathe';
import picocolors from 'picocolors';
import { intro, outro, confirm, isCancel } from '@clack/prompts';

// ============================================
// Stage Definition Interface
// ============================================

interface PipelineStage {
  id: string;
  name: string;
  description: string;
  /** The script file to execute (relative to scripts/) */
  script: string;
  /** Whether this stage is enabled by default */
  enabled: boolean;
  /** Whether this stage requires TTY (interactive) */
  interactive?: boolean;
}

// ============================================
// Stage Registry - Add new stages here
// ============================================

const STAGES: PipelineStage[] = [
  {
    id: 'export',
    name: '📥 拉取文章',
    description: '从 Folo 云端同步未读文章',
    script: 'export-unread-articles-api.ts',
    enabled: true,
  },
  {
    id: 'dedup',
    name: '🔍 去重检测',
    description: '检测相似/重复内容',
    script: 'ai-dedup.ts',
    enabled: true,
  },
  {
    id: 'analyze',
    name: '🤖 AI 分析',
    description: '使用大模型判定垃圾/优质内容',
    script: 'ai-analyze.ts',
    enabled: true,
  },
  {
    id: 'review',
    name: '👀 人工审核',
    description: '交互式确认被拦截的文章',
    script: 'ai-review.ts',
    enabled: true,
    interactive: true,
  },
  // ============================================
  // Future stages - uncomment when ready
  // ============================================
  // {
  //   id: 'translate',
  //   name: '🌐 翻译',
  //   description: '翻译外文文章为中文',
  //   script: 'ai-translate.ts',
  //   enabled: false,
  // },
  // {
  //   id: 'summarize',
  //   name: '📝 摘要',
  //   description: '生成文章摘要',
  //   script: 'ai-summarize.ts',
  //   enabled: false,
  // },
];

// ============================================
// CLI Argument Parsing
// ============================================

function parseArgs(): { only?: string[]; skip?: string[]; yes?: boolean } {
  const args = process.argv.slice(2);
  const result: { only?: string[]; skip?: string[]; yes?: boolean } = {};

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--only' && args[i + 1]) {
      result.only = args[++i].split(',').map(s => s.trim());
    } else if (arg === '--skip' && args[i + 1]) {
      result.skip = args[++i].split(',').map(s => s.trim());
    } else if (arg === '-y' || arg === '--yes') {
      result.yes = true;
    }
  }

  return result;
}

// ============================================
// Stage Execution
// ============================================

function runStage(stage: PipelineStage): Promise<{ success: boolean; duration: number }> {
  return new Promise((resolve) => {
    const startTime = Date.now();
    const scriptPath = path.join(process.cwd(), 'scripts', stage.script);

    const child = spawn('npx', ['tsx', scriptPath], {
      cwd: process.cwd(),
      stdio: 'inherit',
      shell: true,
    });

    child.on('close', (code) => {
      const duration = Date.now() - startTime;
      resolve({ success: code === 0, duration });
    });

    child.on('error', () => {
      const duration = Date.now() - startTime;
      resolve({ success: false, duration });
    });
  });
}

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60000)}m ${Math.round((ms % 60000) / 1000)}s`;
}

// ============================================
// Main Pipeline
// ============================================

async function main() {
  const args = parseArgs();

  // Determine which stages to run
  let stagesToRun = STAGES.filter(s => s.enabled);

  if (args.only) {
    stagesToRun = stagesToRun.filter(s => args.only!.includes(s.id));
  }

  if (args.skip) {
    stagesToRun = stagesToRun.filter(s => !args.skip!.includes(s.id));
  }

  if (stagesToRun.length === 0) {
    console.log(picocolors.red('❌ 没有可运行的阶段。请检查 --only 或 --skip 参数。'));
    process.exit(1);
  }

  // Show intro
  intro(picocolors.bgMagenta(picocolors.white(' Folo-Read Pipeline ')));

  console.log(picocolors.cyan('\n📋 即将执行以下阶段：'));
  for (const stage of stagesToRun) {
    console.log(`   ${stage.name} - ${picocolors.gray(stage.description)}`);
  }
  console.log();

  // Confirm before running (unless -y flag)
  if (!args.yes) {
    const shouldContinue = await confirm({
      message: '开始执行？',
      initialValue: true,
    });

    if (isCancel(shouldContinue) || !shouldContinue) {
      outro(picocolors.gray('👋 已取消'));
      process.exit(0);
    }
  }

  // Execute stages sequentially
  const results: Array<{ stage: PipelineStage; success: boolean; duration: number }> = [];
  let allSuccess = true;

  for (const stage of stagesToRun) {
    console.log(picocolors.cyan(`\n${'─'.repeat(50)}`));
    console.log(picocolors.bold(`${stage.name}`));
    console.log(picocolors.gray(stage.description));
    console.log(picocolors.cyan('─'.repeat(50)));

    const result = await runStage(stage);
    results.push({ stage, ...result });

    if (!result.success) {
      allSuccess = false;
      console.log(picocolors.red(`\n❌ ${stage.name} 执行失败`));

      // Ask whether to continue on failure (for non-interactive stages)
      if (!stage.interactive && stagesToRun.indexOf(stage) < stagesToRun.length - 1) {
        const shouldContinue = await confirm({
          message: '是否继续执行后续阶段？',
          initialValue: false,
        });

        if (isCancel(shouldContinue) || !shouldContinue) {
          break;
        }
      } else {
        break;
      }
    } else {
      console.log(picocolors.green(`\n✅ ${stage.name} 完成 (${formatDuration(result.duration)})`));
    }
  }

  // Summary
  console.log(picocolors.cyan(`\n${'═'.repeat(50)}`));
  console.log(picocolors.bold('📊 执行摘要'));
  console.log(picocolors.cyan('═'.repeat(50)));

  for (const r of results) {
    const icon = r.success ? picocolors.green('✓') : picocolors.red('✗');
    const time = picocolors.gray(`(${formatDuration(r.duration)})`);
    console.log(`  ${icon} ${r.stage.name} ${time}`);
  }

  const totalDuration = results.reduce((sum, r) => sum + r.duration, 0);
  console.log(picocolors.gray(`\n  总耗时: ${formatDuration(totalDuration)}`));

  if (allSuccess) {
    outro(picocolors.green('🎉 Pipeline 执行完成！'));
  } else {
    outro(picocolors.yellow('⚠️ Pipeline 执行完成，但部分阶段失败'));
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(picocolors.red('Pipeline Error:'), err);
  process.exit(1);
});
