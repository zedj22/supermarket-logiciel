// Documentation Center — chapter/article registry (Phase 3).
//
// Adding a Phase 4 chapter is: (1) write its content keys in
// doc_content.dart for all three locales, (2) append a DocChapter here.
// The screen, search and tests pick it up automatically.
import 'package:flutter/material.dart' show Icons;

import 'doc_models.dart';

/// All registered chapters, in reading order.
final List<DocChapter> docChapters = <DocChapter>[
  DocChapter(
    id: 'getting_started',
    titleKey: 'chapter.getting_started.title',
    icon: Icons.rocket_launch_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'gs_first_launch',
        chapterId: 'getting_started',
        titleKey: 'gs_first_launch.title',
        summaryKey: 'gs_first_launch.summary',
        sections: <DocSection>[
          DocSection(
            id: 'role',
            headingKey: 'gs_first_launch.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('gs_first_launch.s1.p1'),
              DocBlock.steps(<String>[
                'gs_first_launch.s1.step1',
                'gs_first_launch.s1.step2',
              ]),
              DocBlock.tip('gs_first_launch.s1.tip1'),
            ],
          ),
          DocSection(
            id: 'pairing',
            headingKey: 'gs_first_launch.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'gs_first_launch.s2.step1',
                'gs_first_launch.s2.step2',
                'gs_first_launch.s2.step3',
                'gs_first_launch.s2.step4',
              ]),
            ],
          ),
          DocSection(
            id: 'prerequisites',
            headingKey: 'gs_first_launch.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('gs_first_launch.s3.p1'),
              DocBlock.warning('gs_first_launch.s3.warn1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'gs_admin_login',
        chapterId: 'getting_started',
        titleKey: 'gs_admin_login.title',
        summaryKey: 'gs_admin_login.summary',
        sections: <DocSection>[
          DocSection(
            id: 'first-admin',
            headingKey: 'gs_admin_login.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('gs_admin_login.s1.p1'),
              DocBlock.warning('gs_admin_login.s1.warn1'),
            ],
          ),
          DocSection(
            id: 'signing-in',
            headingKey: 'gs_admin_login.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('gs_admin_login.s2.p1'),
              DocBlock.paragraph('gs_admin_login.s2.p2'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'gs_navigation',
        chapterId: 'getting_started',
        titleKey: 'gs_navigation.title',
        summaryKey: 'gs_navigation.summary',
        sections: <DocSection>[
          DocSection(
            id: 'rail',
            headingKey: 'gs_navigation.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('gs_navigation.s1.p1'),
            ],
          ),
          DocSection(
            id: 'sections',
            headingKey: 'gs_navigation.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'gs_navigation.s2.step1',
                'gs_navigation.s2.step2',
                'gs_navigation.s2.step3',
                'gs_navigation.s2.step4',
              ]),
              DocBlock.tip('gs_navigation.s2.tip1'),
            ],
          ),
          DocSection(
            id: 'help',
            headingKey: 'gs_navigation.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('gs_navigation.s3.p1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'gs_workflow',
        chapterId: 'getting_started',
        titleKey: 'gs_workflow.title',
        summaryKey: 'gs_workflow.summary',
        sections: <DocSection>[
          DocSection(
            id: 'order',
            headingKey: 'gs_workflow.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'gs_workflow.s1.step1',
                'gs_workflow.s1.step2',
                'gs_workflow.s1.step3',
                'gs_workflow.s1.step4',
                'gs_workflow.s1.step5',
                'gs_workflow.s1.step6',
              ]),
              DocBlock.tip('gs_workflow.s1.tip1'),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'dashboard',
    titleKey: 'chapter.dashboard.title',
    icon: Icons.dashboard_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'dash_overview',
        chapterId: 'dashboard',
        titleKey: 'dash_overview.title',
        summaryKey: 'dash_overview.summary',
        sections: <DocSection>[
          DocSection(
            id: 'purpose',
            headingKey: 'dash_overview.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('dash_overview.s1.p1'),
              DocBlock.paragraph('dash_overview.s1.p2'),
            ],
          ),
          DocSection(
            id: 'cards',
            headingKey: 'dash_overview.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('dash_overview.s2.p1'),
              DocBlock.tip('dash_overview.s2.tip1'),
            ],
          ),
          DocSection(
            id: 'lists',
            headingKey: 'dash_overview.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('dash_overview.s3.p1'),
              DocBlock.paragraph('dash_overview.s3.p2'),
              DocBlock.warning('dash_overview.s3.warn1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'dash_controls',
        chapterId: 'dashboard',
        titleKey: 'dash_controls.title',
        summaryKey: 'dash_controls.summary',
        sections: <DocSection>[
          DocSection(
            id: 'period',
            headingKey: 'dash_controls.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('dash_controls.s1.p1'),
              DocBlock.paragraph('dash_controls.s1.p2'),
            ],
          ),
          DocSection(
            id: 'actions',
            headingKey: 'dash_controls.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'dash_controls.s2.step1',
                'dash_controls.s2.step2',
                'dash_controls.s2.step3',
              ]),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'pos',
    titleKey: 'chapter.pos.title',
    icon: Icons.point_of_sale_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'pos_opening',
        chapterId: 'pos',
        titleKey: 'pos_opening.title',
        summaryKey: 'pos_opening.summary',
        sections: <DocSection>[
          DocSection(
            id: 'open',
            headingKey: 'pos_opening.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_opening.s1.p1'),
            ],
          ),
          DocSection(
            id: 'layout',
            headingKey: 'pos_opening.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'pos_opening.s2.step1',
                'pos_opening.s2.step2',
                'pos_opening.s2.step3',
                'pos_opening.s2.step4',
              ]),
            ],
          ),
          DocSection(
            id: 'adding',
            headingKey: 'pos_opening.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_opening.s3.p1'),
              DocBlock.warning('pos_opening.s3.warn1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'pos_selling',
        chapterId: 'pos',
        titleKey: 'pos_selling.title',
        summaryKey: 'pos_selling.summary',
        sections: <DocSection>[
          DocSection(
            id: 'variants',
            headingKey: 'pos_selling.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_selling.s1.p1'),
              DocBlock.paragraph('pos_selling.s1.p2'),
            ],
          ),
          DocSection(
            id: 'quantities',
            headingKey: 'pos_selling.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'pos_selling.s2.step1',
                'pos_selling.s2.step2',
                'pos_selling.s2.step3',
              ]),
              DocBlock.tip('pos_selling.s2.tip1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'pos_pricing',
        chapterId: 'pos',
        titleKey: 'pos_pricing.title',
        summaryKey: 'pos_pricing.summary',
        sections: <DocSection>[
          DocSection(
            id: 'automatic',
            headingKey: 'pos_pricing.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_pricing.s1.p1'),
              DocBlock.paragraph('pos_pricing.s1.p2'),
              DocBlock.warning('pos_pricing.s1.warn1'),
            ],
          ),
          DocSection(
            id: 'discounts',
            headingKey: 'pos_pricing.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_pricing.s2.p1'),
              DocBlock.paragraph('pos_pricing.s2.p2'),
            ],
          ),
          DocSection(
            id: 'totals',
            headingKey: 'pos_pricing.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_pricing.s3.p1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'pos_payment',
        chapterId: 'pos',
        titleKey: 'pos_payment.title',
        summaryKey: 'pos_payment.summary',
        sections: <DocSection>[
          DocSection(
            id: 'open',
            headingKey: 'pos_payment.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_payment.s1.p1'),
            ],
          ),
          DocSection(
            id: 'methods',
            headingKey: 'pos_payment.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'pos_payment.s2.step1',
                'pos_payment.s2.step2',
                'pos_payment.s2.step3',
                'pos_payment.s2.step4',
              ]),
            ],
          ),
          DocSection(
            id: 'safety',
            headingKey: 'pos_payment.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_payment.s3.p1'),
              DocBlock.paragraph('pos_payment.s3.p2'),
              DocBlock.paragraph('pos_payment.s3.p3'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'pos_printing',
        chapterId: 'pos',
        titleKey: 'pos_printing.title',
        summaryKey: 'pos_printing.summary',
        sections: <DocSection>[
          DocSection(
            id: 'settings',
            headingKey: 'pos_printing.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_printing.s1.p1'),
            ],
          ),
          DocSection(
            id: 'after-sale',
            headingKey: 'pos_printing.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_printing.s2.p1'),
              DocBlock.warning('pos_printing.s2.warn1'),
            ],
          ),
          DocSection(
            id: 'reprint',
            headingKey: 'pos_printing.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_printing.s3.p1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'pos_history',
        chapterId: 'pos',
        titleKey: 'pos_history.title',
        summaryKey: 'pos_history.summary',
        sections: <DocSection>[
          DocSection(
            id: 'opening',
            headingKey: 'pos_history.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_history.s1.p1'),
              DocBlock.warning('pos_history.s1.warn1'),
            ],
          ),
          DocSection(
            id: 'details',
            headingKey: 'pos_history.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_history.s2.p1'),
            ],
          ),
          DocSection(
            id: 'actions',
            headingKey: 'pos_history.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'pos_history.s3.step1',
                'pos_history.s3.step2',
                'pos_history.s3.step3',
                'pos_history.s3.step4',
              ]),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'pos_shortcuts',
        chapterId: 'pos',
        titleKey: 'pos_shortcuts.title',
        summaryKey: 'pos_shortcuts.summary',
        sections: <DocSection>[
          DocSection(
            id: 'global',
            headingKey: 'pos_shortcuts.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'pos_shortcuts.s1.step1',
                'pos_shortcuts.s1.step2',
                'pos_shortcuts.s1.step3',
                'pos_shortcuts.s1.step4',
                'pos_shortcuts.s1.step5',
                'pos_shortcuts.s1.step6',
              ]),
            ],
          ),
          DocSection(
            id: 'pos',
            headingKey: 'pos_shortcuts.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'pos_shortcuts.s2.step1',
                'pos_shortcuts.s2.step2',
                'pos_shortcuts.s2.step3',
                'pos_shortcuts.s2.step4',
                'pos_shortcuts.s2.step5',
                'pos_shortcuts.s2.step6',
                'pos_shortcuts.s2.step7',
                'pos_shortcuts.s2.step8',
                'pos_shortcuts.s2.step9',
              ]),
              DocBlock.tip('pos_shortcuts.s2.tip1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'pos_returns',
        chapterId: 'pos',
        titleKey: 'pos_returns.title',
        summaryKey: 'pos_returns.summary',
        sections: <DocSection>[
          DocSection(
            id: 'entry',
            headingKey: 'pos_returns.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_returns.s1.p1'),
            ],
          ),
          DocSection(
            id: 'confirm',
            headingKey: 'pos_returns.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_returns.s2.p1'),
              DocBlock.steps(<String>[
                'pos_returns.s2.step1',
                'pos_returns.s2.step2',
              ]),
              DocBlock.warning('pos_returns.s2.warn1'),
            ],
          ),
          DocSection(
            id: 'after',
            headingKey: 'pos_returns.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('pos_returns.s3.p1'),
            ],
          ),
        ],
      ),
    ],
  ),
];

