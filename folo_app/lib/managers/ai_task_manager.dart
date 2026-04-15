import '../api/models.dart';
import '../api/similarity_service.dart';
import '../api/ai_pipeline_service.dart';
import 'package:flutter/material.dart';
import '../main.dart';

class SimilarityGroup {
  final List<FollowArticle> articles;
  SimilarityGroup(this.articles);
}

class AiTaskManager extends ChangeNotifier {
  static final AiTaskManager _instance = AiTaskManager._internal();

  factory AiTaskManager() {
    return _instance;
  }

  AiTaskManager._internal();

  bool isRunning = false;
  bool isCheckingSimilarity = false;

  int totalToAnalyze = 0;
  int analyzedCount = 0;

  List<SimilarityGroup> pendingResolutionGroups = [];
  List<FollowArticle> _llmQueue = [];

  VoidCallback? onOpenFilterBox;

  void init() {
    // Initialization if necessary, kept empty for now
  }

  Future<void> startAnalysis(List<FollowArticle> unreadArticles) async {
    if (isRunning) return;

    // Filter out articles that have already been analyzed or rejected
    final toProcess = unreadArticles.where((a) {
      final state = AiPipelineService().getState(a.id);
      return state.status == 'pending';
    }).toList();

    if (toProcess.isEmpty) return;

    isRunning = true;
    isCheckingSimilarity = true;
    totalToAnalyze = toProcess.length;
    analyzedCount = 0;
    pendingResolutionGroups.clear();
    _llmQueue.clear();
    notifyListeners();

    await _runSimilarityCheckAndSplit(toProcess);

    isCheckingSimilarity = false;
    notifyListeners();

    _processLlmQueue(); // start processing the unique ones immediately
  }

  Future<void> _runSimilarityCheckAndSplit(List<FollowArticle> articles) async {
    List<FollowArticle> unassigned = List.from(articles);
    List<SimilarityGroup> newGroups = [];
    List<FollowArticle> uniqueArticles = [];

    while (unassigned.isNotEmpty) {
      final current = unassigned.removeAt(0);
      final group = [current];

      final currentText = '${current.title} ${current.content ?? current.description ?? ''}';

      for (int i = unassigned.length - 1; i >= 0; i--) {
        final other = unassigned[i];
        final otherText = '${other.title} ${other.content ?? other.description ?? ''}';

        final similarity = SimilarityService.calculateJaccard(currentText, otherText);
        if (similarity >= 0.85) {
          group.add(unassigned.removeAt(i));
        }
      }

      if (group.length > 1) {
        newGroups.add(SimilarityGroup(group));
      } else {
        uniqueArticles.add(current);
      }
    }

    pendingResolutionGroups = newGroups;
    _llmQueue.addAll(uniqueArticles);
  }

  Future<void> _processLlmQueue() async {
    final int maxConcurrency = 64;

    while (_llmQueue.isNotEmpty) {
      final chunk = _llmQueue.take(maxConcurrency).toList();
      _llmQueue.removeRange(0, chunk.length);

      final futures = chunk.map((article) async {
        await AiPipelineService().analyzeArticle(
          article.id,
          article.title ?? '',
          article.content ?? article.description ?? '',
        );
        analyzedCount++;
        notifyListeners();
      });

      await Future.wait(futures);
    }

    _checkCompletion();
  }

  void resumeWithResolvedArticles(List<FollowArticle> keptArticles) {
    _llmQueue.addAll(keptArticles);
    pendingResolutionGroups.clear();
    notifyListeners();

    if (!isRunning) {
      isRunning = true;
    }
    _processLlmQueue();
  }

  void markResolutionAborted() {
    // If they cancel the similarity screen, we still need to clear the groups
    // or adjust the total count so the progress bar finishes.
    int skippedCount = 0;
    for (var g in pendingResolutionGroups) {
      skippedCount += g.articles.length;
    }

    totalToAnalyze -= skippedCount;
    pendingResolutionGroups.clear();
    notifyListeners();
    _checkCompletion();
  }

  void _checkCompletion() {
    if (_llmQueue.isEmpty && pendingResolutionGroups.isEmpty) {
      isRunning = false;
      notifyListeners();

      // Notify globally
      globalMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('AI 分析完成 (已分析 $analyzedCount 篇)，点击查看过滤箱。'),
          duration: Duration(seconds: 3),
          action: SnackBarAction(
            label: '查看',
            onPressed: () {
              globalMessengerKey.currentState?.hideCurrentSnackBar();
              if (onOpenFilterBox != null) {
                onOpenFilterBox!();
              }
            },
          ),
        ),
      );
    }
  }
}
