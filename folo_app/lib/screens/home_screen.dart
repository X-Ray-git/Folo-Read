import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/follow_client.dart';
import '../api/models.dart';
import '../widgets/article_card.dart';
import 'login_screen.dart';
import 'settings_screen.dart';
import '../api/translation_service.dart';

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
      final articles = await _client.fetchUnreadArticles();
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

  void _applyFilter() {
    setState(() {
      if (_selectedCategory == 'All') {
        _filteredArticles = List.from(_articles);
      } else {
        _filteredArticles = _articles.where((a) => a.category.toLowerCase() == _selectedCategory.toLowerCase()).toList();
      }
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
            icon: Icon(Icons.refresh),
            onPressed: _isLoading ? null : _fetchArticles,
          ),
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: _openSettings,
          ),
          IconButton(
            icon: Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: _buildBody(),
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
      return Center(child: Text('No unread articles for $_selectedCategory!'));
    }

    return ListView.builder(
      itemCount: _filteredArticles.length,
      itemBuilder: (context, index) {
        if (index % 5 == 0) {
          // prefetch occasionally as they scroll
          _prefetchTranslations(index);
        }
        return ArticleCard(
          key: ValueKey(_filteredArticles[index].id),
          article: _filteredArticles[index],
          client: _client,
          onMarkedRead: () {
            setState(() {
              _articles.removeWhere((a) => a.id == _filteredArticles[index].id);
              _filteredArticles.removeAt(index);
            });
          },
        );
      },
    );
  }
}
