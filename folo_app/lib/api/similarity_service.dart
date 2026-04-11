class SimilarityService {
  /// Calculate Jaccard similarity between two strings using character n-grams.
  static double calculateJaccard(String text1, String text2, {int nGramSize = 2}) {
    if (text1.isEmpty || text2.isEmpty) return 0.0;

    final set1 = _getNGrams(text1, nGramSize);
    final set2 = _getNGrams(text2, nGramSize);

    if (set1.isEmpty && set2.isEmpty) return 1.0;
    if (set1.isEmpty || set2.isEmpty) return 0.0;

    final intersection = set1.intersection(set2).length;
    final union = set1.union(set2).length;

    return intersection / union;
  }

  static Set<String> _getNGrams(String text, int n) {
    // Basic normalization: lowercase, remove non-alphanumeric, strip html-like tags
    String normalized = text.toLowerCase()
        .replaceAll(RegExp(r'<[^>]+>'), ' ') // remove simple html tags
        .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]'), '') // keep only alphanumeric and chinese
        .trim();

    Set<String> nGrams = {};
    for (int i = 0; i <= normalized.length - n; i++) {
      nGrams.add(normalized.substring(i, i + n));
    }
    return nGrams;
  }
}
