import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

class FollowClient {
  final String apiUrl;
  String _sessionToken = '';

  FollowClient({this.apiUrl = 'https://api.follow.is'});

  void setToken(String token) {
    _sessionToken = Uri.decodeComponent(token);
  }

  bool get hasToken => _sessionToken.isNotEmpty;

  Map<String, String> get _headers {
    final cookieName = apiUrl.contains('https')
        ? '__Secure-better-auth.session_token'
        : 'better-auth.session_token';
    return {
      'Content-Type': 'application/json',
      'Cookie': '$cookieName=$_sessionToken',
      'User-Agent': 'Folo-Android-App/1.0',
      'Accept': 'application/json',
    };
  }

  Future<List<FollowArticle>> fetchUnreadArticles({int limit = 20}) async {
    if (!hasToken) throw Exception('Session token not set');

    List<FollowArticle> allArticles = [];

    // 1. Fetch subscriptions to build feedViewMap
    final subscriptions = await _fetchSubscriptions();
    final feedViewMap = subscriptions['feedViewMap'] as Map<String, int>;

    // 2. Fetch Feed articles (view=0 for general, view=1 for social)
    for (int viewType in [0, 1]) {
      try {
        final response = await http.post(
          Uri.parse('$apiUrl/entries'),
          headers: _headers,
          body: jsonEncode({
            'read': false,
            'limit': limit,
            'view': viewType,
            'withContent': true,
          }),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['data'] != null && data['data'] is List) {
            for (var item in data['data']) {
              final entries = item['entries'];
              final feedId = item['feeds']?['id'];
              final subView = feedViewMap[feedId];

              String category = (subView == 1) ? 'social' : 'feeds';
              allArticles.add(FollowArticle.fromJson(entries, category));
            }
          }
        } else {
          print('Error fetching entries (view=$viewType): ${response.statusCode}');
        }
      } catch (e) {
        print('Exception fetching entries: $e');
      }
    }

    return allArticles;
  }

  Future<Map<String, dynamic>> _fetchSubscriptions() async {
    final Map<String, int> feedViewMap = {};

    try {
      final response = await http.get(
        Uri.parse('$apiUrl/subscriptions'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['data'] != null && data['data'] is List) {
          for (var sub in data['data']) {
            if (sub['feedId'] != null && sub['view'] != null) {
              feedViewMap[sub['feedId']] = sub['view'];
            }
          }
        }
      }
    } catch (e) {
      print('Exception fetching subscriptions: $e');
    }

    return {
      'feedViewMap': feedViewMap,
    };
  }

  Future<bool> markAsRead(String entryId, {bool isInbox = false}) async {
    if (!hasToken) throw Exception('Session token not set');

    try {
      final response = await http.post(
        Uri.parse('$apiUrl/reads'),
        headers: _headers,
        body: jsonEncode({
          'entryIds': [entryId],
          'isInbox': isInbox,
        }),
      );

      return response.statusCode == 200;
    } catch (e) {
      print('Error marking as read: $e');
      return false;
    }
  }
}
