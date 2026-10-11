// Documentation Center — typed content model (Phase 3).
//
// Documentation content is plain data: chapters contain ordered articles,
// articles contain ordered sections, sections contain typed blocks.
// Localized text lives in doc_content.dart keyed by stable string keys,
// so adding a Phase 4 chapter is a registry + content edit only — no
// presentation changes.
import 'package:flutter/material.dart' show IconData;

/// What kind of content a block carries.
enum DocBlockKind {
  paragraph,
  steps,
  tip,
  warning,
}

/// One paragraph, an ordered step list, a tip, or a warning.
class DocBlock {
  const DocBlock.paragraph(this.textKey)
      : kind = DocBlockKind.paragraph,
        steps = const [];

  const DocBlock.steps(List<String> stepKeys)
      : kind = DocBlockKind.steps,
        textKey = null,
        steps = stepKeys;

  const DocBlock.tip(this.textKey)
      : kind = DocBlockKind.tip,
        steps = const [];

  const DocBlock.warning(this.textKey)
      : kind = DocBlockKind.warning,
        steps = const [];

  final DocBlockKind kind;

  /// Content key for paragraph/tip/warning; null for steps.
  final String? textKey;

  /// Ordered content keys for [DocBlockKind.steps].
  final List<String> steps;
}

/// A titled group of blocks inside an article. The [id] is stable and
/// used as a search-result anchor.
class DocSection {
  const DocSection({
    required this.id,
    required this.headingKey,
    this.blocks = const [],
  });

  final String id;
  final String headingKey;
  final List<DocBlock> blocks;
}

/// One manual article. [id] is stable across releases (deep-link target).
class DocArticle {
  const DocArticle({
    required this.id,
    required this.chapterId,
    required this.titleKey,
    required this.summaryKey,
    this.sections = const [],
  });

  final String id;
  final String chapterId;
  final String titleKey;
  final String summaryKey;
  final List<DocSection> sections;

  /// Phase 4 hook: verified screenshot references. Never populated with
  /// real data captures — see Phase 3 §10 (demo dataset required).
  List<String> get screenshotRefs => const [];
}

/// One manual chapter with its ordered [articles].
class DocChapter {
  const DocChapter({
    required this.id,
    required this.titleKey,
    required this.icon,
    this.articles = const [],
  });

  final String id;
  final String titleKey;
  final IconData icon;
  final List<DocArticle> articles;
}
