import 'package:flutter/material.dart';
import '../api/models.dart';
import '../api/follow_client.dart';
import '../api/similarity_service.dart';

class SimilarityGroup {
  final List<FollowArticle> articles;
  SimilarityGroup(this.articles);
}

class SimilarityScreen extends StatefulWidget {
  final List<FollowArticle> articles;
  final FollowClient client;
  final Function(List<FollowArticle> keptArticles) onResolved;

  const SimilarityScreen({
    Key? key,
    required this.articles,
    required this.client,
    required this.onResolved,
  }) : super(key: key);

  @override
  _SimilarityScreenState createState() => _SimilarityScreenState();
}

class _SimilarityScreenState extends State<SimilarityScreen> {
  bool _isProcessing = true;
  List<SimilarityGroup> _groups = [];
  final Map<String, bool> _keepSelections = {}; // articleId -> true if selected to keep

  @override
  void initState() {
    super.initState();
    _processSimilarities();
  }

  Future<void> _processSimilarities() async {
    // Process in background
    await Future.delayed(Duration(milliseconds: 100));

    List<FollowArticle> unassigned = List.from(widget.articles);
    List<SimilarityGroup> newGroups = [];

    while (unassigned.isNotEmpty) {
      final current = unassigned.removeAt(0);
      final group = [current];

      final currentText = '${current.title} ${current.content ?? current.description ?? ''}';

      for (int i = unassigned.length - 1; i >= 0; i--) {
        final other = unassigned[i];
        final otherText = '${other.title} ${other.content ?? other.description ?? ''}';

        final similarity = SimilarityService.calculateJaccard(currentText, otherText);
        if (similarity >= 0.80) {
          group.add(unassigned.removeAt(i));
        }
      }

      // Only add groups with 2 or more items
      if (group.length > 1) {
        newGroups.add(SimilarityGroup(group));
        for (var a in group) {
          _keepSelections[a.id] = false; // By default, keep none or keep all? Let's default to keep oldest or nothing.
        }

        // Auto-select the oldest one by default
        if (group.isNotEmpty) {
          group.sort((a, b) {
            final timeA = DateTime.tryParse(a.publishedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
            final timeB = DateTime.tryParse(b.publishedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
            return timeA.compareTo(timeB); // oldest first
          });
          _keepSelections[group.first.id] = true;
        }
      }
    }

    if (!mounted) return;

    if (newGroups.isEmpty) {
      // No similarities found, instantly resolve keeping everything
      widget.onResolved(widget.articles);
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _groups = newGroups;
      _isProcessing = false;
    });
  }

  Future<void> _confirmResolution() async {
    setState(() {
      _isProcessing = true;
    });

    List<FollowArticle> finalKept = [];
    List<String> toMarkAsReadIds = [];

    // Articles not in any group are automatically kept
    Set<String> groupedIds = {};
    for (var g in _groups) {
      for (var a in g.articles) {
        groupedIds.add(a.id);
        if (_keepSelections[a.id] == true) {
          finalKept.add(a);
        } else {
          toMarkAsReadIds.add(a.id);
        }
      }
    }

    for (var a in widget.articles) {
      if (!groupedIds.contains(a.id)) {
        finalKept.add(a);
      }
    }

    // Process deletes (mark as read)
    for (var id in toMarkAsReadIds) {
      // Find article category to pass correctly to isInbox
      final article = widget.articles.firstWhere((a) => a.id == id);
      await widget.client.markAsRead(id, isInbox: article.category == 'inbox');
    }

    if (mounted) {
      widget.onResolved(finalKept);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isProcessing) {
      return Scaffold(
        appBar: AppBar(title: Text('Detecting Similarities...')),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Resolve Similar Articles'),
      ),
      body: ListView.builder(
        itemCount: _groups.length,
        itemBuilder: (context, groupIndex) {
          final group = _groups[groupIndex];
          return Card(
            margin: EdgeInsets.all(8.0),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Group ${groupIndex + 1} (${group.articles.length} similar items)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Divider(),
                  ...group.articles.map((article) {
                    return CheckboxListTile(
                      title: Text(article.title ?? 'Untitled', maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(article.author ?? article.category),
                      value: _keepSelections[article.id] ?? false,
                      onChanged: (bool? val) {
                        setState(() {
                          _keepSelections[article.id] = val ?? false;
                        });
                      },
                    );
                  }),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _confirmResolution,
        icon: Icon(Icons.check),
        label: Text('Confirm & Continue'),
      ),
    );
  }
}
