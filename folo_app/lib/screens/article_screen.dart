import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../api/models.dart';
import '../api/follow_client.dart';
import '../api/translation_service.dart';

class FullScreenImageScreen extends StatelessWidget {
  final String imageUrl;

  const FullScreenImageScreen({Key? key, required this.imageUrl}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.1,
          maxScale: 5.0,
          child: CachedNetworkImage(
            imageUrl: imageUrl,
            placeholder: (context, url) => CircularProgressIndicator(),
            errorWidget: (context, url, error) => Icon(Icons.error, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

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
  bool _showTranslation = true;
  TranslatedArticle? _translation;

  @override
  void initState() {
    super.initState();
    _loadTranslation();
  }

  Future<void> _loadTranslation() async {
    final translation = await TranslationService().getTranslation(
      widget.article.id,
      widget.article.title ?? '',
      widget.article.content ?? widget.article.description ?? '',
    );
    if (mounted && translation != null) {
      setState(() {
        _translation = translation;
      });
    }
  }

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
    final titleToDisplay = _showTranslation && _translation != null
        ? _translation!.title
        : widget.article.title ?? 'Untitled';

    final contentToDisplay = _showTranslation && _translation != null
        ? _translation!.content
        : widget.article.content ?? widget.article.description ?? 'No content available.';

    return Scaffold(
      appBar: AppBar(
        title: Text('Article'),
        actions: [
          Row(
            children: [
              Text('中/En', style: TextStyle(fontSize: 12)),
              Switch(
                value: _showTranslation,
                onChanged: _translation != null ? (val) {
                  setState(() => _showTranslation = val);
                } : null,
              ),
            ],
          ),
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
              titleToDisplay,
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
              data: contentToDisplay,
              onLinkTap: (url, attributes, element) {
                if (url != null) {
                  launchUrl(Uri.parse(url));
                }
              },
              extensions: [
                ImageExtension(
                  builder: (extensionContext) {
                    final src = extensionContext.attributes['src'];
                    if (src != null && src.isNotEmpty) {
                      return GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => FullScreenImageScreen(imageUrl: src),
                            ),
                          );
                        },
                        child: CachedNetworkImage(
                          imageUrl: src,
                          placeholder: (context, url) => const Center(
                            child: CircularProgressIndicator(),
                          ),
                          errorWidget: (context, url, error) => const Center(
                            child: Icon(Icons.broken_image, color: Colors.grey),
                          ),
                        ),
                      );
                    }
                    return const SizedBox();
                  },
                ),
              ],
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
