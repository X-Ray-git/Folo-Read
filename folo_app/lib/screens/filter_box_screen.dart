import 'package:flutter/material.dart';
import '../api/models.dart';
import '../api/follow_client.dart';
import '../api/ai_pipeline_service.dart';
import '../managers/ai_task_manager.dart';
import 'similarity_screen.dart';
import 'article_screen.dart';

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
    AiTaskManager().addListener(_onAiTaskUpdate);
  }

  @override
  void dispose() {
    AiTaskManager().removeListener(_onAiTaskUpdate);
    super.dispose();
  }

  void _onAiTaskUpdate() {
    if (mounted) {
      setState(() {});
      // Also silently reload rejected when task finishes analyzing something
      _loadRejectedSilently();
    }
  }

  Future<void> _loadRejectedSilently() async {
    final rejectedStates = AiPipelineService().getRejectedArticles();
    final rejectedIds = rejectedStates.map((e) => e.id).toSet();
    if (mounted) {
      setState(() {
        _rejectedArticles = widget.articles.where((a) => rejectedIds.contains(a.id)).toList();
      });
    }
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

  Widget _buildAiProgressCard() {
    final manager = AiTaskManager();
    if (!manager.isRunning && manager.pendingResolutionGroups.isEmpty) {
      return SizedBox.shrink(); // Hide if completely idle
    }

    return Card(
      margin: EdgeInsets.all(8),
      color: Theme.of(context).primaryColorLight,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (manager.isCheckingSimilarity)
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                if (manager.isCheckingSimilarity) SizedBox(width: 8),
                Text(
                  manager.isCheckingSimilarity
                    ? '正在后台查重...'
                    : 'AI 分析进度 (${manager.analyzedCount} / ${manager.totalToAnalyze})',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            if (!manager.isCheckingSimilarity) ...[
              SizedBox(height: 8),
              LinearProgressIndicator(
                value: manager.totalToAnalyze > 0 ? (manager.analyzedCount / manager.totalToAnalyze) : 0,
              ),
            ],
            if (manager.pendingResolutionGroups.isNotEmpty) ...[
              SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('发现 ${manager.pendingResolutionGroups.length} 组疑似重复文章', style: TextStyle(color: Colors.red[900])),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SimilarityScreen(
                            articles: widget.articles,
                            client: widget.client,
                            onResolved: (kept) {
                              AiTaskManager().resumeWithResolvedArticles(kept);
                            },
                          ),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red[100],
                      foregroundColor: Colors.red[900],
                    ),
                    child: Text('去处理'),
                  )
                ],
              )
            ]
          ],
        ),
      ),
    );
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
        title: Text('AI 控制中心 (拦截 ${_rejectedArticles.length})'),
        actions: [
          IconButton(
            icon: Icon(Icons.delete_sweep),
            tooltip: '清空拦截',
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
      body: Column(
        children: [
          _buildAiProgressCard(),
          Expanded(
            child: _rejectedArticles.isEmpty
                ? Center(child: Text('拦截箱是空的！'))
                : ListView.builder(
                    itemCount: _rejectedArticles.length,
                    itemBuilder: (context, index) {
                      final article = _rejectedArticles[index];
                      final state = AiPipelineService().getState(article.id);
                      return Card(
                        margin: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: ListTile(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ArticleScreen(
                                  article: article,
                                  client: widget.client,
                                  onMarkedRead: () {
                                    // if marked read from inside, also clear from box
                                    _confirmDelete(article);
                                    Navigator.pop(context);
                                  },
                                ),
                              ),
                            );
                          },
                          title: Text(article.title ?? 'Untitled', maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('理由: ${state.rejectReason ?? "未知"}', style: TextStyle(color: Colors.red)),
                              if (state.category != null) Text('分类: ${state.category}'),
                            ],
                          ),
                          isThreeLine: true,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(Icons.restore, color: Colors.green),
                                tooltip: '恢复并保留',
                                onPressed: () => _restoreArticle(article),
                              ),
                              IconButton(
                                icon: Icon(Icons.delete, color: Colors.red),
                                tooltip: '永久删除',
                                onPressed: () => _confirmDelete(article),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: !AiTaskManager().isRunning ? FloatingActionButton.extended(
        onPressed: () {
          AiTaskManager().startAnalysis(widget.articles);
        },
        icon: Icon(Icons.auto_awesome),
        label: Text('启动全量分析'),
      ) : null,
    );
  }
}
