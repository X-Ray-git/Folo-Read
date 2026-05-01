#!/usr/bin/env tsx

/**
 * Export Unread Articles from Folo
 * 
 * This script fetches all unread articles from Folo API and saves them as HTML files.
 * Each article is saved in its own folder with downloaded images.
 * 
 * Usage:
 *   # Using config file (recommended)
 *   pnpm run export:unread
 * 
 *   # Using command line
 *   pnpm run export:unread -- --token YOUR_AUTH_TOKEN
 * 
 * Configuration:
 *   Create .env.export file in project root with:
 *   FOLO_SESSION_TOKEN=your_token_here
 *   FOLO_API_URL=https://api.follow.is (optional)
 *   FOLO_OUTPUT_DIR=./unread-articles (optional)
 *   FOLO_LIMIT=100 (optional)
 * 
 * See AUTH_GUIDE.md for how to obtain the authentication token.
 */

import fs from "node:fs"
import path from "pathe"
import { FollowClient } from "@follow-app/client-sdk"
import pLimit from "p-limit"
import cliProgress from "cli-progress"
import { Readability } from "@mozilla/readability"
import { JSDOM } from "jsdom"
import { updateArticleState } from "./lib/state-manager.js"

interface Article {
  id: string
  title: string | null
  url: string | null
  content: string | null
  description: string | null
  author: string | null
  publishedAt: string
  feedId: string | null
  media?: Array<{ url: string; type: string }>
  // Category for organizing into folders
  category?: "feeds" | "inbox" | "social"
}

// Local read status tracking
interface ReadStatusStore {
  // Map of entry ID to timestamp when marked as read
  entries: Record<string, number>
}

const READ_STATUS_FILE = "read-entries.json"

interface Subscription {
  type: "feed" | "inbox" | "list"
  feedId?: string
  inboxId?: string
  listId?: string
  view?: number
}

interface ExportOptions {
  token: string
  outputDir: string
  apiUrl: string
  limit?: number
  concurrency?: number
  clientId?: string
  sessionId?: string
}

class UnreadArticlesExporter {
  private outputDir: string
  private options: ExportOptions
  private readStatusPath: string
  private feedCategoryMap: Map<string, string> = new Map()

  constructor(options: ExportOptions) {
    this.options = options
    this.outputDir = options.outputDir
    this.readStatusPath = path.join(options.outputDir, READ_STATUS_FILE)
  }

  // Load local read status
  private loadReadStatus(): ReadStatusStore {
    try {
      if (fs.existsSync(this.readStatusPath)) {
        const content = fs.readFileSync(this.readStatusPath, "utf-8")
        return JSON.parse(content)
      }
    } catch (e) {
      // Ignore errors, return empty
    }
    return { entries: {} }
  }

  // Save local read status
  private saveReadStatus(store: ReadStatusStore): void {
    fs.writeFileSync(this.readStatusPath, JSON.stringify(store, null, 2), "utf-8")
  }

  // Check if an entry is marked as read locally
  private isLocallyMarkedRead(entryId: string, store: ReadStatusStore): boolean {
    return entryId in store.entries
  }

  // Extract entry ID from existing HTML file
  private extractEntryIdFromHtml(htmlPath: string): string | null {
    try {
      if (!fs.existsSync(htmlPath)) return null
      const content = fs.readFileSync(htmlPath, "utf-8")
      
      // Try HTML comment marker first (new format)
      let match = content.match(/<!-- FOLO_ENTRY_ID:([a-zA-Z0-9_-]+) -->/)
      if (match) return match[1]
      
      // Try meta tag
      match = content.match(/<meta\s+name="folo-entry-id"\s+content="([^"]+)"/)
      if (match) return match[1]
      
      // Try JavaScript const (old format)
      match = content.match(/const\s+ENTRY_ID\s*=\s*"([^"]+)"/)
      if (match) return match[1]
      
