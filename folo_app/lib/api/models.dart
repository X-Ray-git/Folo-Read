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
    return FollowArticle(
      id: json['id'] as String? ?? '',
      title: json['title'] as String?,
      url: json['url'] as String?,
      content: json['content'] as String?,
      description: json['description'] as String?,
      author: json['author'] as String?,
      publishedAt: json['publishedAt'] as String? ?? '',
      category: category,
      isRead: json['read'] == true,
    );
  }
}
