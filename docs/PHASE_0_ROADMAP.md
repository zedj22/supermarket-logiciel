# PHASE 0 — Roadmap

## Phase Overview

| Phase | Name | Duration | Dependencies |
|-------|------|----------|--------------|
| 0 | Reverse Engineering & Specification | Complete | — |
| 1 | Project Foundation | 2 weeks | Phase 0 |
| 2 | Database/Models/Migrations | 2 weeks | Phase 1 |
| 3 | Backend Foundation | 2 weeks | Phase 2 |
| 4 | Auth/Users/Permissions | 1 week | Phase 3 |
| 5 | Products/Categories | 2 weeks | Phase 3, 4 |
| 6 | Variants/Units/Weighted | 1 week | Phase 5 |
| 7 | Inventory | 1 week | Phase 5 |
| 8 | POS (Core) | 3 weeks | Phase 5, 6, 7 |
| 9 | Payments/Customers/Debts | 2 weeks | Phase 8 |
| 10 | Packs | 1 week | Phase 5, 8 |
| 11 | Purchases/Suppliers | 2 weeks | Phase 5, 7 |
| 12 | Returns/Voids | 1 week | Phase 8, 9 |
| 13 | Expenses | 1 week | Phase 3 |
| 14 | Reports/Dashboard | 3 weeks | Phase 8, 9, 11, 12, 13 |
| 15 | Printing/Exports | 2 weeks | Phase 14 |
| 16 | LAN/Multi-PC/Devices | 2 weeks | Phase 3 |
| 17 | Backup/Settings/Localization/Final QA | 3 weeks | All |

**Total Estimated Duration**: ~30 weeks (7-8 months)

---

## Phase 1: Project Foundation

### Objective
Set up project structure, development environment, CI/CD, and core infrastructure.

### Dependencies
- Phase 0 complete

### Features
- Backend project scaffolding (FastAPI)
- Flutter project scaffolding
- PostgreSQL setup with Docker
- Alembic migration infrastructure
- Development environment configuration
- Code quality tools (linting, formatting)
- Basic CI/CD pipeline

### Backend Work
- Create FastAPI project structure
- Configure SQLAlchemy with PostgreSQL
- Set up Alembic
- Create base models
- Set up logging
- Create exception hierarchy
- Set up dependency injection

### Flutter Work
- Create Flutter desktop project
- Set up Riverpod state management
- Configure API client
- Set up routing
- Create theme system (dark/light/grey)
- Set up localization infrastructure
- Create base UI components

### Database Work
- Design final schema
- Create initial migration
- Set up test database

### Tests
- Unit test setup
- Integration test setup
- Database test setup

### Acceptance Criteria
- [ ] Backend starts and serves health endpoint
- [ ] Flutter app builds and runs
- [ ] Database connection works
- [ ] Migrations run successfully
- [ ] CI pipeline passes

### Risks
- Flutter desktop compatibility issues
- PostgreSQL setup complexity on Windows
- Initial architecture decisions may need revision

---

## Phase 2: Database/Models/Migrations

### Objective
Implement complete database schema with SQLAlchemy models and Alembic migrations.

### Dependencies
- Phase 1

### Features
- All 17+ tables with proper relationships
- Proper data types (DECIMAL for money)
- Foreign key constraints
- Indexes for performance
- Audit fields (created_at, updated_at)

### Backend Work
- SQLAlchemy models for all entities
- Relationship definitions
- Index creation
- Seed data for testing

### Database Work
- Create comprehensive migration
- Add all indexes
- Add foreign key constraints
- Test data integrity

### Tests
- Model tests
- Migration tests
- Constraint tests

### Acceptance Criteria
- [ ] All tables created with correct schema
- [ ] All relationships work
- [ ] All indexes created
- [ ] Migrations can be applied and rolled back
- [ ] Seed data loads successfully

---

## Phase 3: Backend Foundation