      return null
    } catch (e) {
      return null
    }
  }

  private async fetchSubscriptions(): Promise<{ inboxIds: string[], feedViewMap: Map<string, number>, feedCategoryMap: Map<string, string> }> {
    console.log("📋 Fetching subscriptions...")

    const decodedToken = decodeURIComponent(this.options.token)
    const cookieName = this.options.apiUrl.includes("https")
      ? "__Secure-better-auth.session_token"
      : "better-auth.session_token"
    const cookieStr = `${cookieName}=${decodedToken}; better-auth.last_used_login_method=google`

    const feedViewMap = new Map<string, number>()
    const feedCategoryMap = new Map<string, string>()

    // Get feed subscriptions
    const response = await fetch(`${this.options.apiUrl}/subscriptions`, {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
        Cookie: cookieStr,
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
        Accept: "application/json",
        Origin: "https://app.folo.is",
        Referer: "https://app.folo.is",
        "X-App-Platform": "desktop/web",
        "X-App-Name": "Folo Web",
        "X-App-Version": "1.7.0",
        "X-Client-Id": this.options.clientId || "",
        "X-Session-Id": this.options.sessionId || "",
      },
    })

    if (!response.ok) {
      const errorText = await response.text()
      throw new Error(`Failed to fetch subscriptions: HTTP ${response.status}: ${errorText}`)
    }

    const result = await response.json()

    if (result.data && Array.isArray(result.data)) {
      for (const sub of result.data) {
        if (sub.feedId) {
          feedViewMap.set(sub.feedId, sub.view)
          feedCategoryMap.set(sub.feedId, sub.category || 'OTHERS')
        }
      }
    }

    // Get inbox list from /inboxes/list
    const inboxIds: string[] = []
    try {
      const inboxRes = await fetch(`${this.options.apiUrl}/inboxes/list`, {
        method: "GET",
        headers: {
          "Content-Type": "application/json",
          Cookie: cookieStr,
          "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
          Accept: "application/json",
          Origin: "https://app.folo.is",
          Referer: "https://app.folo.is",
          "X-App-Platform": "desktop/web",
          "X-App-Name": "Folo Web",
          "X-App-Version": "1.7.0",
          "X-Client-Id": this.options.clientId || "",
          "X-Session-Id": this.options.sessionId || "",
        },
      })
      if (inboxRes.ok) {
        const inboxData = await inboxRes.json()
        if (inboxData.data && Array.isArray(inboxData.data)) {
          for (const inbox of inboxData.data) {
            inboxIds.push(inbox.id)
          }
        }
      }
    } catch (e) {
      // Ignore inbox list errors
    }

    console.log(`✓ Found ${inboxIds.length} inboxes, ${feedViewMap.size} feed subscriptions`)
    return { inboxIds, feedViewMap, feedCategoryMap }
  }

  private async fetchFeedArticles(feedViewMap: Map<string, number>): Promise<Article[]> {
    console.log("📰 Fetching feed articles...")

    const allArticles: Article[] = []
    let cursor: string | undefined = undefined
    let hasMore = true
    let pageNum = 0

    const decodedToken = decodeURIComponent(this.options.token)
    const cookieName = this.options.apiUrl.includes("https")
      ? "__Secure-better-auth.session_token"
      : "better-auth.session_token"
    const cookieStr = `${cookieName}=${decodedToken}; better-auth.last_used_login_method=google`

    try {
      // Fetch entries from both view=0 (综合) and view=1 (文章/社交媒体)
      // view=1 contains Twitter/Weibo subscriptions which are "social media"
      for (const viewType of [0, 1]) {
        cursor = undefined
        hasMore = true
        
        while (hasMore) {
          pageNum++
          process.stdout.write(`\r  Fetching view=${viewType} page ${pageNum}...`)

          const body: any = {
            read: false,
            limit: this.options.limit || 100,
            view: viewType,
            withContent: true,
          }

          if (cursor) {
            body.publishedAfter = cursor
          }

          const response = await fetch(`${this.options.apiUrl}/entries`, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Cookie: cookieStr,
              "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
              Accept: "application/json",
              Origin: "https://app.folo.is",
              Referer: "https://app.folo.is",
              "X-App-Platform": "desktop/web",
              "X-App-Name": "Folo Web",
              "X-App-Version": "1.7.0",
              "X-Client-Id": this.options.clientId || "",
              "X-Session-Id": this.options.sessionId || "",
            },
            body: JSON.stringify(body),
          })

          if (!response.ok) {
            const errorText = await response.text()
            throw new Error(`HTTP ${response.status}: ${errorText}`)
          }

          const result = await response.json()

          if (!result.data || result.data.length === 0) {
            hasMore = false
            break
          }

          for (const item of result.data) {
            const article = item.entries
            // Get feedId from the feeds object
            const feedId = item.feeds?.id
            article.feedId = feedId || null
            // Look up the subscription view for this feed
            const subView = feedId ? feedViewMap.get(feedId) : undefined
            
            // Categorize: view=1 subscriptions (Twitter/Weibo) go to social
            if (subView === 1) {
              article.category = "social"
            } else {
              article.category = "feeds"
            }
            allArticles.push(article)
          }

          if (result.data.length < (this.options.limit || 100)) {
            hasMore = false
          } else {
            const lastArticle = result.data[result.data.length - 1]
            cursor = lastArticle.entries.publishedAt
          }
        }
      }

      process.stdout.write("\n")
      return allArticles
    } catch (error: any) {
      throw new Error(
        `Failed to fetch feed articles from API: ${error.message}\n` +
          `Make sure your authentication token is valid and not expired.`,
      )
    }
  }

  private async fetchInboxArticles(inboxIds: string[]): Promise<Article[]> {
    if (inboxIds.length === 0) {
      return []
    }

    console.log(`📥 Fetching inbox articles from ${inboxIds.length} inboxes...`)

    const allArticles: Article[] = []
    const entryIds: string[] = []
    const decodedToken = decodeURIComponent(this.options.token)
    const cookieName = this.options.apiUrl.includes("https")
      ? "__Secure-better-auth.session_token"
      : "better-auth.session_token"
    const cookieStr = `${cookieName}=${decodedToken}; better-auth.last_used_login_method=google`

    // Step 1: Get all unread entry IDs from inboxes
    for (let i = 0; i < inboxIds.length; i++) {
      const inboxId = inboxIds[i]
      let cursor: string | undefined = undefined
      let hasMore = true

      process.stdout.write(`\r  Scanning inbox ${i + 1}/${inboxIds.length}...`)

      try {
        while (hasMore) {
          const body: any = {
            inboxId,
            read: false,
            limit: this.options.limit || 100,
          }

          if (cursor) {
            body.publishedAfter = cursor
          }

          const response = await fetch(`${this.options.apiUrl}/entries/inbox`, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Cookie: cookieStr,
              "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
              Accept: "application/json",
              Origin: "https://app.folo.is",
              Referer: "https://app.folo.is",
              "X-App-Platform": "desktop/web",
              "X-App-Name": "Folo Web",
              "X-App-Version": "1.7.0",
              "X-Client-Id": this.options.clientId || "",
              "X-Session-Id": this.options.sessionId || "",
            },
            body: JSON.stringify(body),
          })

          if (!response.ok) {
            break
          }

          const result = await response.json()

          if (!result.data || result.data.length === 0) {
            hasMore = false
            break
          }

          for (const item of result.data) {
            entryIds.push(item.entries.id)
          }

          if (result.data.length < (this.options.limit || 100)) {
            hasMore = false
          } else {
            const lastArticle = result.data[result.data.length - 1]
            cursor = lastArticle.entries.publishedAt
          }
        }
      } catch (error) {
        continue
      }
    }

    process.stdout.write(`\n  Found ${entryIds.length} unread inbox entries, fetching content...`)

    // Step 2: Fetch full content for each entry
    for (let i = 0; i < entryIds.length; i++) {
      const entryId = entryIds[i]
      
      try {
        const response = await fetch(`${this.options.apiUrl}/entries/inbox?id=${entryId}`, {
          method: "GET",
          headers: {
            "Content-Type": "application/json",
            Cookie: cookieStr,
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
            Accept: "application/json",
            Origin: "https://app.folo.is",
            Referer: "https://app.folo.is",
            "X-App-Platform": "desktop/web",
            "X-App-Name": "Folo Web",
            "X-App-Version": "1.7.0",
            "X-Client-Id": this.options.clientId || "",
            "X-Session-Id": this.options.sessionId || "",
          },
        })

        if (!response.ok) {
          continue
        }

        const result = await response.json()
        if (result.data?.entries) {
          const article = result.data.entries
          article.category = "inbox"
          allArticles.push(article)
        }
      } catch (error) {
        continue
      }
    }

    process.stdout.write("\n")
    return allArticles
  }

  private async fetchUnreadArticles(): Promise<Article[]> {
    console.log("📡 Fetching all unread articles...\n")

    // 1. Get subscriptions to find inboxIds and build feedViewMap
    const { inboxIds, feedViewMap, feedCategoryMap } = await this.fetchSubscriptions()

    // Store for later use (writing subscription_category to pipeline-state)
    this.feedCategoryMap = feedCategoryMap

    // 2. Fetch feed articles (view=0 for all, then categorize by subscription view)
    const feedArticles = await this.fetchFeedArticles(feedViewMap)

    // 3. Fetch inbox articles
    const inboxArticles = await this.fetchInboxArticles(inboxIds)

    // 4. Merge and deduplicate by article ID
    const articleMap = new Map<string, Article>()
    
    for (const article of [...feedArticles, ...inboxArticles]) {
      if (!articleMap.has(article.id)) {
        articleMap.set(article.id, article)
      }
    }

    const allArticles = Array.from(articleMap.values())
    
    // Count by category
    const feedsCount = allArticles.filter(a => a.category === "feeds").length
    const socialCount = allArticles.filter(a => a.category === "social").length
    const inboxCount = allArticles.filter(a => a.category === "inbox").length

    console.log(`\n✓ Total: ${allArticles.length} unique articles`)
    console.log(`  - Feeds: ${feedsCount}`)
    console.log(`  - Social: ${socialCount}`)
    console.log(`  - Inbox: ${inboxCount}`)

    return allArticles
  }

  private sanitizeFilename(name: string): string {
    return name
      // Remove emojis and other Unicode symbols
      .replace(/[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|[\u{1F000}-\u{1F02F}]|[\u{1F0A0}-\u{1F0FF}]/gu, '')
      // Remove other problematic characters including #, %, &, etc.
      .replace(/[<>:"/\\|?*\x00-\x1F,+#%&@!'()[\]{}=;`~$^]/g, "-")
      .replace(/\s+/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, '') // Remove leading/trailing dashes
      .substring(0, 100)
  }

  private generateArticleFolder(article: Article): string {
    const titleSlug = article.title
      ? this.sanitizeFilename(article.title)
      : `article-${article.id.substring(0, 8)}`

    // Determine category folder
    const category = article.category || "feeds"
    
    return path.join(this.outputDir, category, `${titleSlug}-${article.id.substring(0, 8)}`)
  }

  private extractImageUrls(html: string, media?: Array<{ url: string; type: string }>): string[] {
    const imgRegex = /<img[^>]+src=["']([^"']+)["']/gi
    const urls: string[] = []
    let match

    while ((match = imgRegex.exec(html)) !== null) {
      // Decode HTML entities in the URL
      let url = match[1]
        .replace(/&#x26;/g, '&')
        .replace(/&#38;/g, '&')
        .replace(/&amp;/g, '&')
      urls.push(url)
    }

    // Add media images
    if (media) {
      media.forEach((m) => {
        if (m.type.startsWith("image/") && !urls.includes(m.url)) {
          urls.push(m.url)
        }
      })
    }

    return urls
  }

  private async fetchArticleContent(url: string): Promise<string | null> {
    try {
      const response = await fetch(url, {
        headers: {
          "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
          "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
          "Accept-Language": "en-US,en;q=0.5",
        },
        signal: AbortSignal.timeout(15000),
      })

      if (!response.ok) {
        return null
      }

      const html = await response.text()
      const dom = new JSDOM(html, { url })
      const reader = new Readability(dom.window.document)
      const article = reader.parse()

      if (article && article.content) {
        return article.content
      }
      return null
    } catch (error) {
      return null
    }
  }

  private async downloadImage(url: string, destPath: string): Promise<boolean> {
    try {
      // Handle data URLs
      if (url.startsWith("data:")) {
        const matches = url.match(/^data:([^;]+);base64,(.+)$/)
        if (matches) {
          const base64Data = matches[2]
          const buffer = Buffer.from(base64Data, "base64")
          await fs.promises.writeFile(destPath, buffer)
          return true
        }
        return false
      }

      // Determine referer based on image URL domain
      let referer = ""
      try {
        const urlObj = new URL(url)
        const hostname = urlObj.hostname
        
        // Set referer based on common CDN domains
        if (hostname.includes("sspai.com")) {
          referer = "https://sspai.com/"
        } else if (hostname.includes("medium.com")) {
          referer = "https://medium.com/"
        } else if (hostname.includes("substack.com")) {
          referer = "https://substack.com/"
        } else if (hostname.includes("zhihu.com")) {
          referer = "https://www.zhihu.com/"
        } else if (hostname.includes("jianshu.com")) {
          referer = "https://www.jianshu.com/"
        } else if (hostname.includes("36kr.com")) {
          referer = "https://36kr.com/"
        } else if (hostname.includes("csdnimg.cn") || hostname.includes("csdn.net")) {
          referer = "https://blog.csdn.net/"
        } else if (hostname.includes("mmbiz.qpic.cn") || hostname.includes("weixin.qq.com")) {
          referer = "https://mp.weixin.qq.com/"
        } else if (hostname.includes("pbs.twimg.com") || hostname.includes("twimg.com")) {
          referer = "https://twitter.com/"
        } else {
          // Use the origin as referer for other domains
          referer = `${urlObj.protocol}//${urlObj.hostname}/`
        }
      } catch (e) {
        // Invalid URL, skip
      }

      // Download remote images
      const headers: Record<string, string> = {
        "User-Agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      }
      
      if (referer) {
        headers["Referer"] = referer
      }

      const response = await fetch(url, {
        headers,
        signal: AbortSignal.timeout(30000), // 30 second timeout
      })

      if (!response.ok) {
        return false
      }

      const buffer = await response.arrayBuffer()
      await fs.promises.writeFile(destPath, Buffer.from(buffer))
      return true
    } catch (error) {
      return false
    }
  }

  private async processImages(
    articleFolder: string,
    content: string,
    media?: Array<{ url: string; type: string }>,
  ): Promise<{ content: string; imageCount: number }> {
    const imageUrls = this.extractImageUrls(content, media)
    if (imageUrls.length === 0) {
      return { content, imageCount: 0 }
    }

    const imagesDir = path.join(articleFolder, "images")
    await fs.promises.mkdir(imagesDir, { recursive: true })

    let processedContent = content
    let successCount = 0

    for (let i = 0; i < imageUrls.length; i++) {
      const url = imageUrls[i]
      try {
        const ext = path.extname(new URL(url, "http://example.com").pathname) || ".jpg"
        const filename = `image-${i + 1}${ext}`
        const destPath = path.join(imagesDir, filename)

        const success = await this.downloadImage(url, destPath)
        if (success) {
          // Replace both the decoded URL and possible encoded versions
          const encodedUrl = url.replace(/&/g, '&#x26;')
          const ampEncodedUrl = url.replace(/&/g, '&amp;')
          processedContent = processedContent.replace(new RegExp(escapeRegExp(url), "g"), `images/${filename}`)
          processedContent = processedContent.replace(new RegExp(escapeRegExp(encodedUrl), "g"), `images/${filename}`)
          processedContent = processedContent.replace(new RegExp(escapeRegExp(ampEncodedUrl), "g"), `images/${filename}`)
          successCount++
        }
      } catch (error) {
        // Skip invalid URLs
        continue
      }
    }

    return { content: processedContent, imageCount: successCount }
  }

  private cleanupHtmlContent(html: string, isInbox: boolean = false): string {
    let cleaned = html

    // Remove embedded <style> tags from email content (they override our styles)
    cleaned = cleaned.replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '')

    // Remove <title> tags from email content
    cleaned = cleaned.replace(/<title[^>]*>[\s\S]*?<\/title>/gi, '')

    // Decode HTML entities in the content (e.g., &#x26; -> &)
    cleaned = cleaned.replace(/&#x26;/g, '&')
    cleaned = cleaned.replace(/&#38;/g, '&')
    cleaned = cleaned.replace(/&amp;/g, '&')

    // For inbox emails, apply moderate cleanup - keep useful styles, remove email template cruft
    if (isInbox) {
      // Remove 1x1 tracking pixels
      cleaned = cleaned.replace(/<img[^>]*width\s*=\s*["']?1["']?[^>]*height\s*=\s*["']?1["']?[^>]*>/gi, '')
      cleaned = cleaned.replace(/<img[^>]*height\s*=\s*["']?1["']?[^>]*width\s*=\s*["']?1["']?[^>]*>/gi, '')

      // Remove table layout but keep content - convert to semantic HTML
      cleaned = cleaned.replace(/<\/?tbody[^>]*>/gi, '')
      cleaned = cleaned.replace(/<table[^>]*>/gi, '<div class="email-section">')
      cleaned = cleaned.replace(/<\/table>/gi, '</div>')
      cleaned = cleaned.replace(/<tr[^>]*>/gi, '')
      cleaned = cleaned.replace(/<\/tr>/gi, '')
      cleaned = cleaned.replace(/<td[^>]*>/gi, '')
      cleaned = cleaned.replace(/<\/td>/gi, '')

      // Clean up email-specific style properties but keep useful ones
      cleaned = cleaned.replace(/style="([^"]*)"/gi, (match, styleContent) => {
        let cleanedStyle = styleContent
          // Remove email client hacks
          .replace(/-ms-text-size-adjust[^;]*;?/gi, '')
          .replace(/-webkit-text-size-adjust[^;]*;?/gi, '')
          .replace(/mso-[^;]+;?/gi, '')
          // Remove fixed widths that break responsive layout
          .replace(/width\s*:\s*\d+px;?/gi, '')
          .replace(/max-width\s*:\s*\d+px;?/gi, '')
          // Remove table-specific styles
          .replace(/border-collapse[^;]*;?/gi, '')
          .replace(/border-spacing[^;]*;?/gi, '')
          .replace(/table-layout[^;]*;?/gi, '')
          // Remove excessive margins/paddings
          .replace(/padding\s*:\s*0[^;]*;?/gi, '')
          .replace(/margin\s*:\s*0[^;]*;?/gi, '')
          // Clean up
          .replace(/;+/g, ';')
          .replace(/^;|;$/g, '')
          .trim()
        
        // Keep style if it has meaningful content (colors, backgrounds, borders, fonts)
        if (cleanedStyle && /(?:color|background|border|font|line-height|text-align|display|margin|padding)/.test(cleanedStyle)) {
          return `style="${cleanedStyle}"`
        }
        return ''
      })

      // Remove layout attributes
      cleaned = cleaned.replace(/\s*(align|valign|width|height|border|cellpadding|cellspacing)\s*=\s*["'][^"']*["']/gi, '')

      // Remove id attributes that start with "user-content-"
      cleaned = cleaned.replace(/\s*id="user-content-[^"]*"/gi, '')

      // Clean up multiple empty divs - run multiple times to catch nested ones
      for (let i = 0; i < 10; i++) {
        cleaned = cleaned.replace(/<div[^>]*>\s*<\/div>/g, '')
        cleaned = cleaned.replace(/<span[^>]*>\s*<\/span>/g, '')
        // Also match divs that only contain whitespace and newlines
        cleaned = cleaned.replace(/<div class="email-section">[\s\n]*<\/div>/g, '')
        cleaned = cleaned.replace(/<div class="email-section">[\s\n]*(<div class="email-section">)/g, '$1')
      }

      // Remove redundant nested email-section divs (collapse nested structure)
      // Replace <div class="email-section">\n\n  <div class="email-section"> with just the inner one
      cleaned = cleaned.replace(/(<div class="email-section">[\s\n]*)(<div class="email-section">)/g, '$2')
      cleaned = cleaned.replace(/(<\/div>[\s\n]*)(<\/div>)/g, '$2')

      // Clean up excessive whitespace
      cleaned = cleaned.replace(/\n\s*\n\s*\n/g, '\n\n')
    } else {
      // For non-inbox content, apply selective style cleanup
      cleaned = cleaned.replace(/style="([^"]*)"/g, (match, styleContent) => {
        let cleanedStyle = styleContent
          // Remove width/min-width that force full viewport width
          .replace(/width\s*:\s*100%\s*!important;?/gi, '')
          .replace(/width\s*:\s*100%;?/gi, '')
          .replace(/min-width\s*:\s*100vw\s*!important;?/gi, '')
          .replace(/min-width\s*:\s*100%\s*!important;?/gi, '')
          .replace(/height\s*:\s*100%\s*!important;?/gi, '')
          // Remove margin/padding that override body styles
          .replace(/margin\s*:\s*0[^;]*;?/gi, '')
          .replace(/padding\s*:\s*0[^;]*;?/gi, '')
          // Remove mso- (Microsoft Office) specific styles
          .replace(/mso-[^;]+;?/gi, '')
          // Remove white-space/overflow that break layout
          .replace(/white-space\s*:\s*nowrap;?/gi, '')
          .replace(/overflow\s*:\s*hidden;?/gi, '')
          .replace(/text-overflow\s*:\s*ellipsis;?/gi, '')
          // Clean up leftover semicolons
          .replace(/;+/g, ';')
          .replace(/^;|;$/g, '')
          .trim()
        
        if (cleanedStyle) {
          return `style="${cleanedStyle}"`
        } else {
          return ''
        }
      })
    }

    // Remove empty <li></li> tags that cause visual clutter
    cleaned = cleaned.replace(/<li>\s*<\/li>/g, '')

    // Remove empty <ul></ul> and <ol></ol> tags
    cleaned = cleaned.replace(/<ul[^>]*>\s*<\/ul>/g, '')
    cleaned = cleaned.replace(/<ol[^>]*>\s*<\/ol>/g, '')

    // Fix nested <pre> tags - flatten them
    cleaned = cleaned.replace(/<pre[^>]*>\s*<pre/g, '<pre')
    cleaned = cleaned.replace(/<\/pre>\s*<\/pre>/g, '</pre>')

    // Clean up code blocks: convert <code><span>text</span></code> patterns to cleaner format
    // First, add line breaks between consecutive code blocks
    cleaned = cleaned.replace(/<\/code>\s*<code>/g, '</code>\n<code>')

    // Remove inline styles from span tags inside code blocks that interfere with formatting
    cleaned = cleaned.replace(/<span\s+style="[^"]*font-size[^"]*">/g, '<span>')

    // Ensure pre blocks have proper styling
    cleaned = cleaned.replace(/<pre(?:\s+[^>]*)?>(?!\s*<code)/g, '<pre class="code-block"><code>')
    cleaned = cleaned.replace(/<\/pre>/g, (match, offset) => {
      // Check if there's a closing </code> before this </pre>
      const before = cleaned.substring(Math.max(0, offset - 20), offset)
      if (!before.includes('</code>')) {
        return '</code></pre>'
      }
      return match
    })

    return cleaned
  }

  private generateHtml(article: Article, content: string): string {
    const isInbox = article.category === "inbox"
    // Clean up the content before generating HTML
    const cleanedContent = this.cleanupHtmlContent(content, isInbox)
    const publishedDate = new Date(article.publishedAt).toLocaleString("zh-CN", {
      year: "numeric",
      month: "long",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    })

    const category = article.category || "feeds"

    // Entry ID marker - placed as HTML comment to avoid translation interference
    const entryIdMarker = `<!-- FOLO_ENTRY_ID:${article.id} -->`

    return `<!DOCTYPE html>
${entryIdMarker}
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="folo-entry-id" content="${article.id}">
  <meta name="folo-category" content="${category}">
  <title>${this.escapeHtml(article.title || "Untitled")}</title>
  <style>
    * {
      box-sizing: border-box;
    }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";
      line-height: 1.7;
      max-width: 800px;
      margin: 0 auto;
      padding: 20px;
      background: #f5f5f5;
      color: #333;
    }
    .article {
      background: white;
      padding: 40px;
      border-radius: 12px;
      box-shadow: 0 2px 12px rgba(0,0,0,0.08);
    }
    h1 {
      font-size: 2em;
      font-weight: 700;
      margin-bottom: 10px;
      color: #1a1a1a;
      line-height: 1.3;
    }
    .meta {
      color: #666;
      font-size: 0.9em;
      margin-bottom: 30px;
      padding-bottom: 20px;
      border-bottom: 2px solid #f0f0f0;
    }
    .meta-item {
      margin: 8px 0;
    }
    .meta-label {
      font-weight: 600;
      color: #888;
    }
    .meta a {
      color: #0066cc;
      text-decoration: none;
      word-break: break-all;
    }
    .meta a:hover {
      text-decoration: underline;
    }
    .actions {
      margin-top: 30px;
      padding-top: 20px;
      border-top: 2px solid #f0f0f0;
      display: flex;
      gap: 12px;
    }
    .btn {
      padding: 10px 20px;
      border: none;
      border-radius: 6px;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
    }
    .btn-primary {
      background: #0066cc;
      color: white;
    }
    .btn-primary:hover {
      background: #0052a3;
    }
    .btn-primary:disabled {
      background: #ccc;
      cursor: not-allowed;
    }
    .btn-success {
      background: #28a745;
      color: white;
    }
    .content {
      color: #333;
      font-size: 1.05em;
      /* Ensure content doesn't overflow */
      overflow-x: auto;
      word-wrap: break-word;
    }
    .content table {
      max-width: 100%;
      margin: 16px 0;
      border-collapse: collapse;
    }
    .content td, .content th {
      padding: 8px;
    }
    .content img {
      max-width: 100%;
      height: auto;
      margin: 24px 0;
      border-radius: 8px;
      box-shadow: 0 2px 8px rgba(0,0,0,0.1);
    }
    .content p {
      margin: 1.2em 0;
    }
    .content h2, .content h3, .content h4 {
      margin-top: 1.5em;
      margin-bottom: 0.8em;
      font-weight: 600;
    }
    .content h2 {
      font-size: 1.5em;
      color: #1a1a1a;
    }
    .content h3 {
      font-size: 1.3em;
      color: #2a2a2a;
    }
    .content pre, .content pre.code-block {
      background: #1e1e1e;
      padding: 16px;
      border-radius: 8px;
      overflow-x: auto;
      border: none;
      margin: 1.5em 0;
      line-height: 1.5;
    }
    .content code {
      font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
      font-size: 0.9em;
    }
    .content pre code, .content pre.code-block code {
      background: transparent;
      padding: 0;
      color: #d4d4d4;
      display: block;
      white-space: pre-wrap;
      word-wrap: break-word;
    }
    .content :not(pre) > code {
      background: #f0f0f0;
      padding: 2px 6px;
      border-radius: 3px;
      color: #e83e8c;
    }
    .content blockquote {
      margin: 1.5em 0;
      padding-left: 20px;
      border-left: 4px solid #ddd;
      color: #666;
      font-style: italic;
    }
    .content a {
      color: #0066cc;
      text-decoration: none;
    }
    .content a:hover {
      text-decoration: underline;
    }
    .content ul, .content ol {
      padding-left: 2em;
      margin: 1em 0;
      list-style-position: outside;
    }
    .content li {
      margin: 0.5em 0;
      padding-left: 0.5em;
    }
    .content ul {
      list-style-type: disc;
    }
    .content ol {
      list-style-type: decimal;
    }
    .content ul ul, .content ol ul {
      list-style-type: circle;
    }
    .content section {
      margin: 0.8em 0;
      white-space: normal !important;
      word-wrap: break-word;
      overflow-wrap: break-word;
    }
    .content section[style*="white-space"] {
      white-space: normal !important;
    }
    @media (max-width: 640px) {
      body {
        padding: 10px;
      }
      .article {
        padding: 20px;
      }
    }
  </style>
</head>
<body>
  <div class="article">
    <h1>${this.escapeHtml(article.title || "Untitled")}</h1>
    <div class="meta">
      ${article.author ? `<div class="meta-item"><span class="meta-label">作者：</span>${this.escapeHtml(article.author)}</div>` : ""}
      <div class="meta-item"><span class="meta-label">发布时间：</span>${publishedDate}</div>
      ${article.url ? `<div class="meta-item"><span class="meta-label">原文链接：</span><a href="${this.escapeHtml(article.url)}" target="_blank" rel="noopener noreferrer">${this.escapeHtml(article.url)}</a></div>` : ""}
    </div>
    <div class="content">
      ${cleanedContent}
    </div>
    <div class="actions">
      <button id="markReadBtn" class="btn btn-primary" onclick="markAsRead()">✓ 标记为已读</button>
    </div>
  </div>

  <script>
    const ENTRY_ID = "${article.id}";
    const IS_INBOX = ${isInbox};

    async function markAsRead() {
      const btn = document.getElementById('markReadBtn');
      btn.disabled = true;
      btn.textContent = '处理中...';

      try {
        // Use local API proxy (served by serve-with-api.ts)
        const response = await fetch('/api/reads', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            entryIds: [ENTRY_ID],
            isInbox: IS_INBOX,
          }),
        });

        if (response.ok) {
          btn.textContent = '✓ 已标记为已读';
          btn.className = 'btn btn-success';
        } else {
          throw new Error('HTTP ' + response.status);
        }
      } catch (error) {
        btn.textContent = '✗ 失败，点击重试';
        btn.disabled = false;
        console.error('Mark as read failed:', error);
      }
    }
  </script>
</body>
</html>`
  }

  private escapeHtml(text: string): string {
    const map: Record<string, string> = {
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#039;",
    }
    return text.replace(/[&<>"']/g, (m) => map[m])
  }

  async export() {
    console.log("🚀 Starting unread articles export from Folo API...\n")

    // Load local read status
    const readStatus = this.loadReadStatus()
    const locallyReadIds = new Set(Object.keys(readStatus.entries))

    // Create category directories if they don't exist
    await fs.promises.mkdir(path.join(this.outputDir, "feeds"), { recursive: true })
    await fs.promises.mkdir(path.join(this.outputDir, "inbox"), { recursive: true })
    await fs.promises.mkdir(path.join(this.outputDir, "social"), { recursive: true })

    // Build a map of existing entry IDs to their folder paths
    console.log("🔍 Scanning existing articles...")
    const existingEntryMap = new Map<string, string>() // entryId -> folderPath
    const categories = ["feeds", "inbox", "social"]
    
    for (const category of categories) {
      const categoryPath = path.join(this.outputDir, category)
      if (!fs.existsSync(categoryPath)) continue
      
      const folders = await fs.promises.readdir(categoryPath)
      for (const folder of folders) {
        const htmlPath = path.join(categoryPath, folder, "index.html")
        const entryId = this.extractEntryIdFromHtml(htmlPath)
        if (entryId) {
          existingEntryMap.set(entryId, path.join(categoryPath, folder))
        }
      }
    }
    console.log(`✓ Found ${existingEntryMap.size} existing articles`)

    // Delete locally-marked-read articles
    let locallyDeletedCount = 0
    for (const [entryId, folderPath] of existingEntryMap) {
      if (locallyReadIds.has(entryId)) {
        await fs.promises.rm(folderPath, { recursive: true, force: true })
        existingEntryMap.delete(entryId)
        locallyDeletedCount++
      }
    }
    if (locallyDeletedCount > 0) {
      console.log(`🗑️  Deleted ${locallyDeletedCount} locally-marked-read articles`)
    }

    // Fetch unread articles from API
    const articles = await this.fetchUnreadArticles()

    // Build set of unread article IDs from API
    const unreadIds = new Set(articles.map(a => a.id))

    // Delete articles that are no longer unread (marked read elsewhere)
    let remoteDeletedCount = 0
    for (const [entryId, folderPath] of existingEntryMap) {
      if (!unreadIds.has(entryId)) {
        await fs.promises.rm(folderPath, { recursive: true, force: true })
        existingEntryMap.delete(entryId)
        remoteDeletedCount++
        // Also clean up from local read status if present
        if (readStatus.entries[entryId]) {
          delete readStatus.entries[entryId]
        }
      }
    }
    if (remoteDeletedCount > 0) {
      console.log(`🗑️  Deleted ${remoteDeletedCount} articles marked read elsewhere`)
    }

    if (articles.length === 0) {
      console.log("\n✓ No unread articles found.")
      // Save read status (preserve it)
      this.saveReadStatus(readStatus)
      return
    }

    // Filter out articles that already exist (by entry ID)
    const newArticles = articles.filter(article => !existingEntryMap.has(article.id))
    const skippedCount = articles.length - newArticles.length

    console.log(`\n📊 Articles status:`)
    console.log(`   Total from API: ${articles.length}`)
    console.log(`   Already exists (skip): ${skippedCount}`)
    console.log(`   New to download: ${newArticles.length}`)
    console.log(`✓ Output directory: ${this.outputDir}\n`)

    if (newArticles.length === 0) {
      console.log("✓ All articles already exist, nothing to download.")

      // Batch-write subscription_category to pipeline-state for all articles
      for (const article of articles) {
        if (article.feedId && this.feedCategoryMap.has(article.feedId)) {
          try {
            await updateArticleState(article.id, { subscription_category: this.feedCategoryMap.get(article.feedId)! })
          } catch {}
        }
      }

      this.saveReadStatus(readStatus)
      return
    }

    // Process articles with concurrency control
    console.log("📥 Processing new articles and downloading images...\n")
    const startTime = Date.now()

    // Determine concurrency level (default: 5)
    const concurrency = this.options.concurrency || 5
    console.log(`⚙️  Using ${concurrency} concurrent workers\n`)

    // Create progress bar
    const progressBar = new cliProgress.SingleBar({
      format: "Progress |{bar}| {percentage}% | {value}/{total} articles | ETA: {eta}s | {currentArticle}",
      barCompleteChar: "\u2588",
      barIncompleteChar: "\u2591",
      hideCursor: true,
      clearOnComplete: false,
      stopOnComplete: true,
    }, cliProgress.Presets.shades_classic)

    progressBar.start(newArticles.length, 0, { currentArticle: "Starting..." })

    let totalImages = 0
    let completed = 0
    const imageCounts: number[] = []

    // Create limiter for parallel processing
    const limit = pLimit(concurrency)

    // Process articles in parallel with limit
    const tasks = newArticles.map((article, index) =>
      limit(async () => {
        const articleTitle = article.title || `Article ${article.id.substring(0, 8)}`

        try {
          const articleFolder = this.generateArticleFolder(article)
          await fs.promises.mkdir(articleFolder, { recursive: true })

          // Get content - if no content available, try to fetch from original URL
          let content = article.content || article.description || ""
          if ((!content || content.length < 50) && article.url) {
            // Try to fetch content from the original article URL
            const fetchedContent = await this.fetchArticleContent(article.url)
            if (fetchedContent) {
              content = fetchedContent
            } else {
              // Fallback: show message with link
              content = `
                <div style="text-align: center; padding: 40px 20px; background: #f8f9fa; border-radius: 8px; margin: 20px 0;">
                  <p style="font-size: 1.2em; color: #666; margin-bottom: 20px;">
                    无法获取文章内容
                  </p>
                  <a href="${this.escapeHtml(article.url)}" target="_blank" rel="noopener noreferrer" 
                     style="display: inline-block; padding: 12px 24px; background: #0066cc; color: white; text-decoration: none; border-radius: 6px; font-weight: 500;">
                    阅读原文 →
                  </a>
                </div>
              `
            }
          }

          // Process images
          const { content: processedContent, imageCount } = await this.processImages(
            articleFolder,
            content,
            article.media,
          )
          imageCounts[index] = imageCount

          // Generate and save HTML
          const html = this.generateHtml(article, processedContent)
          await fs.promises.writeFile(path.join(articleFolder, "index.html"), html, "utf-8")

          // Write subscription category to pipeline-state
          if (article.feedId && this.feedCategoryMap.has(article.feedId)) {
            const subCat = this.feedCategoryMap.get(article.feedId)!
            await updateArticleState(article.id, { subscription_category: subCat }).catch(() => {})
          }

          // Update progress
          completed++
          progressBar.update(completed, {
            currentArticle: articleTitle.substring(0, 50),
          })

          return { success: true, imageCount }
        } catch (error) {
          completed++
          progressBar.update(completed, {
            currentArticle: `⚠️ Failed: ${articleTitle.substring(0, 40)}`,
          })
          return { success: false, error, imageCount: 0 }
        }
      }),
    )

    const results = await Promise.all(tasks)
    progressBar.stop()

    // Calculate total images
    totalImages = results.reduce((sum, r) => sum + r.imageCount, 0)

    // Calculate stats
    const successCount = results.filter((r) => r.success).length
    const failedCount = results.length - successCount

    const elapsed = ((Date.now() - startTime) / 1000).toFixed(1)

    // Save read status (preserve it for next run)
    this.saveReadStatus(readStatus)

    const totalDeleted = locallyDeletedCount + remoteDeletedCount

    // Batch-write subscription_category to pipeline-state for all articles
    for (const article of articles) {
      if (article.feedId && this.feedCategoryMap.has(article.feedId)) {
        try {
          await updateArticleState(article.id, { subscription_category: this.feedCategoryMap.get(article.feedId)! })
        } catch {}
      }
    }

    console.log(`\n✅ Export completed successfully in ${elapsed}s!`)
    console.log(`   New articles exported: ${successCount}/${newArticles.length}`)
    console.log(`   Skipped (already exist): ${skippedCount}`)
    if (totalDeleted > 0) {
      console.log(`   Deleted (marked read): ${totalDeleted}`)
    }
    if (failedCount > 0) {
      console.log(`   ⚠️  Failed: ${failedCount}`)
    }
    console.log(`   Images downloaded: ${totalImages}`)
    console.log(`   Output location: ${this.outputDir}`)
    console.log(`\n💡 Tip: Start the server with: pnpm run serve:articles`)
  }
}

// Helper function to escape regex special characters
function escapeRegExp(string: string): string {
  return string.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// Helper function to load config from .env.export file
function loadConfig(): Partial<ExportOptions> {
  const configPath = path.join(process.cwd(), ".env.export")
  const config: Partial<ExportOptions> = {}

  if (fs.existsSync(configPath)) {
    const content = fs.readFileSync(configPath, "utf-8")
    const lines = content.split("\n")

    for (const line of lines) {
      const trimmed = line.trim()
      if (trimmed && !trimmed.startsWith("#")) {
        const [key, ...valueParts] = trimmed.split("=")
        const value = valueParts.join("=").trim()

        if (key && value) {
          switch (key.trim()) {
            case "FOLO_SESSION_TOKEN":
              config.token = value
              break
            case "FOLO_API_URL":
              config.apiUrl = value
              break
            case "FOLO_OUTPUT_DIR":
              config.outputDir = value
              break
            case "FOLO_LIMIT":
              config.limit = parseInt(value, 10)
              break
            case "FOLO_CONCURRENCY":
              config.concurrency = parseInt(value, 10)
              break
            case "FOLO_CLIENT_ID":
              config.clientId = value
              break
            case "FOLO_SESSION_ID":
              config.sessionId = value
              break
          }
        }
      }
    }
  }

  return config
}

// CLI
async function main() {
  const args = process.argv.slice(2)

  if (args.includes("--help") || args.includes("-h")) {
    console.log(`
Usage: pnpm run export:unread [options]

Options:
  --token <token>          Authentication token (overrides config file)
  --output <path>          Output directory (default: ./unread-articles)
  --api-url <url>          API URL (default: https://api.follow.is)
  --limit <number>         Articles per request (default: 100)
  --concurrency <number>   Number of parallel workers (default: 5)
  --help, -h               Show this help message

Configuration File (.env.export):
  Create a .env.export file in the project root with:
    FOLO_SESSION_TOKEN=your_token_here
    FOLO_API_URL=https://api.follow.is
    FOLO_OUTPUT_DIR=./unread-articles
    FOLO_LIMIT=100
    FOLO_CONCURRENCY=5

Examples:
  # Using config file (recommended)
  pnpm run export:unread

  # Override with command line
  pnpm run export:unread -- --token YOUR_TOKEN
  pnpm run export:unread -- --output ./my-articles
  pnpm run export:unread -- --concurrency 10

Authentication:
  See AUTH_GUIDE.md for detailed instructions on how to obtain your authentication token.
    `)
    process.exit(0)
  }

  // Load config from file first
  const fileConfig = loadConfig()

  // Parse command line arguments (they override file config)
  const tokenIndex = args.indexOf("--token")
  const outputIndex = args.indexOf("--output")
  const apiUrlIndex = args.indexOf("--api-url")
  const limitIndex = args.indexOf("--limit")
  const concurrencyIndex = args.indexOf("--concurrency")

  const options: ExportOptions = {
    token:
      tokenIndex !== -1 ? args[tokenIndex + 1] : fileConfig.token || process.env.FOLO_SESSION_TOKEN || "",
    outputDir:
      outputIndex !== -1
        ? args[outputIndex + 1]
        : fileConfig.outputDir || process.env.FOLO_OUTPUT_DIR || path.join(process.cwd(), "unread-articles"),
    apiUrl:
      apiUrlIndex !== -1
        ? args[apiUrlIndex + 1]
        : fileConfig.apiUrl || process.env.FOLO_API_URL || "https://api.follow.is",
    limit:
      limitIndex !== -1
        ? parseInt(args[limitIndex + 1], 10)
        : fileConfig.limit || parseInt(process.env.FOLO_LIMIT || "100", 10),
    concurrency:
      concurrencyIndex !== -1
        ? parseInt(args[concurrencyIndex + 1], 10)
        : fileConfig.concurrency || parseInt(process.env.FOLO_CONCURRENCY || "5", 10),
    clientId: fileConfig.clientId || process.env.FOLO_CLIENT_ID || "",
    sessionId: fileConfig.sessionId || process.env.FOLO_SESSION_ID || "",
  }

  if (!options.token) {
    console.error(
      `\n❌ Error: Authentication token is required.\n\n` +
        `Please either:\n` +
        `  1. Create a .env.export file with FOLO_SESSION_TOKEN=your_token\n` +
        `  2. Use --token parameter: pnpm run export:unread -- --token YOUR_TOKEN\n` +
        `  3. Set environment variable: export FOLO_SESSION_TOKEN=your_token\n\n` +
        `See AUTH_GUIDE.md for how to obtain your authentication token.\n`,
    )
    process.exit(1)
  }

  try {
    const exporter = new UnreadArticlesExporter(options)
    await exporter.export()
  } catch (error) {
    console.error(`\n❌ Error: ${(error as Error).message}`)
    process.exit(1)
  }
}

main()
