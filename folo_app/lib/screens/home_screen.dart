import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/follow_client.dart';
import '../api/models.dart';
import '../widgets/article_card.dart';
import 'login_screen.dart';
import 'settings_screen.dart';
import '../api/translation_service.dart';
import '../api/ai_pipeline_service.dart';
import 'similarity_screen.dart';
import 'filter_box_screen.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FollowClient _client = FollowClient();
  List<FollowArticle> _articles = [];
  List<FollowArticle> _filteredArticles = [];
  bool _isLoading = true;
  String? _error;
  String _selectedCategory = 'All';
  bool _showReadArticles = false;

  @override
  void initState() {
    super.initState();
    _initClientAndFetch();
  }

  Future<void> _initClientAndFetch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('folo_session_token');

      if (token == null || token.isEmpty) {
        _logout();
        return;
      }

      _client.setToken(token);
      await _fetchArticles();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchArticles() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final articles = await _client.fetchArticles(isRead: _showReadArticles);
      setState(() {
        _articles = articles;
        _applyFilter();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load articles: $e';
        _isLoading = false;
      });
    }
  }

  void _markArticleAsRead(FollowArticle article, int index) {
    // 1. Instantly remove from UI
    setState(() {
      _articles.removeWhere((a) => a.id == article.id);
      _filteredArticles.removeWhere((a) => a.id == article.id);
    });

    bool undoClicked = false;

    // 2. Clear any existing snackbars to prevent stacking, then show new one
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Marked as read'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            undoClicked = true;
            setState(() {
              _articles.insert(index < _articles.length ? index : _articles.length, article);
              _applyFilter();
            });
          },
        ),
        duration: Duration(seconds: 3),
      ),
    );

    // 3. Wait for 3 seconds, then check if undo was clicked
    Future.delayed(Duration(seconds: 3), () async {
      if (!mounted) return;

      if (!undoClicked) {
        // Hide the snackbar forcefully to prevent it from getting stuck and allowing late undos
        ScaffoldMessenger.of(context).hideCurrentSnackBar();

        final success = await _client.markAsRead(
          article.id,
          isInbox: article.category == 'inbox'
        );

        // 4. If request failed, restore it and notify
        if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to mark as read: ${article.title}')),
          );
          setState(() {
            // Restore it back
            _articles.insert(index < _articles.length ? index : _articles.length, article);
            _applyFilter();
          });
        }
      }
    });
  }

  void _applyFilter() async {
    await AiPipelineService().init();
    setState(() {
      List<FollowArticle> filtered;
      if (_selectedCategory == 'All') {
        filtered = List.from(_articles);
      } else {
        filtered = _articles.where((a) => a.category.toLowerCase() == _selectedCategory.toLowerCase()).toList();
      }

      // Hide rejected ones from the main feed
      _filteredArticles = filtered.where((a) {
        final state = AiPipelineService().getState(a.id);
        return state.status != 'rejected';
      }).toList();
    });
  }

  void _prefetchTranslations(int currentIndex) async {
    final prefs = await SharedPreferences.getInstance();
    final prefetchCount = prefs.getInt('llm_prefetch_count') ?? 10;
    final maxIndex = currentIndex + prefetchCount;

    for (int i = currentIndex; i < maxIndex && i < _filteredArticles.length; i++) {
      final article = _filteredArticles[i];
      TranslationService().getTranslation(
        article.id,
        article.title ?? '',
        article.content ?? article.description ?? '',
      ); // Ignoring the future intentionally, letting it run and cache in background
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('folo_session_token');
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => LoginScreen()),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsScreen()),
    );
  }

  void _openAiFilterBox() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FilterBoxScreen(
          client: _client,
          articles: _articles, // pass all fetched articles so it can find the rejected ones
        ),
      ),
    ).then((_) {
      // Reload on return to remove restored/deleted articles from home screen list
      _fetchArticles();
    });
  }

  Future<void> _triggerAiPipeline() async {
    if (_articles.isEmpty) return;

    // 1. Show processing
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text("Processing Pipeline..."),
          ],
        ),
      )
    );

    await AiPipelineService().init();

    if (!mounted) return;
    Navigator.pop(context); // close dialog

    // 2. Similarity Screen
    // Pass to similarity screen. Similarity screen handles background jaccard and UI.
    // It returns the kept articles.
    List<FollowArticle>? similarityKept;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SimilarityScreen(
          articles: _articles,
          client: _client,
          onResolved: (kept) {
             similarityKept = kept;
          },
        ),
      ),
    );

    if (similarityKept == null || !mounted) return; // cancelled or aborted

    // 3. AI Analysis on the kept ones
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text("AI Analyzing..."),
          ],
        ),
      )
    );

    int count = 0;
    for (var article in similarityKept!) {
      final state = AiPipelineService().getState(article.id);
      if (state.status == 'pending') {
         await AiPipelineService().analyzeArticle(
           article.id,
           article.title ?? '',
           article.content ?? article.description ?? ''
         );
         count++;
      }
    }

    if (!mounted) return;
    Navigator.pop(context); // close dialog

    // refresh list and show filter box
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Analyzed $count new articles.')),
    );
    _openAiFilterBox();
  }

  Future<void> _handleRefresh() async {
    try {
      final newArticles = await _client.fetchArticles(isRead: _showReadArticles);

      if (!mounted) return;

      setState(() {
        // Merge and deduplicate
        final Map<String, FollowArticle> articleMap = {};
        for (var a in _articles) {
          articleMap[a.id] = a;
        }

        int addedCount = 0;
        for (var a in newArticles) {
          if (!articleMap.containsKey(a.id)) {
            articleMap[a.id] = a;
            addedCount++;
          }
        }

        _articles = articleMap.values.toList();

        // Sort by publishedAt descending (newest first)
        _articles.sort((a, b) {
          final timeA = DateTime.tryParse(a.publishedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b.publishedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeB.compareTo(timeA);
        });

        _applyFilter();

        if (addedCount > 0) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$addedCount new articles available, list updated.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to refresh: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Folo Read'),
        actions: [
          DropdownButton<String>(
            value: _selectedCategory,
            dropdownColor: Theme.of(context).primaryColorLight,
            underline: SizedBox(),
            icon: Icon(Icons.filter_list, color: Colors.black87),
            onChanged: (String? newValue) {
              if (newValue != null) {
                _selectedCategory = newValue;
                _applyFilter();
              }
            },
            items: <String>['All', 'Feeds', 'Social', 'Inbox']
                .map<DropdownMenuItem<String>>((String value) {
              return DropdownMenuItem<String>(
                value: value,
                child: Text(value),
              );
            }).toList(),
          ),
          IconButton(
            icon: Icon(Icons.auto_awesome),
            tooltip: 'AI Analysis',
            onPressed: _triggerAiPipeline,
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
              ),
              child: Text(
                'Folo Read',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                ),
              ),
            ),
            ListTile(
              leading: Icon(_showReadArticles ? Icons.visibility : Icons.visibility_off),
              title: Text(_showReadArticles ? 'Viewing Read' : 'Viewing Unread'),
              onTap: () {
                Navigator.pop(context);
                setState(() {
                  _showReadArticles = !_showReadArticles;
                });
                _fetchArticles();
              },
            ),
            ListTile(
              leading: Icon(Icons.inbox),
              title: Text('AI Filter Box'),
              onTap: () {
                Navigator.pop(context);
                _openAiFilterBox();
              },
            ),
            ListTile(
              leading: Icon(Icons.settings),
              title: Text('Settings'),
              onTap: () {
                Navigator.pop(context);
                _openSettings();
              },
            ),
            ListTile(
              leading: Icon(Icons.logout),
              title: Text('Logout'),
              onTap: () {
                Navigator.pop(context);
                _logout();
              },
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, style: TextStyle(color: Colors.red)),
            ElevatedButton(
              onPressed: _fetchArticles,
              child: Text('Retry'),
            )
          ],
        ),
      );
    }

    if (_filteredArticles.isEmpty) {
      final statusText = _showReadArticles ? 'read' : 'unread';
      return Center(child: Text('No $statusText articles for $_selectedCategory!'));
    }

    return ListView.builder(
      itemCount: _filteredArticles.length,
      itemBuilder: (context, index) {
        if (index % 5 == 0) {
          // prefetch occasionally as they scroll
          _prefetchTranslations(index);
        }
        final article = _filteredArticles[index];
        return ArticleCard(
          key: ValueKey(article.id),
          article: article,
          client: _client,
          onMarkedRead: () => _markArticleAsRead(article, index),
        );
      },
    );
  }
}
