# Folo-Read

一个基于 AI 的 RSS 信息流智能审查自动化 CLI 平台。

从 [Folo](https://follow.is) 云端拉取未读文章，利用大语言模型自动过滤不相关内容，通过交互式终端进行人工复审，并将处理结果同步回云端 —— 让你的阅读列表只保留真正值得关注的内容。

## ✨ 功能特性

- **📥 云端同步**：通过 Folo API 自动拉取 Feeds / Inbox / Social 三类未读内容，下载文章 HTML 与图片到本地
- **🔍 智能去重**：基于 Jaccard n-gram 相似度检测重复文章，交互式选择保留版本
- **🤖 AI 过滤**：调用大模型（SiliconFlow）批量并行分析文章相关性，自动建议过滤非目标领域内容
- **👀 人工复审**：交互式 TUI 审批界面，可逐条复核 AI 判定，挽回误拦文章
- **☁️ 双向同步**：确认后自动删除本地垃圾文件，同时向 Folo 云端推送已读状态

## 🚀 快速开始

### 前置要求

- [Node.js](https://nodejs.org/) >= 18
- [pnpm](https://pnpm.io/) 包管理器

### 安装

```bash
git clone https://github.com/YOUR_USERNAME/Folo-Read.git
cd Folo-Read
pnpm install
```

### 配置

复制环境变量模板并填入你的配置：

```bash
cp .env.export.example .env.export
```

需要填写的关键配置：

| 变量 | 说明 | 获取方式 |
|------|------|---------|
| `FOLO_SESSION_TOKEN` | Folo 认证 Token | 登录 [Folo Web](https://app.follow.is)，从浏览器 Cookie 中提取 `__Secure-better-auth.session_token` 的值 |
| `AI_API_KEY` | SiliconFlow API Key | 注册 [SiliconFlow](https://siliconflow.cn) 获取 |

### 运行

```bash
# 一键执行完整流水线（推荐）
pnpm run pipeline

# 或单独运行各阶段
pnpm run export:unread   # 仅拉取文章
pnpm run dedup            # 仅去重
pnpm run analyze          # 仅 AI 分析
pnpm run review           # 仅人工审核
```

流水线支持灵活控制：

```bash
# 仅运行指定阶段
pnpm run pipeline -- --only export,analyze

# 跳过某些阶段
pnpm run pipeline -- --skip review

# 跳过确认直接执行
pnpm run pipeline -- -y
```

## 📐 架构与流水线

```
📥 Export ──→ 🔍 Dedup ──→ 🤖 Analyze ──→ 👀 Review
   │              │             │              │
   │              │             │              ├─ 人工确认拦截 → 删除本地 + 云端标记已读
   │              │             │              └─ 挽回放行 → 标记为 kept
   │              │             └─ LLM 判定 should_reject → pipeline-state.json
   │              └─ Jaccard 相似度检测 → 标记重复
   └─ Folo API 拉取 → unread-articles/{feeds,inbox,social}/
```

### 核心脚本

| 脚本 | 说明 |
|------|------|
| `scripts/pipeline.ts` | 流水线编排器，串行调度各阶段 |
| `scripts/export-unread-articles-api.ts` | 从 Folo 云端拉取未读文章，下载 HTML 和图片 |
| `scripts/ai-dedup.ts` | 文章去重检测（Jaccard / 可扩展为 Embedding） |
| `scripts/ai-analyze.ts` | AI 大批量并行审核，判定文章是否应过滤 |
| `scripts/ai-review.ts` | 交互式 TUI，人工确认被拦截文章 |

### 工具库

| 模块 | 说明 |
|------|------|
| `scripts/lib/llm.ts` | LLM API 调用封装，p-limit 控制并发 |
| `scripts/lib/state-manager.ts` | 文章状态机管理（`pipeline-state.json`） |
| `scripts/lib/similarity.ts` | 可插拔的相似度策略（Jaccard / Embedding 预留） |
| `scripts/prompts/filter.ts` | 过滤 Prompt 加载器 |

### 状态流转

每篇文章在 `pipeline-state.json` 中以 18 位雪花 ID 为键，经历以下状态流转：

```
pending → analyzed → kept / rejected
```

## ⚙️ 配置说明

所有配置通过 `.env.export` 文件管理：

```ini
# Folo 连接
FOLO_SESSION_TOKEN=...     # 认证 Token
FOLO_API_URL=...           # API 地址（默认 https://api.follow.is）
FOLO_OUTPUT_DIR=...        # 输出目录（默认 ./unread-articles）
FOLO_LIMIT=100             # 每页文章数
FOLO_CONCURRENCY=16        # 下载并发数

# AI 模型
AI_API_URL=...             # LLM API 地址
AI_API_KEY=...             # LLM API Key
AI_MODEL=...               # 模型名称

# 去重
DEDUP_STRATEGY=jaccard     # 策略：jaccard / embedding（预留）
DEDUP_THRESHOLD=0.7        # 相似度阈值
DEDUP_NGRAM_SIZE=2         # n-gram 大小
```

过滤 Prompt 在 `prompts.yaml` 中配置，可根据个人阅读偏好调调整。

## 📁 项目结构

```
Folo-Read/
├── scripts/
│   ├── pipeline.ts                   # 流水线编排器
│   ├── export-unread-articles-api.ts # 文章拉取
│   ├── ai-dedup.ts                   # 去重检测
│   ├── ai-analyze.ts                 # AI 分析
│   ├── ai-review.ts                  # 人工审核
│   ├── lib/
│   │   ├── llm.ts                    # LLM 封装
│   │   ├── state-manager.ts          # 状态管理
│   │   └── similarity.ts             # 相似度策略
│   └── prompts/
│       └── filter.ts                 # Prompt 加载
├── prompts.yaml                      # 过滤 Prompt 配置
├── .env.export.example               # 环境变量模板
├── package.json
├── tsconfig.json
└── unread-articles/                  # 运行时数据（不入库）
    ├── feeds/                        # RSS 订阅文章
    ├── inbox/                        # 邮件推送
    ├── social/                       # 社交媒体
    ├── pipeline-state.json           # 状态机
    └── read-entries.json             # 本地已读缓存
```

## ⚠️ 注意事项

- **Entry ID**：所有业务流转必须使用从 HTML `<meta name="folo-entry-id">` 中提取的 **18 位雪花 ID**，切勿使用文件夹名（其中的 ID 是截断的 8 位）
- **`read-entries.json` 格式**：文件外层必须保持 `{"entries": {...}}` 结构，官方 SDK 在加载时执行 `Object.keys(readStatus.entries)`
- **云端标记已读**：正确的路径是 `POST /reads`，传送 `{ "entryIds": string[], "isInbox": boolean }`，不要使用 `/reads/markAsRead`
- **Token 时效**：Folo Session Token 可能会过期，如遇到 401/403 错误请重新从浏览器获取

## 🗺️ Roadmap

- [ ] 语义向量去重（Embedding 相似度替代 Jaccard）
- [ ] 自动化 Cron 守护进程
- [ ] 翻译阶段（自动翻译外文文章）
- [ ] 摘要阶段（生成文章摘要）

## 📄 License

MIT
