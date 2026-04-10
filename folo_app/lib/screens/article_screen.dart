import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/models.dart';
import '../api/follow_client.dart';

class ArticleScreen extends StatefulWidget {
  final FollowArticle article;
  final FollowClient client;
  final VoidCallback onMarkedRead;

  const ArticleScreen({
    Key? key,
    required this.article,
    required this.client,
    required this.onMarkedRead,
  }) : super(key: key);

  @override
  _ArticleScreenState createState() => _ArticleScreenState();
}

class _ArticleScreenState extends State<ArticleScreen> {
  bool _isMarkingRead = false;

  Future<void> _markAsRead() async {
    setState(() => _isMarkingRead = true);

    final success = await widget.client.markAsRead(
      widget.article.id,
      isInbox: widget.article.category == 'inbox'
    );

    if (success && mounted) {
      widget.onMarkedRead();
      Navigator.of(context).pop();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to mark as read')),
        );
        setState(() => _isMarkingRead = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.article.title ?? 'Article'),
        actions: [
          IconButton(
            icon: _isMarkingRead
                ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.done),
            onPressed: _isMarkingRead ? null : _markAsRead,
            tooltip: 'Mark as Read',
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.article.title ?? 'Untitled',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            if (widget.article.author != null)
              Text(
                'By ${widget.article.author}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
              ),
            Text(
              'Published: ${widget.article.publishedAt}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
            ),
            if (widget.article.url != null) ...[
              SizedBox(height: 8),
              InkWell(
                onTap: () => launchUrl(Uri.parse(widget.article.url!)),
                child: Text(
                  'View Original',
                  style: TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
                ),
              ),
            ],
            Divider(height: 32),
            Html(
              data: widget.article.content ?? widget.article.description ?? 'No content available.',
              onLinkTap: (url, attributes, element) {
                if (url != null) {
                  launchUrl(Uri.parse(url));
                }
              },
              style: {
                "body": Style(
                  fontSize: FontSize(16.0),
                  lineHeight: LineHeight(1.6),
                ),
                "img": Style(
                  width: Width.auto(),
                  height: Height.auto(),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}
