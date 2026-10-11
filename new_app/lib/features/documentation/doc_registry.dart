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
  DocChapter(
    id: 'products',
    titleKey: 'chapter.products.title',
    icon: Icons.inventory_2_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'cat_basics',
        chapterId: 'products',
        titleKey: 'cat_basics.title',
        summaryKey: 'cat_basics.summary',
        sections: <DocSection>[
          DocSection(
            id: 'creating',
            headingKey: 'cat_basics.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cat_basics.s1.p1'),
              DocBlock.steps(<String>[
                'cat_basics.s1.step1',
                'cat_basics.s1.step2',
                'cat_basics.s1.step3',
                'cat_basics.s1.step4',
              ]),
            ],
          ),
          DocSection(
            id: 'editing',
            headingKey: 'cat_basics.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cat_basics.s2.p1'),
              DocBlock.paragraph('cat_basics.s2.p2'),
            ],
          ),
          DocSection(
            id: 'searching',
            headingKey: 'cat_basics.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cat_basics.s3.p1'),
              DocBlock.tip('cat_basics.s3.tip1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'cat_children',
        chapterId: 'products',
        titleKey: 'cat_children.title',
        summaryKey: 'cat_children.summary',
        sections: <DocSection>[
          DocSection(
            id: 'selling-units',
            headingKey: 'cat_children.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cat_children.s1.p1'),
              DocBlock.steps(<String>[
                'cat_children.s1.step1',
                'cat_children.s1.step2',
                'cat_children.s1.step3',
              ]),
              DocBlock.warning('cat_children.s1.warn1'),
            ],
          ),
          DocSection(
            id: 'purchase-units',
            headingKey: 'cat_children.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cat_children.s2.p1'),
            ],
          ),
          DocSection(
            id: 'variants',
            headingKey: 'cat_children.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cat_children.s3.p1'),
              DocBlock.paragraph('cat_children.s3.p2'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'cat_pricing',
        chapterId: 'products',
        titleKey: 'cat_pricing.title',
        summaryKey: 'cat_pricing.summary',
        sections: <DocSection>[
          DocSection(
            id: 'wholesale',
            headingKey: 'cat_pricing.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cat_pricing.s1.p1'),
              DocBlock.paragraph('cat_pricing.s1.p2'),
            ],
          ),
          DocSection(
            id: 'promotions',
            headingKey: 'cat_pricing.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cat_pricing.s2.p1'),
              DocBlock.paragraph('cat_pricing.s2.p2'),
              DocBlock.warning('cat_pricing.s2.warn1'),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'inventory',
    titleKey: 'chapter.inventory.title',
    icon: Icons.warehouse_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'inv_levels',
        chapterId: 'inventory',
        titleKey: 'inv_levels.title',
        summaryKey: 'inv_levels.summary',
        sections: <DocSection>[
          DocSection(
            id: 'stock-screen',
            headingKey: 'inv_levels.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('inv_levels.s1.p1'),
              DocBlock.paragraph('inv_levels.s1.p2'),
            ],
          ),
          DocSection(
            id: 'product-detail',
            headingKey: 'inv_levels.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('inv_levels.s2.p1'),
              DocBlock.tip('inv_levels.s2.tip1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'inv_adjust',
        chapterId: 'inventory',
        titleKey: 'inv_adjust.title',
        summaryKey: 'inv_adjust.summary',
        sections: <DocSection>[
          DocSection(
            id: 'making-adjustment',
            headingKey: 'inv_adjust.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'inv_adjust.s1.step1',
                'inv_adjust.s1.step2',
                'inv_adjust.s1.step3',
                'inv_adjust.s1.step4',
              ]),
            ],
          ),
          DocSection(
            id: 'rules',
            headingKey: 'inv_adjust.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('inv_adjust.s2.p1'),
              DocBlock.paragraph('inv_adjust.s2.p2'),
              DocBlock.warning('inv_adjust.s2.warn1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'inv_movements',
        chapterId: 'inventory',
        titleKey: 'inv_movements.title',
        summaryKey: 'inv_movements.summary',
        sections: <DocSection>[
          DocSection(
            id: 'journal',
            headingKey: 'inv_movements.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('inv_movements.s1.p1'),
              DocBlock.paragraph('inv_movements.s1.p2'),
            ],
          ),
          DocSection(
            id: 'diagnosing',
            headingKey: 'inv_movements.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'inv_movements.s2.step1',
                'inv_movements.s2.step2',
                'inv_movements.s2.step3',
              ]),
              DocBlock.tip('inv_movements.s2.tip1'),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'purchasing',
    titleKey: 'chapter.purchasing.title',
    icon: Icons.shopping_cart_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'purch_suppliers',
        chapterId: 'purchasing',
        titleKey: 'purch_suppliers.title',
        summaryKey: 'purch_suppliers.summary',
        sections: <DocSection>[
          DocSection(
            id: 'records',
            headingKey: 'purch_suppliers.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('purch_suppliers.s1.p1'),
            ],
          ),
          DocSection(
            id: 'payments',
            headingKey: 'purch_suppliers.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('purch_suppliers.s2.p1'),
              DocBlock.paragraph('purch_suppliers.s2.p2'),
              DocBlock.warning('purch_suppliers.s2.warn1'),
            ],
          ),
          DocSection(
            id: 'permissions',
            headingKey: 'purch_suppliers.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('purch_suppliers.s3.p1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'purch_docs',
        chapterId: 'purchasing',
        titleKey: 'purch_docs.title',
        summaryKey: 'purch_docs.summary',
        sections: <DocSection>[
          DocSection(
            id: 'creating',
            headingKey: 'purch_docs.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'purch_docs.s1.step1',
                'purch_docs.s1.step2',
                'purch_docs.s1.step3',
              ]),
            ],
          ),
          DocSection(
            id: 'receiving',
            headingKey: 'purch_docs.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('purch_docs.s2.p1'),
              DocBlock.paragraph('purch_docs.s2.p2'),
            ],
          ),
          DocSection(
            id: 'cancelling',
            headingKey: 'purch_docs.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('purch_docs.s3.p1'),
              DocBlock.warning('purch_docs.s3.warn1'),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'customers',
    titleKey: 'chapter.customers.title',
    icon: Icons.people_outline,
    articles: <DocArticle>[
      DocArticle(
        id: 'cust_records',
        chapterId: 'customers',
        titleKey: 'cust_records.title',
        summaryKey: 'cust_records.summary',
        sections: <DocSection>[
          DocSection(
            id: 'fields',
            headingKey: 'cust_records.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cust_records.s1.p1'),
            ],
          ),
          DocSection(
            id: 'ceiling',
            headingKey: 'cust_records.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cust_records.s2.p1'),
              DocBlock.warning('cust_records.s2.warn1'),
            ],
          ),
          DocSection(
            id: 'permissions',
            headingKey: 'cust_records.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cust_records.s3.p1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'cust_debts',
        chapterId: 'customers',
        titleKey: 'cust_debts.title',
        summaryKey: 'cust_debts.summary',
        sections: <DocSection>[
          DocSection(
            id: 'credit-sale',
            headingKey: 'cust_debts.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cust_debts.s1.p1'),
              DocBlock.paragraph('cust_debts.s1.p2'),
            ],
          ),
          DocSection(
            id: 'payments',
            headingKey: 'cust_debts.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cust_debts.s2.p1'),
              DocBlock.paragraph('cust_debts.s2.p2'),
            ],
          ),
          DocSection(
            id: 'limitations',
            headingKey: 'cust_debts.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('cust_debts.s3.p1'),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'expenses',
    titleKey: 'chapter.expenses.title',
    icon: Icons.receipt_long_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'exp_manage',
        chapterId: 'expenses',
        titleKey: 'exp_manage.title',
        summaryKey: 'exp_manage.summary',
        sections: <DocSection>[
          DocSection(
            id: 'recording',
            headingKey: 'exp_manage.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'exp_manage.s1.step1',
                'exp_manage.s1.step2',
                'exp_manage.s1.step3',
              ]),
            ],
          ),
          DocSection(
            id: 'corrections',
            headingKey: 'exp_manage.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('exp_manage.s2.p1'),
            ],
          ),
          DocSection(
            id: 'in-reports',
            headingKey: 'exp_manage.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('exp_manage.s3.p1'),
              DocBlock.warning('exp_manage.s3.warn1'),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'facturation',
    titleKey: 'chapter.facturation.title',
    icon: Icons.receipt_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'fac_types',
        chapterId: 'facturation',
        titleKey: 'fac_types.title',
        summaryKey: 'fac_types.summary',
        sections: <DocSection>[
          DocSection(
            id: 'types',
            headingKey: 'fac_types.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'fac_types.s1.step1',
                'fac_types.s1.step2',
                'fac_types.s1.step3',
                'fac_types.s1.step4',
                'fac_types.s1.step5',
              ]),
            ],
          ),
          DocSection(
            id: 'creating',
            headingKey: 'fac_types.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('fac_types.s2.p1'),
              DocBlock.paragraph('fac_types.s2.p2'),
              DocBlock.tip('fac_types.s2.tip1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'fac_totals',
        chapterId: 'facturation',
        titleKey: 'fac_totals.title',
        summaryKey: 'fac_totals.summary',
        sections: <DocSection>[
          DocSection(
            id: 'vat',
            headingKey: 'fac_totals.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('fac_totals.s1.p1'),
            ],
          ),
          DocSection(
            id: 'stamp',
            headingKey: 'fac_totals.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('fac_totals.s2.p1'),
              DocBlock.paragraph('fac_totals.s2.p2'),
              DocBlock.warning('fac_totals.s2.warn1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'fac_pdf_post',
        chapterId: 'facturation',
        titleKey: 'fac_pdf_post.title',
        summaryKey: 'fac_pdf_post.summary',
        sections: <DocSection>[
          DocSection(
            id: 'preview',
            headingKey: 'fac_pdf_post.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('fac_pdf_post.s1.p1'),
            ],
          ),
          DocSection(
            id: 'posting',
            headingKey: 'fac_pdf_post.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('fac_pdf_post.s2.p1'),
              DocBlock.paragraph('fac_pdf_post.s2.p2'),
            ],
          ),
          DocSection(
            id: 'immutability',
            headingKey: 'fac_pdf_post.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('fac_pdf_post.s3.p1'),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'reports',
    titleKey: 'chapter.reports.title',
    icon: Icons.bar_chart_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'rep_overview',
        chapterId: 'reports',
        titleKey: 'rep_overview.title',
        summaryKey: 'rep_overview.summary',
        sections: <DocSection>[
          DocSection(
            id: 'tabs',
            headingKey: 'rep_overview.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'rep_overview.s1.step1',
                'rep_overview.s1.step2',
                'rep_overview.s1.step3',
                'rep_overview.s1.step4',
                'rep_overview.s1.step5',
                'rep_overview.s1.step6',
                'rep_overview.s1.step7',
                'rep_overview.s1.step8',
                'rep_overview.s1.step9',
              ]),
            ],
          ),
          DocSection(
            id: 'access',
            headingKey: 'rep_overview.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('rep_overview.s2.p1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'rep_exports',
        chapterId: 'reports',
        titleKey: 'rep_exports.title',
        summaryKey: 'rep_exports.summary',
        sections: <DocSection>[
          DocSection(
            id: 'filters',
            headingKey: 'rep_exports.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('rep_exports.s1.p1'),
            ],
          ),
          DocSection(
            id: 'exporting',
            headingKey: 'rep_exports.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'rep_exports.s2.step1',
                'rep_exports.s2.step2',
                'rep_exports.s2.step3',
              ]),
              DocBlock.tip('rep_exports.s2.tip1'),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'printing',
    titleKey: 'chapter.printing.title',
    icon: Icons.print_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'prt_overview',
        chapterId: 'printing',
        titleKey: 'prt_overview.title',
        summaryKey: 'prt_overview.summary',
        sections: <DocSection>[
          DocSection(
            id: 'supported',
            headingKey: 'prt_overview.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('prt_overview.s1.p1'),
              DocBlock.paragraph('prt_overview.s1.p2'),
            ],
          ),
          DocSection(
            id: 'workflow',
            headingKey: 'prt_overview.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('prt_overview.s2.p1'),
            ],
          ),
          DocSection(
            id: 'unsupported',
            headingKey: 'prt_overview.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('prt_overview.s3.p1'),
              DocBlock.warning('prt_overview.s3.warn1'),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'lan',
    titleKey: 'chapter.lan.title',
    icon: Icons.lan_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'lan_pairing',
        chapterId: 'lan',
        titleKey: 'lan_pairing.title',
        summaryKey: 'lan_pairing.summary',
        sections: <DocSection>[
          DocSection(
            id: 'pairing',
            headingKey: 'lan_pairing.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'lan_pairing.s1.step1',
                'lan_pairing.s1.step2',
                'lan_pairing.s1.step3',
              ]),
            ],
          ),
          DocSection(
            id: 'connected',
            headingKey: 'lan_pairing.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('lan_pairing.s2.p1'),
              DocBlock.warning('lan_pairing.s2.warn1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'lan_devices',
        chapterId: 'lan',
        titleKey: 'lan_devices.title',
        summaryKey: 'lan_devices.summary',
        sections: <DocSection>[
          DocSection(
            id: 'devices-screen',
            headingKey: 'lan_devices.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('lan_devices.s1.p1'),
              DocBlock.paragraph('lan_devices.s1.p2'),
            ],
          ),
          DocSection(
            id: 'actions',
            headingKey: 'lan_devices.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'lan_devices.s2.step1',
                'lan_devices.s2.step2',
                'lan_devices.s2.step3',
              ]),
              DocBlock.warning('lan_devices.s2.warn1'),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'settings',
    titleKey: 'chapter.settings.title',
    icon: Icons.settings_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'set_general',
        chapterId: 'settings',
        titleKey: 'set_general.title',
        summaryKey: 'set_general.summary',
        sections: <DocSection>[
          DocSection(
            id: 'language-theme',
            headingKey: 'set_general.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('set_general.s1.p1'),
            ],
          ),
          DocSection(
            id: 'store-settings',
            headingKey: 'set_general.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('set_general.s2.p1'),
            ],
          ),
          DocSection(
            id: 'company',
            headingKey: 'set_general.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('set_general.s3.p1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'set_backup',
        chapterId: 'settings',
        titleKey: 'set_backup.title',
        summaryKey: 'set_backup.summary',
        sections: <DocSection>[
          DocSection(
            id: 'creating-backup',
            headingKey: 'set_backup.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('set_backup.s1.p1'),
            ],
          ),
          DocSection(
            id: 'restoring',
            headingKey: 'set_backup.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('set_backup.s2.p1'),
              DocBlock.warning('set_backup.s2.warn1'),
            ],
          ),
          DocSection(
            id: 'missing-tools',
            headingKey: 'set_backup.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('set_backup.s3.p1'),
            ],
          ),
        ],
      ),
    ],
  ),
  DocChapter(
    id: 'troubleshooting',
    titleKey: 'chapter.troubleshooting.title',
    icon: Icons.troubleshoot_outlined,
    articles: <DocArticle>[
      DocArticle(
        id: 'ts_connection',
        chapterId: 'troubleshooting',
        titleKey: 'ts_connection.title',
        summaryKey: 'ts_connection.summary',
        sections: <DocSection>[
          DocSection(
            id: 'disconnected',
            headingKey: 'ts_connection.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'ts_connection.s1.step1',
                'ts_connection.s1.step2',
                'ts_connection.s1.step3',
                'ts_connection.s1.step4',
              ]),
            ],
          ),
          DocSection(
            id: 'login-rejected',
            headingKey: 'ts_connection.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('ts_connection.s2.p1'),
              DocBlock.warning('ts_connection.s2.warn1'),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'ts_print_pdf',
        chapterId: 'troubleshooting',
        titleKey: 'ts_print_pdf.title',
        summaryKey: 'ts_print_pdf.summary',
        sections: <DocSection>[
          DocSection(
            id: 'printing-problems',
            headingKey: 'ts_print_pdf.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'ts_print_pdf.s1.step1',
                'ts_print_pdf.s1.step2',
                'ts_print_pdf.s1.step3',
              ]),
            ],
          ),
          DocSection(
            id: 'barcode',
            headingKey: 'ts_print_pdf.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'ts_print_pdf.s2.step1',
                'ts_print_pdf.s2.step2',
                'ts_print_pdf.s2.step3',
              ]),
            ],
          ),
        ],
      ),
      DocArticle(
        id: 'ts_data',
        chapterId: 'troubleshooting',
        titleKey: 'ts_data.title',
        summaryKey: 'ts_data.summary',
        sections: <DocSection>[
          DocSection(
            id: 'stock-debt',
            headingKey: 'ts_data.s1.heading',
            blocks: const <DocBlock>[
              DocBlock.steps(<String>[
                'ts_data.s1.step1',
                'ts_data.s1.step2',
              ]),
            ],
          ),
          DocSection(
            id: 'permissions',
            headingKey: 'ts_data.s2.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('ts_data.s2.p1'),
            ],
          ),
          DocSection(
            id: 'layout',
            headingKey: 'ts_data.s3.heading',
            blocks: const <DocBlock>[
              DocBlock.paragraph('ts_data.s3.p1'),
              DocBlock.tip('ts_data.s3.tip1'),
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