/// Every article in reading order (chapter order, then article order).
List<DocArticle> allDocArticles() => <DocArticle>[
      for (final chapter in docChapters) ...chapter.articles,
    ];

DocChapter? findDocChapter(String id) {
  for (final chapter in docChapters) {
    if (chapter.id == id) return chapter;
  }
  return null;
}

DocArticle? findDocArticle(String id) {
  for (final article in allDocArticles()) {
    if (article.id == id) return article;
  }
  return null;
}

/// Article immediately before/after [id] in global reading order.
/// Returns null at the ends.
String? adjacentDocArticleId(String id, {required bool next}) {
  final ids = <String>[for (final a in allDocArticles()) a.id];
  final index = ids.indexOf(id);
  if (index < 0) return null;
  if (next) {
    return index + 1 < ids.length ? ids[index + 1] : null;
  }
  return index > 0 ? ids[index - 1] : null;
}

/// All content keys referenced by the registry — used by tests to prove
/// every key resolves in every locale.
Iterable<String> allDocContentKeys() sync* {
  for (final chapter in docChapters) {
    yield chapter.titleKey;
    for (final article in chapter.articles) {
      yield article.titleKey;
      yield article.summaryKey;
      for (final section in article.sections) {
        yield section.headingKey;
        for (final block in section.blocks) {
          if (block.kind == DocBlockKind.steps) {
            yield* block.steps;
          } else if (block.textKey != null) {
            yield block.textKey!;
          }
        }
      }
    }
  }
}
