import 'package:flutter/material.dart';
import '../api/models.dart';
import '../api/follow_client.dart';
import '../screens/article_screen.dart';
import '../api/translation_service.dart';

class ArticleCard extends StatefulWidget {
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
  _ArticleCardState createState() => _ArticleCardState();
}

class _ArticleCardState extends State<ArticleCard> {
  TranslatedArticle? _translation;
  bool _isTranslating = false;

  @override
  void initState() {
    super.initState();
    _loadTranslation();
  }

  Future<void> _loadTranslation() async {
    setState(() {
      _isTranslating = true;
    });

    final translation = await TranslationService().getTranslation(
      widget.article.id,
      widget.article.title ?? '',
      widget.article.content ?? widget.article.description ?? '',
    );

    if (mounted) {
      setState(() {
        _isTranslating = false;
        if (translation != null) {
          _translation = translation;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final titleToDisplay = _translation?.title.isNotEmpty == true
        ? _translation!.title
        : widget.article.title ?? 'Untitled';

    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ArticleScreen(
                article: widget.article,
                client: widget.client,
                onMarkedRead: widget.onMarkedRead,
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
                      color: _getCategoryColor(widget.article.category).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      widget.article.category.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: _getCategoryColor(widget.article.category),
                      ),
                    ),
                  ),
                  if (_isTranslating)
                    Padding(
                      padding: const EdgeInsets.only(left: 8.0),
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                  Spacer(),
                  Text(
                    _formatDate(widget.article.publishedAt),
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              SizedBox(height: 12),
              Text(
                titleToDisplay,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (widget.article.description != null && widget.article.description!.isNotEmpty) ...[
                SizedBox(height: 8),
                Text(
                  _stripHtml(widget.article.description!),
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[700],
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (widget.article.author != null) ...[
                SizedBox(height: 12),
                Text(
                  widget.article.author!,
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
