import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/follow_client.dart';
import '../api/models.dart';
import '../widgets/article_card.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FollowClient _client = FollowClient();
  List<FollowArticle> _articles = [];
  bool _isLoading = true;
  String? _error;

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
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load articles: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('folo_session_token');
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Folo Read'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _isLoading ? null : _fetchArticles,
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

    if (_articles.isEmpty) {
      return Center(child: Text('No unread articles!'));
    }

    return ListView.builder(
      itemCount: _articles.length,
      itemBuilder: (context, index) {
        return ArticleCard(
          article: _articles[index],
          client: _client,
          onMarkedRead: () {
            setState(() {
              _articles.removeAt(index);
            });
          },
        );
      },
    );
  }
}
