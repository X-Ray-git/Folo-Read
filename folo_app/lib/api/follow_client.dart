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

  Future<List<FollowArticle>> fetchArticles({int limit = 20, bool isRead = false, String? cursor}) async {
    if (!hasToken) throw Exception('Session token not set');

    List<FollowArticle> allArticles = [];

    // 1. Fetch subscriptions to build feedViewMap
    final subscriptions = await _fetchSubscriptions();
    final feedViewMap = subscriptions['feedViewMap'] as Map<String, int>;

    // 2. Fetch Feed articles (view=0 for general, view=1 for social)
    for (int viewType in [0, 1]) {
      try {
        final uri = Uri.parse('$apiUrl/entries');
        debugPrint('POST $uri (view=$viewType, read=$isRead, cursor=$cursor)');

        final Map<String, dynamic> body = {
          'read': isRead,
          'limit': limit,
          'view': viewType,
          'withContent': true,
        };

        if (cursor != null) {
          body['publishedAfter'] = cursor;
        }

        final response = await http.post(
          uri,
          headers: _headers,
          body: jsonEncode(body),
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
    final List<String> unreadEntryIds = [];

    for (String inboxId in inboxIds) {
      try {
        final uri = Uri.parse('$apiUrl/entries/inbox');
        debugPrint('POST $uri (inboxId=$inboxId, read=$isRead, cursor=$cursor)');

        final Map<String, dynamic> body = {
          'inboxId': inboxId,
          'read': isRead,
          'limit': limit,
        };

        if (cursor != null) {
          body['publishedAfter'] = cursor;
        }

        final response = await http.post(
          uri,
          headers: _headers,
          body: jsonEncode(body),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['data'] != null && data['data'] is List) {
            for (var item in data['data']) {
              if (item['entries'] != null && item['entries']['id'] != null) {
                unreadEntryIds.add(item['entries']['id'].toString());
              }
            }
          }
        } else {
          debugPrint('Error fetching inbox entries ($inboxId): ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('Exception fetching inbox entries list: $e');
      }
    }

    debugPrint('Found ${unreadEntryIds.length} inbox entries. Fetching details concurrently...');

    // Fetch inbox article details concurrently
    final chunkedIds = _chunkList(unreadEntryIds, 5); // Fetch in chunks of 5 to avoid overwhelming the API
    for (var chunk in chunkedIds) {
      final List<Future<FollowArticle?>> fetchTasks = chunk.map((entryId) async {
        try {
          final uri = Uri.parse('$apiUrl/entries/inbox?id=$entryId');
          final response = await http.get(uri, headers: _headers);

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            if (data['data'] != null && data['data']['entries'] != null) {
              return FollowArticle.fromJson(data['data']['entries'], 'inbox');
            }
          }
        } catch (e) {
          debugPrint('Exception fetching full inbox entry $entryId: $e');
        }
        return null;
      }).toList();

      final results = await Future.wait(fetchTasks);
      for (var article in results) {
        if (article != null) {
          allArticles.add(article);
        }
      }
    }

    return allArticles;
  }

  List<List<T>> _chunkList<T>(List<T> list, int chunkSize) {
    List<List<T>> chunks = [];
    for (var i = 0; i < list.length; i += chunkSize) {
      chunks.add(list.sublist(i, i + chunkSize > list.length ? list.length : i + chunkSize));
    }
    return chunks;
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
