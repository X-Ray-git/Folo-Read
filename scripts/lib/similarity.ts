/**
 * Similarity Detection Module
 * 
 * Provides pluggable similarity strategies for content deduplication.
 * Currently supports Jaccard similarity, designed for easy extension
 * to more advanced methods (TF-IDF, embeddings, etc.)
 */

// ============================================
// Core Interfaces - DO NOT MODIFY
// ============================================

export interface SimilarityMatch {
  id: string;
  score: number;
  title?: string;
}

export interface SimilarityStrategy {
  readonly name: string;
  
  /**
   * Compute similarity between two texts
   * @returns A score between 0 (completely different) and 1 (identical)
   */
  computeSimilarity(textA: string, textB: string): number;
  
  /**
   * Find all similar items above threshold
   * @param target - The text to compare against
   * @param candidates - Array of {id, text} to search through
   * @param threshold - Minimum similarity score (0-1)
   */
  findSimilar(
    target: string,
    candidates: Array<{ id: string; text: string; title?: string }>,
    threshold: number
  ): SimilarityMatch[];
}

// ============================================
// Jaccard Similarity Implementation
// ============================================

export class JaccardSimilarity implements SimilarityStrategy {
  readonly name = 'jaccard';
  
  private ngramSize: number;
  
  constructor(options: { ngramSize?: number } = {}) {
    // Use character n-grams for better handling of Chinese text
    this.ngramSize = options.ngramSize ?? 2;
  }
  
  /**
   * Tokenize text into n-grams (works for both Chinese and English)
   */
  private tokenize(text: string): Set<string> {
    // Normalize: lowercase, remove extra whitespace
    const normalized = text.toLowerCase().replace(/\s+/g, ' ').trim();
    
    const tokens = new Set<string>();
    
    // Generate character n-grams
    for (let i = 0; i <= normalized.length - this.ngramSize; i++) {
      tokens.add(normalized.substring(i, i + this.ngramSize));
    }
    
    return tokens;
  }
  
  /**
   * Jaccard Index = |A ∩ B| / |A ∪ B|
   */
  computeSimilarity(textA: string, textB: string): number {
    const setA = this.tokenize(textA);
    const setB = this.tokenize(textB);
    
    if (setA.size === 0 && setB.size === 0) return 1;
    if (setA.size === 0 || setB.size === 0) return 0;
    
    let intersection = 0;
    for (const token of setA) {
      if (setB.has(token)) intersection++;
    }
    
    const union = setA.size + setB.size - intersection;
    return intersection / union;
  }
  
  findSimilar(
    target: string,
    candidates: Array<{ id: string; text: string; title?: string }>,
    threshold: number
  ): SimilarityMatch[] {
    const matches: SimilarityMatch[] = [];
    
    for (const candidate of candidates) {
      const score = this.computeSimilarity(target, candidate.text);
      if (score >= threshold) {
        matches.push({
          id: candidate.id,
          score,
          title: candidate.title,
        });
      }
    }
    
    // Sort by score descending
    return matches.sort((a, b) => b.score - a.score);
  }
}

// ============================================
// Future: Embedding Similarity (placeholder)
// ============================================

// export class EmbeddingSimilarity implements SimilarityStrategy {
//   readonly name = 'embedding';
//   
//   constructor(options: { model?: string; apiUrl?: string } = {}) {
//     // Initialize embedding API client
//   }
//   
//   async computeEmbedding(text: string): Promise<number[]> {
//     // Call embedding API
//   }
//   
//   computeSimilarity(textA: string, textB: string): number {
//     // Cosine similarity of embeddings
//   }
//   
//   findSimilar(...) { ... }
// }

// ============================================
// Strategy Factory
// ============================================

export type StrategyType = 'jaccard' | 'embedding';

export interface SimilarityConfig {
  strategy: StrategyType;
  threshold: number;
  options?: Record<string, unknown>;
}

const DEFAULT_CONFIG: SimilarityConfig = {
  strategy: 'jaccard',
  threshold: 0.7,
  options: { ngramSize: 2 },
};

export function createSimilarityStrategy(
  config: Partial<SimilarityConfig> = {}
): SimilarityStrategy {
  const merged = { ...DEFAULT_CONFIG, ...config };
  
  switch (merged.strategy) {
    case 'jaccard':
      return new JaccardSimilarity(merged.options as { ngramSize?: number });
    
    case 'embedding':
      throw new Error('Embedding similarity not yet implemented');
    
    default:
      throw new Error(`Unknown similarity strategy: ${merged.strategy}`);
  }
}
