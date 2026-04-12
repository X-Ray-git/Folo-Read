import 'package:flutter/material.dart';
import '../api/models.dart';
import '../api/follow_client.dart';
import '../managers/ai_task_manager.dart';

class SimilarityScreen extends StatefulWidget {
  final List<FollowArticle> articles;
  final FollowClient client;
  final Function(List<FollowArticle> keptArticles) onResolved;

  const SimilarityScreen({
    Key? key,
    required this.articles,
    required this.client,
    required this.onResolved,
  }) : super(key: key);

  @override
  _SimilarityScreenState createState() => _SimilarityScreenState();
}

class _SimilarityScreenState extends State<SimilarityScreen> {
  bool _isProcessing = false;
  List<SimilarityGroup> _groups = [];
  final Map<String, bool> _keepSelections = {}; // articleId -> true if selected to keep

  @override
  void initState() {
    super.initState();
    _groups = AiTaskManager().pendingResolutionGroups;

    for (var group in _groups) {
      for (var a in group.articles) {
        _keepSelections[a.id] = false;
      }
      if (group.articles.isNotEmpty) {
        // Auto-select the oldest one by default
        final articles = List<FollowArticle>.from(group.articles);
        articles.sort((a, b) {
          final timeA = DateTime.tryParse(a.publishedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b.publishedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB); // oldest first
        });
        _keepSelections[articles.first.id] = true;
      }
    }
  }

  Future<void> _confirmResolution() async {
    setState(() {
      _isProcessing = true;
    });

    List<FollowArticle> finalKept = [];
    List<String> toMarkAsReadIds = [];

    // We only process the groups provided. Unique articles are already handled by AiTaskManager.
    for (var g in _groups) {
      for (var a in g.articles) {
        if (_keepSelections[a.id] == true) {
          finalKept.add(a);
        } else {
          toMarkAsReadIds.add(a.id);
        }
      }
    }

    // Process deletes (mark as read)
    for (var id in toMarkAsReadIds) {
      // Find article category to pass correctly to isInbox
      final article = widget.articles.firstWhere((a) => a.id == id);
      await widget.client.markAsRead(id, isInbox: article.category == 'inbox');
    }

    if (mounted) {
      widget.onResolved(finalKept);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isProcessing) {
      return Scaffold(
        appBar: AppBar(title: Text('Processing...')),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          AiTaskManager().markResolutionAborted();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('处理重复文章'),
          leading: IconButton(
            icon: Icon(Icons.arrow_back),
            onPressed: () {
              // If they cancel, we abort the resolution process
              AiTaskManager().markResolutionAborted();
              Navigator.pop(context);
            },
          ),
        ),
        body: ListView.builder(
        itemCount: _groups.length,
        itemBuilder: (context, groupIndex) {
          final group = _groups[groupIndex];
          return Card(
            margin: EdgeInsets.all(8.0),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Group ${groupIndex + 1} (${group.articles.length} similar items)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Divider(),
                  ...group.articles.map((article) {
                    return CheckboxListTile(
                      title: Text(article.title ?? 'Untitled', maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(article.author ?? article.category),
                      value: _keepSelections[article.id] ?? false,
                      onChanged: (bool? val) {
                        setState(() {
                          _keepSelections[article.id] = val ?? false;
                        });
                      },
                    );
                  }),
                ],
              ),
            ),
          );
          },
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _confirmResolution,
          icon: Icon(Icons.check),
          label: Text('Confirm & Continue'),
        ),
      ),
    );
  }
}
