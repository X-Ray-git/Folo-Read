class FollowArticle {
  final String id;
  final String? title;
  final String? url;
  final String? content;
  final String? description;
  final String? author;
  final String publishedAt;
  final String category; // 'feeds', 'inbox', 'social'
  final bool isRead;

  FollowArticle({
    required this.id,
    this.title,
    this.url,
    this.content,
    this.description,
    this.author,
    required this.publishedAt,
    required this.category,
    this.isRead = false,
  });

  factory FollowArticle.fromJson(Map<String, dynamic> json, String category) {
    String? rawContent = json['content'] as String?;
    String? rawDesc = json['description'] as String?;
    String? rawUrl = json['url'] as String?;

    // Align with TS pipeline logic: Fallback to description or "Read Original" link if content is short/missing
    String? processedContent = rawContent;

    if (processedContent == null || processedContent.trim().length < 50) {
      if (rawDesc != null && rawDesc.trim().length >= 50) {
        processedContent = rawDesc;
      } else if (rawUrl != null && rawUrl.isNotEmpty) {
        processedContent = '''
          <div style="text-align: center; padding: 40px 20px; background: #f8f9fa; border-radius: 8px; margin: 20px 0;">
            <p style="font-size: 1.2em; color: #666; margin-bottom: 20px;">
              无法获取文章内容
            </p>
            <a href="$rawUrl" target="_blank" rel="noopener noreferrer"
               style="display: inline-block; padding: 12px 24px; background: #0066cc; color: white; text-decoration: none; border-radius: 6px; font-weight: 500;">
              阅读原文 →
            </a>
          </div>
        ''';
      }
    }

    return FollowArticle(
      id: json['id'] as String? ?? '',
      title: json['title'] as String?,
      url: rawUrl,
      content: processedContent,
      description: rawDesc,
      author: json['author'] as String?,
      publishedAt: json['publishedAt'] as String? ?? '',
      category: category,
      isRead: json['read'] == true,
    );
  }
}
