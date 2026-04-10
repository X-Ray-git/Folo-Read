import 'dart:convert';
import 'package:flutter/foundation.dart';
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
        final uri = Uri.parse('$apiUrl/entries');
        debugPrint('POST $uri (view=$viewType)');
        final response = await http.post(
          uri,
          headers: _headers,
          body: jsonEncode({
            'read': false,
            'limit': limit,
            'view': viewType,
            'withContent': true,
          }),
        );

        if (response.statusCode == 200) {
          debugPrint('Success fetching entries (view=$viewType)');
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
          debugPrint('Error fetching entries (view=$viewType): ${response.statusCode}');
          debugPrint('Response body: ${response.body}');
        }
      } catch (e) {
        debugPrint('Exception fetching entries: $e');
      }
    }

    return allArticles;
  }

  Future<Map<String, dynamic>> _fetchSubscriptions() async {
    final Map<String, int> feedViewMap = {};

    try {
      final uri = Uri.parse('$apiUrl/subscriptions');
      debugPrint('GET $uri');
      final response = await http.get(
        uri,
        headers: _headers,
      );

      if (response.statusCode == 200) {
        debugPrint('Success fetching subscriptions');
        final data = jsonDecode(response.body);
        if (data['data'] != null && data['data'] is List) {
          for (var sub in data['data']) {
            if (sub['feedId'] != null && sub['view'] != null) {
              feedViewMap[sub['feedId']] = sub['view'];
            }
          }
        }
      } else {
        debugPrint('Error fetching subscriptions: ${response.statusCode}');
        debugPrint('Response body: ${response.body}');
      }
    } catch (e) {
      debugPrint('Exception fetching subscriptions: $e');
    }

    return {
      'feedViewMap': feedViewMap,
    };
  }

  Future<bool> markAsRead(String entryId, {bool isInbox = false}) async {
    if (!hasToken) throw Exception('Session token not set');

    try {
      final uri = Uri.parse('$apiUrl/reads');
      debugPrint('POST $uri (entryId=$entryId, isInbox=$isInbox)');
      final response = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode({
          'entryIds': [entryId],
          'isInbox': isInbox,
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('Successfully marked entry as read');
        return true;
      } else {
        debugPrint('Error marking as read: ${response.statusCode}');
        debugPrint('Response body: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('Exception marking as read: $e');
      return false;
    }
  }
}