### Objective
Implement core backend services, API framework, and authentication infrastructure.

### Dependencies
- Phase 2

### Features
- JWT authentication
- PIN-based login
- User management API
- Settings API
- Device management API
- Structured error handling
- Request validation
- CORS configuration
- Rate limiting

### Backend Work
- Auth service (login, verify, refresh)
- User service (CRUD)
- Settings service
- Device service
- Exception handlers
- Validation middleware
- Logging middleware

### Tests
- Auth tests
- User tests
- Settings tests
- Error handling tests

### Acceptance Criteria
- [ ] Login returns JWT token
- [ ] Token verification works
- [ ] User CRUD works
- [ ] Settings CRUD works
- [ ] Errors return proper format
- [ ] CORS configured correctly

---

## Phase 4: Auth/Users/Permissions

### Objective
Complete user management with role-based access control.

### Dependencies
- Phase 3

### Features
- User creation with PIN hashing
- Role assignment (admin, cashier)
- Permission checks on endpoints
- Audit logging
- First admin setup

### Backend Work
- Complete user CRUD
- PIN hashing (SHA-256 with salt)
- Role-based permission checks
- Audit log service
- First admin setup endpoint

### Flutter Work
- Login screen
- PIN input screen
- User management screen
- First admin setup wizard

### Tests
- Authentication tests
- Permission tests
- Audit log tests

### Acceptance Criteria
- [ ] Admin can create users
- [ ] PIN login works
- [ ] Roles restrict access
- [ ] Sensitive actions logged
- [ ] First admin setup works

---

## Phase 5: Products/Categories

### Objective
Complete product and category management.

### Dependencies
- Phase 3, 4

### Features
- Product CRUD with validation
- Category CRUD
- Barcode management
- Image upload
- Product search with pagination
- Category filtering

### Backend Work
- Product service
- Category service
- Product repository with search
- Image handling
- Pagination support

### Flutter Work
- Product list screen with search
- Product form screen
- Category management screen
- Image picker/display

### Tests
- Product CRUD tests
- Category tests
- Search tests
- Validation tests

### Acceptance Criteria
- [ ] Products can be created/edited/deleted
- [ ] Categories work correctly
- [ ] Barcode lookup works
- [ ] Search returns correct results
- [ ] Pagination works

---

## Phase 6: Variants/Units/Weighted Products

### Objective
Implement product variants, units of measure, and weighted product support.

### Dependencies
- Phase 5

### Features
- Product variant CRUD
- Variant stock tracking
- Variant barcode support
- Unit of measure selection
- Weighted product quantity dialog
- Decimal precision for weights

### Backend Work
- Variant service
- Variant repository
- Stock tracking for variants
- Unit validation

### Flutter Work
- Variant management in product form
- Variant picker in POS
- Weight input dialog
- Unit selector

### Tests
- Variant CRUD tests
- Stock tracking tests
- Weight precision tests

### Acceptance Criteria
- [ ] Variants can be created/edited/deleted
- [ ] Variant stock tracked separately
- [ ] Weighted products work correctly
- [ ] Unit selection works

---

## Phase 7: Inventory

### Objective
Complete inventory management with stock tracking and movement history.

### Dependencies
- Phase 5

### Features
- Stock levels view
- Manual stock adjustment
- Stock entry dialog
- Movement history
- Low stock alerts
- Stock valuation

### Backend Work
- Inventory service
- Stock adjustment logic
- Movement recording
- Low stock detection

### Flutter Work
- Inventory screen
- Stock entry dialog
- Movement history view
- Low stock alerts

### Tests
- Stock adjustment tests
- Movement recording tests
- Low stock tests

### Acceptance Criteria
- [ ] Stock can be adjusted
- [ ] Movements recorded correctly
- [ ] Low stock detected
- [ ] History viewable

---

## Phase 8: POS (Core)

### Objective
Implement complete point-of-sale system.

