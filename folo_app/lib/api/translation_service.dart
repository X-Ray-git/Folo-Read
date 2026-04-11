import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TranslatedArticle {
  final String title;
  final String content;

  TranslatedArticle({required this.title, required this.content});

  Map<String, dynamic> toJson() => {
        'title': title,
        'content': content,
      };

  factory TranslatedArticle.fromJson(Map<String, dynamic> json) {
    return TranslatedArticle(
      title: json['title'] ?? '',
      content: json['content'] ?? '',
    );
  }
}

class TranslationService {
  static final TranslationService _instance = TranslationService._internal();

  factory TranslationService() {
    return _instance;
  }

  TranslationService._internal();

  final Map<String, Future<TranslatedArticle?>> _activeRequests = {};

  Future<File> _getCacheFile(String articleId) async {
    final directory = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${directory.path}/translation_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return File('${cacheDir.path}/$articleId.json');
  }

  bool isMostlyChinese(String text) {
    if (text.isEmpty) return true;
    final chineseCharRegex = RegExp(r'[\u4e00-\u9fa5]');
    final matches = chineseCharRegex.allMatches(text);
    return (matches.length / text.length) > 0.3; // If > 30% of characters are Chinese, consider it Chinese
  }

  Future<TranslatedArticle?> getTranslation(String articleId, String title, String content) {
    if (_activeRequests.containsKey(articleId)) {
      return _activeRequests[articleId]!;
    }

    final request = _performTranslation(articleId, title, content).whenComplete(() {
      _activeRequests.remove(articleId);
    });

    _activeRequests[articleId] = request;
    return request;
  }

  Future<TranslatedArticle?> _performTranslation(String articleId, String title, String content) async {
    // 1. Check local cache
    final cacheFile = await _getCacheFile(articleId);
    if (await cacheFile.exists()) {
      try {
        final jsonStr = await cacheFile.readAsString();
        return TranslatedArticle.fromJson(jsonDecode(jsonStr));
      } catch (e) {
        debugPrint('Cache read error: $e');
      }
    }

    // 2. Check if text is mostly Chinese (Skip translation)
    final combinedText = '$title $content';
    if (isMostlyChinese(combinedText)) {
      final defaultTranslation = TranslatedArticle(title: title, content: content);
      _cacheTranslation(articleId, defaultTranslation);
      return defaultTranslation;
    }

    // 3. Proceed to API translation
    final prefs = await SharedPreferences.getInstance();
    final apiUrl = prefs.getString('llm_api_url') ?? 'https://api.siliconflow.cn/v1/chat/completions';
    final apiKey = prefs.getString('llm_api_key') ?? '';
    final modelName = prefs.getString('llm_model_name') ?? 'Pro/MiniMaxAI/MiniMax-M2.5';

    if (apiKey.isEmpty) {
      debugPrint('Translation failed: API Key is not configured.');
      return null;
    }

    return await _callLLM(articleId, title, content, apiUrl, apiKey, modelName);
  }

  Future<void> _cacheTranslation(String articleId, TranslatedArticle translation) async {
    try {
      final cacheFile = await _getCacheFile(articleId);
      await cacheFile.writeAsString(jsonEncode(translation.toJson()));
    } catch (e) {
      debugPrint('Cache write error: $e');
    }
  }

  Future<TranslatedArticle?> _callLLM(
      String articleId, String title, String content, String apiUrl, String apiKey, String modelName) async {
    const systemPrompt = '''
You are a highly skilled professional translator.
Your task is to translate the user's article from its source language to Chinese.
You must return a JSON object with two keys: "title" and "content".
For "title": Provide a bilingual string, with Chinese first and original language second, separated by a space or pipe (e.g., "你好 | Hello").
For "content": Translate the content into Chinese while PRESERVING ALL HTML TAGS, structure, attributes (like src, href), and images exactly as they appear in the source text.
Do not output markdown code blocks wrapping the json, just output raw JSON.
''';

    final userPrompt = '''
Title: $title
Content: $content
''';

    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': modelName,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userPrompt}
          ],
          'response_format': {'type': 'json_object'},
          'temperature': 0.1,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final responseContent = data['choices']?[0]?['message']?['content'];
        if (responseContent != null) {
          try {
             // Clean potential markdown blocks just in case
            String cleanJson = responseContent.toString().trim();
            if (cleanJson.startsWith('```json')) {
              cleanJson = cleanJson.replaceFirst('```json', '');
            }
            if (cleanJson.startsWith('```')) {
              cleanJson = cleanJson.replaceFirst('```', '');
            }
            if (cleanJson.endsWith('```')) {
              cleanJson = cleanJson.substring(0, cleanJson.length - 3);
            }

            final jsonResult = jsonDecode(cleanJson.trim());
            final translatedArticle = TranslatedArticle.fromJson(jsonResult);
            await _cacheTranslation(articleId, translatedArticle);
            return translatedArticle;
          } catch (parseError) {
             debugPrint('Failed to parse LLM JSON output: \$parseError');
             debugPrint('Raw LLM output: \$responseContent');
          }
        }
      } else {
        debugPrint('LLM API Error: \${response.statusCode} - \${response.body}');
      }
    } catch (e) {
      debugPrint('LLM Request Exception: $e');
    }
    return null;
  }
}
