import 'package:flutter/material.dart';
import '../api/models.dart';
import '../api/follow_client.dart';
import '../api/ai_pipeline_service.dart';

class FilterBoxScreen extends StatefulWidget {
  final FollowClient client;
  final List<FollowArticle> articles;

  const FilterBoxScreen({
    Key? key,
    required this.client,
    required this.articles,
  }) : super(key: key);

  @override
  _FilterBoxScreenState createState() => _FilterBoxScreenState();
}

class _FilterBoxScreenState extends State<FilterBoxScreen> {
  List<FollowArticle> _rejectedArticles = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRejected();
  }

  Future<void> _loadRejected() async {
    await AiPipelineService().init();
    final rejectedStates = AiPipelineService().getRejectedArticles();
    final rejectedIds = rejectedStates.map((e) => e.id).toSet();

    if (mounted) {
      setState(() {
        _rejectedArticles = widget.articles.where((a) => rejectedIds.contains(a.id)).toList();
        _isLoading = false;
      });
    }
  }

  void _restoreArticle(FollowArticle article) async {
    await AiPipelineService().updateState(article.id, status: 'kept');
    setState(() {
      _rejectedArticles.remove(article);
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Restored: ${article.title}')),
      );
    }
  }

  void _confirmDelete(FollowArticle article) async {
    await widget.client.markAsRead(article.id, isInbox: article.category == 'inbox');
    await AiPipelineService().removeState(article.id);
    setState(() {
      _rejectedArticles.remove(article);
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted forever')),
      );
    }
  }

  void _confirmAll() async {
    if (_rejectedArticles.isEmpty) return;

    for (var a in _rejectedArticles) {
      await widget.client.markAsRead(a.id, isInbox: a.category == 'inbox');
      await AiPipelineService().removeState(a.id);
    }

    if (mounted) {
      setState(() {
        _rejectedArticles.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Emptied Filter Box')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text('AI Filter Box')),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('AI Filter Box (${_rejectedArticles.length})'),
        actions: [
          IconButton(
            icon: Icon(Icons.delete_sweep),
            tooltip: 'Confirm All',
            onPressed: _rejectedArticles.isEmpty ? null : () {
              showDialog(
                context: context,
                builder: (c) => AlertDialog(
                  title: Text('Confirm All Deletions'),
                  content: Text('Are you sure you want to mark all these rejected articles as read? This cannot be undone.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c), child: Text('Cancel')),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(c);
                        _confirmAll();
                      },
                      child: Text('Confirm', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: _rejectedArticles.isEmpty
          ? Center(child: Text('Filter box is empty!'))
          : ListView.builder(
              itemCount: _rejectedArticles.length,
              itemBuilder: (context, index) {
                final article = _rejectedArticles[index];
                final state = AiPipelineService().getState(article.id);
                return Card(
                  margin: EdgeInsets.all(8),
                  child: ListTile(
                    title: Text(article.title ?? 'Untitled', maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Reason: ${state.rejectReason ?? "Unknown"}', style: TextStyle(color: Colors.red)),
                        if (state.category != null) Text('Category: ${state.category}'),
                      ],
                    ),
                    isThreeLine: true,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(Icons.restore, color: Colors.green),
                          tooltip: 'Restore to Keep',
                          onPressed: () => _restoreArticle(article),
                        ),
                        IconButton(
                          icon: Icon(Icons.delete, color: Colors.red),
                          tooltip: 'Confirm Delete',
                          onPressed: () => _confirmDelete(article),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