### Dependencies
- Phase 5, 6, 7

### Features
- Product browser with search
- Barcode scanning
- Cart management
- Quantity adjustment
- Item/invoice discounts
- Favorites
- Hold/restore sale
- Customer selection
- Payment processing
- Invoice creation

### Backend Work
- POS service
- Sale creation with transaction
- Stock deduction with optimistic locking
- Discount handling
- Favorites service

### Flutter Work
- POS screen (product browser + cart)
- Cart display and management
- Payment dialog
- Customer selector
- Discount dialogs
- Favorites section
- Hold/restore UI

### Tests
- Cart management tests
- Stock deduction tests
- Discount tests
- Transaction tests

### Acceptance Criteria
- [ ] Products can be added to cart
- [ ] Barcode scanning works
- [ ] Stock deducted correctly
- [ ] Discounts apply correctly
- [ ] Payment processing works
- [ ] Invoices created successfully

---

## Phase 9: Payments/Customers/Debts

### Objective
Complete customer management and debt tracking.

### Dependencies
- Phase 8

### Features
- Customer CRUD
- Debt tracking
- Payment recording
- Debt history
- Customer balance
- Debt ceiling

### Backend Work
- Customer service
- Debt service
- Payment processing
- Balance calculation

### Flutter Work
- Customer management screen
- Debt payment dialog
- Debt history view
- Customer details screen

### Tests
- Customer CRUD tests
- Debt tracking tests
- Payment tests
- Balance calculation tests

### Acceptance Criteria
- [ ] Customers can be managed
- [ ] Debts tracked correctly
- [ ] Payments recorded
- [ ] History viewable

---

## Phase 10: Packs

### Objective
Implement product packs/bundles.

### Dependencies
- Phase 5, 8

### Features
- Pack CRUD
- Component management
- Pack pricing
- Stock validation
- Pack sales in POS

### Backend Work
- Pack service
- Component validation
- Pack pricing logic

### Flutter Work
- Pack management screen
- Pack picker in POS
- Pack display in cart

### Tests
- Pack CRUD tests
- Stock validation tests
- Pack sale tests

### Acceptance Criteria
- [ ] Packs can be created/edited/deleted
- [ ] Stock validation works
- [ ] Pack sales deduct component stock

---

## Phase 11: Purchases/Suppliers

### Objective
Complete supplier and purchase invoice management.

### Dependencies
- Phase 5, 7

### Features
- Supplier CRUD
- Purchase invoice creation
- Purchase items
- Supplier balance tracking
- Stock increase on purchase
- Purchase deletion with stock reversal

### Backend Work
- Supplier service
- Purchase service
- Balance tracking
- Stock increase logic

### Flutter Work
- Supplier management screen
- Purchase form screen
- Purchase list screen
- Supplier payment dialog

### Tests
- Supplier CRUD tests
- Purchase creation tests
- Stock increase tests
- Balance tracking tests

### Acceptance Criteria
- [ ] Suppliers can be managed
- [ ] Purchases create correctly
- [ ] Stock increases on purchase
- [ ] Supplier balance tracked

---

## Phase 12: Returns/Voids

### Objective
Implement return processing and invoice voiding.

### Dependencies
- Phase 8, 9

### Features
- Independent returns
- Invoice-based returns
- Stock restoration
- Invoice voiding
- Customer balance adjustment

### Backend Work
- Return service
- Void service
- Stock restoration logic
- Balance adjustment

### Flutter Work
- Return dialog
- Invoice-based return flow
- Void confirmation

### Tests
- Return processing tests
- Void tests
- Stock restoration tests

### Acceptance Criteria
- [ ] Returns restore stock correctly
- [ ] Voids reverse all effects
- [ ] Customer balance adjusted

---

## Phase 13: Expenses

### Objective
Implement expense tracking.

### Dependencies
- Phase 3

### Features
- Expense CRUD
- Category management
- Drawer vs external payment
- Expense reporting

