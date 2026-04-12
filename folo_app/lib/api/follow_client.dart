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

  Future<List<FollowArticle>> fetchArticles({int limit = 20, bool isRead = false}) async {
    if (!hasToken) throw Exception('Session token not set');

    List<FollowArticle> allArticles = [];

    // 1. Fetch subscriptions to build feedViewMap
    final subscriptions = await _fetchSubscriptions();
    final feedViewMap = subscriptions['feedViewMap'] as Map<String, int>;

    // 2. Fetch Feed articles (view=0 for general, view=1 for social)
    for (int viewType in [0, 1]) {
      try {
        final uri = Uri.parse('$apiUrl/entries');
        debugPrint('POST $uri (view=$viewType, read=$isRead)');
        final response = await http.post(
          uri,
          headers: _headers,
          body: jsonEncode({
            'read': isRead,
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

    // 3. Fetch Inbox articles
    final inboxIds = await _fetchInboxIds();
    for (String inboxId in inboxIds) {
      try {
        final uri = Uri.parse('$apiUrl/entries/inbox');
        debugPrint('POST $uri (inboxId=$inboxId, read=$isRead)');

        bool hasMore = true;

        while (hasMore) {
          final Map<String, dynamic> body = {
            'inboxId': inboxId,
            'read': isRead,
            'limit': limit,
          };
          // cursor is initialized to null and only assigned if pagination was supported
          // for now we don't have pagination assignment so the warning is expected, we can keep it simple:
          // we are intentionally fetching only one page.

          final response = await http.post(
            uri,
            headers: _headers,
            body: jsonEncode(body),
          );

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            if (data['data'] == null || (data['data'] as List).isEmpty) {
              hasMore = false;
              break;
            }

            for (var item in data['data']) {
              final entryId = item['id'];

              // Fetch full content for inbox entry
              final fullEntryUri = Uri.parse('$apiUrl/entries/inbox?id=$entryId');
              final fullEntryRes = await http.get(fullEntryUri, headers: _headers);

              if (fullEntryRes.statusCode == 200) {
                final fullData = jsonDecode(fullEntryRes.body);
                if (fullData['data'] != null && fullData['data']['entries'] != null) {
                  final article = FollowArticle.fromJson(fullData['data']['entries'], 'inbox');
                  allArticles.add(article);
                }
              }

              // Only pull max 1 page per inbox per refresh for performance, otherwise we can get stuck if limit is large
              // For full pagination support we would use cursor from the item or pagination data
            }
            hasMore = false; // Just one page per inbox per fetch request

          } else {
            debugPrint('Error fetching inbox entries ($inboxId): ${response.statusCode}');
            hasMore = false;
          }
        }
      } catch (e) {
        debugPrint('Exception fetching inbox entries: $e');
      }
    }

    return allArticles;
  }

  Future<List<String>> _fetchInboxIds() async {
    final List<String> inboxIds = [];
    try {
      final uri = Uri.parse('$apiUrl/inboxes/list');
      debugPrint('GET $uri');
      final response = await http.get(uri, headers: _headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['data'] != null && data['data'] is List) {
          for (var inbox in data['data']) {
            if (inbox['id'] != null) {
              inboxIds.add(inbox['id'].toString());
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Exception fetching inboxes: $e');
    }
    return inboxIds;
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
