import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ArticleState {
  final String id;
  String status; // 'pending', 'analyzed', 'kept', 'rejected'
  String? rejectReason;
  String? category;
  String? title;

  ArticleState({
    required this.id,
    this.status = 'pending',
    this.rejectReason,
    this.category,
    this.title,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'status': status,
        'rejectReason': rejectReason,
        'category': category,
        'title': title,
      };

  factory ArticleState.fromJson(Map<String, dynamic> json) {
    return ArticleState(
      id: json['id'] ?? '',
      status: json['status'] ?? 'pending',
      rejectReason: json['rejectReason'],
      category: json['category'],
      title: json['title'],
    );
  }
}

class AiPipelineService {
  static final AiPipelineService _instance = AiPipelineService._internal();

  factory AiPipelineService() {
    return _instance;
  }

  AiPipelineService._internal();

  Map<String, ArticleState> _states = {};
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await _loadStates();
    _initialized = true;
  }

  Future<File> _getStateFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/pipeline_states.json');
  }

  Future<void> _loadStates() async {
    try {
      final file = await _getStateFile();
      if (await file.exists()) {
        final jsonStr = await file.readAsString();
        final Map<String, dynamic> data = jsonDecode(jsonStr);
        _states = data.map((key, value) => MapEntry(key, ArticleState.fromJson(value)));
      }
    } catch (e) {
      debugPrint('Failed to load pipeline states: $e');
      _states = {};
    }
  }

  Future<void> _saveStates() async {
    try {
      final file = await _getStateFile();
      final Map<String, dynamic> data = _states.map((key, value) => MapEntry(key, value.toJson()));
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Failed to save pipeline states: $e');
    }
  }

  ArticleState getState(String id) {
    if (!_states.containsKey(id)) {
      _states[id] = ArticleState(id: id);
      _saveStates(); // save default pending state
    }
    return _states[id]!;
  }

  Future<void> updateState(String id, {
    String? status,
    String? rejectReason,
    String? category,
    String? title,
  }) async {
    final state = getState(id);
    if (status != null) state.status = status;
    if (rejectReason != null) state.rejectReason = rejectReason;
    if (category != null) state.category = category;
    if (title != null) state.title = title;

    await _saveStates();
  }

  List<ArticleState> getRejectedArticles() {
    return _states.values.where((s) => s.status == 'rejected').toList();
  }

  Future<void> removeState(String id) async {
    _states.remove(id);
    await _saveStates();
  }

  Future<bool> analyzeArticle(String id, String title, String content) async {
    final prefs = await SharedPreferences.getInstance();
    final apiUrl = prefs.getString('llm_api_url') ?? 'https://api.siliconflow.cn/v1/chat/completions';
    final apiKey = prefs.getString('llm_api_key') ?? '';
    final modelName = prefs.getString('llm_model_name') ?? 'Pro/MiniMaxAI/MiniMax-M2.5';

    if (apiKey.isEmpty) {
      debugPrint('LLM Analysis failed: API Key is not configured.');
      return false;
    }

    // Default prompt based on prompts.yaml from Folo-Read
    const systemPrompt = '''
你是一个专业的全智能技术前沿文章分析判定机器。
你的任务是快速判定给定的文章是否应当被过滤抛弃，并推断其语言，最终必须返回固定格式的JSON。

需要抛弃（隔离）的文章条件，注意，符合以下条件并不意味着文章是垃圾文章，只是与我们的技术领域不相关，因此即使文章内容质量很高，如果不适合我们，也应当被过滤抛弃：
1. 纯视觉模态（Vision AI、图像生成、视频生成/视觉世界模型、视频理解、图像编辑、GUI 操作、数字人等方向）。（例外：即使是图像有关，但若是关于医学影像处理的必须保留）。
2. 具身智能（如 VLA）、机器人控制技术领域、自动驾驶、点云、3D 感知等方向。
3. 加密货币、区块链、Web3 炒币技术，且不含其它技术内容。
4. 音频处理、音乐生成、语音识别（Audio TTS）等方向。
5. 纯粹的政治话题、军事新闻等无技术内涵的其他杂项。
6. 疑似夸张、炒作的内容。
7. 公司收购、融资等商业新闻（除非涉及技术创新或技术应用的内容）。
8. 个人宣传、营销推广、介绍公司产品的文章。
9. 非人工智能领域的其他技术领域（如数据库、操作系统、编程语言等），除非文章中同时涉及人工智能技术内容。

部分文章为新闻集合，如果其中仅有部分涉及上述内容，但仍然存在其它技术领域的，则不应当被过滤抛弃。
你的标准应当尽可能严格，因为我会进行二次过滤，所以只有被你认为非常相关的文章才会进入下一轮评审，因此请务必严格把关，宁可错杀也不要放过不相关的文章。

返回格式要求：
你必须返回一个合法的 JSON 数据（不要输出 Markdown 标记，直接输出 JSON）。具体格式如下：
{
  "language": "en" | "zh" | "ja" | "other",
  "should_reject": true | false,
  "reject_reason": "如果是 true 的话，给出命中的简短原因（如 Crypto/Vision AI等）",
  "category": "文章大的所属分类，可简短一两词概括",
  "summary": "不超过200个字的一句话极简核心提炼，使用中文"
}
''';

    final cleanContent = content
        .replaceAll(RegExp(r'<[^>]+>'), ' ') // Strip HTML
        .replaceAll(RegExp(r'\s+'), ' ') // Normalize spaces
        .trim();

    final snippet = cleanContent.length > 10000 ? cleanContent.substring(0, 10000) : cleanContent;

    final userPrompt = '''请针对以下文章的内容特征，返回要求的 JSON 判定结果：
【文章标题】：$title
【内容截取】：
$snippet
''';

    try {
      var requestBody = {
        'model': modelName,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt}
        ],
        'response_format': {'type': 'json_object'},
        'temperature': 0.1,
      };

      var response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode(requestBody),
      );

      if (response.statusCode >= 400 && response.statusCode < 500) {
        debugPrint('LLM API Error with response_format, retrying without it...');
        requestBody.remove('response_format');
        response = await http.post(
          Uri.parse(apiUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(requestBody),
        );
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final responseContent = data['choices']?[0]?['message']?['content'];

        if (responseContent != null) {
          try {
            String cleanJson = responseContent.toString().trim();
            final startIndex = cleanJson.indexOf('{');
            final endIndex = cleanJson.lastIndexOf('}');

            if (startIndex != -1 && endIndex != -1 && endIndex >= startIndex) {
              cleanJson = cleanJson.substring(startIndex, endIndex + 1);
            }

            final jsonResult = jsonDecode(cleanJson.trim());

            final shouldReject = jsonResult['should_reject'] == true;
            final rejectReason = jsonResult['reject_reason']?.toString();
            final category = jsonResult['category']?.toString();

            await updateState(
              id,
              status: shouldReject ? 'rejected' : 'analyzed',
              rejectReason: rejectReason,
              category: category,
              title: title,
            );
            return true;
          } catch (parseError) {
             debugPrint('Failed to parse LLM Analysis JSON output: $parseError');
          }
        }
      } else {
        debugPrint('LLM Analysis API Error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('LLM Analysis Request Exception: $e');
    }
    return false;
  }
}