### Backend Work
- Expense service
- Category management

### Flutter Work
- Expense list screen
- Expense form dialog

### Tests
- Expense CRUD tests

### Acceptance Criteria
- [ ] Expenses can be tracked
- [ ] Categories work
- [ ] Reporting includes expenses

---

## Phase 14: Reports/Dashboard

### Objective
Complete reporting system with dashboard.

### Dependencies
- Phase 8, 9, 11, 12, 13

### Features
- Financial report
- Product performance
- Category analysis
- Daily/hourly timeline
- Peak hours analysis
- Slow moving products
- Device breakdown
- Voided invoices
- Dashboard KPIs

### Backend Work
- Report service
- Dashboard aggregation
- Analytics calculations

### Flutter Work
- Dashboard screen
- Report screens with charts
- Date range selector
- Export options

### Tests
- Report calculation tests
- Dashboard KPI tests

### Acceptance Criteria
- [ ] Reports calculate correctly
- [ ] Dashboard shows accurate KPIs
- [ ] Charts render properly

---

## Phase 15: Printing/Exports

### Objective
Implement PDF printing and data exports.

### Dependencies
- Phase 14

### Features
- 80mm thermal printing
- A4 invoice printing
- Arabic text support
- Excel export
- CSV export
- PDF export

### Backend Work
- Print service
- Export service
- PDF generation
- Excel generation

### Flutter Work
- Print dialog
- Export format selection
- Print preview

### Tests
- PDF generation tests
- Export format tests

### Acceptance Criteria
- [ ] 80mm invoices print correctly
- [ ] A4 invoices print correctly
- [ ] Arabic text renders in PDF
- [ ] Excel/CSV exports work

---

## Phase 16: LAN/Multi-PC/Devices

### Objective
Implement multi-PC LAN operation.

### Dependencies
- Phase 3

### Features
- Server/client mode
- Device discovery (UDP + TCP)
- Pairing approval
- Connection monitoring
- Auto-reconnect
- Status indicator

### Backend Work
- Device service
- Discovery responder
- Pairing management
- Connection health check

### Flutter Work
- Device setup wizard
- Pairing approval dialog
- Connection status indicator
- Reconnect dialog

### Tests
- Discovery tests
- Pairing tests
- Connection monitoring tests

### Acceptance Criteria
- [ ] Server mode works
- [ ] Client mode works
- [ ] Device discovery works
- [ ] Pairing approval works
- [ ] Connection monitoring works

---

## Phase 17: Backup/Settings/Localization/Final QA

### Objective
Complete remaining features and final quality assurance.

### Dependencies
- All previous phases

### Features
- Backup creation/restore
- Settings management
- Full localization (AR/EN/FR)
- RTL support
- Theme system
- Performance optimization
- Security audit
- Final testing

### Backend Work
- Backup service
- Settings service
- Localization support

### Flutter Work
- Backup/restore UI
- Settings screen
- Full localization
- RTL layout
- Theme switching
- Performance tuning

### Tests
- Backup/restore tests
- Localization tests
- RTL tests
- Theme tests
- Performance tests
- Security tests
- End-to-end tests

### Acceptance Criteria
- [ ] Backups work correctly
- [ ] Settings persist
- [ ] All strings translated
- [ ] RTL layout works
- [ ] All themes work
- [ ] Performance meets targets
- [ ] No security vulnerabilities
- [ ] All tests pass

---

## Definition of Done

A phase is complete when:

1. **Implementation** — All features implemented
2. **Tests** — Automated tests written and passing
3. **Static Analysis** — No linting errors
4. **No Silent Errors** — No unexplained exception suppression
5. **Localization** — All strings translatable
6. **UI Verification** — UI works correctly
7. **Database Verification** — Data integrity maintained
8. **Regression** — No existing features broken
9. **Acceptance Criteria** — All criteria satisfied
10. **Documentation** — API docs updated
