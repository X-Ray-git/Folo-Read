import 'package:flutter/material.dart';
import '../api/models.dart';
import '../api/follow_client.dart';
import '../screens/article_screen.dart';

class ArticleCard extends StatelessWidget {
  final FollowArticle article;
  final FollowClient client;
  final VoidCallback onMarkedRead;

  const ArticleCard({
    Key? key,
    required this.article,
    required this.client,
    required this.onMarkedRead,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ArticleScreen(
                article: article,
                client: client,
                onMarkedRead: onMarkedRead,
              ),
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _getCategoryColor(article.category).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      article.category.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: _getCategoryColor(article.category),
                      ),
                    ),
                  ),
                  Spacer(),
                  Text(
                    _formatDate(article.publishedAt),
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              SizedBox(height: 12),
              Text(
                article.title ?? 'Untitled',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (article.description != null && article.description!.isNotEmpty) ...[
                SizedBox(height: 8),
                Text(
                  _stripHtml(article.description!),
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[700],
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (article.author != null) ...[
                SizedBox(height: 12),
                Text(
                  article.author!,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ]
            ],
          ),
        ),
      ),
    );
  }

  Color _getCategoryColor(String category) {
    switch (category) {
      case 'inbox':
        return Colors.blue;
      case 'social':
        return Colors.purple;
      default:
        return Colors.orange;
    }
  }

  String _formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return dateStr;
    }
  }

  String _stripHtml(String text) {
    return text.replaceAll(RegExp(r'<[^>]*>|&[^;]+;'), ' ').trim();
  }
}
