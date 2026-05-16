# 08 — UI screen list

Every screen, who sees it, and what it does. Routes use GoRouter paths.

## Auth (unauthenticated)

| Route | Screen | Notes |
|---|---|---|
| `/login` | LoginScreen | phone + password; "Join shop with code" link |
| `/register-shop` | RegisterShopScreen | 3-step wizard: shop info → owner info → owner PIN |
| `/accept-invite` | AcceptInviteScreen | phone + 8-digit code + password |
| `/forgot-pin` | (deferred; owner contacts support) | |

## Home shell — bottom nav (authenticated)

Tab visibility differs by role.

### Tab 1 — Sell (`/pos`) — both roles
| Screen | Notes |
|---|---|
| **PosScreen** | grid of product tiles (8/page), search bar at top, cart drawer right-edge, big "Checkout" FAB |
| **CheckoutSheet** (modal) | total, payment method picker (cash / mobile money / credit), tendered amount, change |
| **CreditDetailsSheet** | customer name (autocomplete from open debts), phone, due date, "requires owner PIN" badge if over threshold |
| **ReceiptPreviewScreen** | shareable summary; export PDF (later: print) |

### Tab 2 — Inventory (`/inventory`)
Cashier view-only; owner full.

| Screen | Notes |
|---|---|
| **InventoryListScreen** | search, category chips, low-stock filter toggle |
| **ProductDetailScreen** | stock history (recent inventory_logs), edit button (owner only) |
| **ProductEditScreen** | name, category, prices, threshold, unit, barcode, image |
| **BulkRestockScreen** | scan/select multiple → enter qty per row → submit |
| **StockAdjustmentSheet** | reason (waste/count/correction) + qty delta; owner PIN |

### Tab 3 — Debts (`/debts`)
| Screen | Notes |
|---|---|
| **DebtListScreen** | tabs: open / partial / paid; sort by due date or amount |
| **DebtDetailScreen** | customer, total, paid, remaining, payment history, "Collect payment" CTA |
| **CollectPaymentSheet** | amount + method; partial/full toggle |
| **DebtCreateScreen** | manual debt entry (rare; usually via checkout) |

### Tab 4 — Shift (`/shift`)
| Screen | Notes |
|---|---|
| **ShiftOpenScreen** | shown when no open shift; "Opening cash" number pad |
| **ShiftActiveScreen** | running totals (sales, cash collected, credit, expenses), big "End shift" button |
| **ShiftCloseSheet** | declared cash count → variance shown after submit |
| **ShiftHistoryScreen** | own shifts (cashier); all shifts (owner) |
| **ShiftDetailScreen** | full reconciliation breakdown, ability to flag |

### Tab 5 — Owner only (`/owner`)
| Screen | Notes |
|---|---|
| **OwnerDashboardScreen** | today's KPIs + range picker (today/7d/30d), revenue chart, profit chart, top products list, low-stock badge, outstanding debt |
| **ReportsScreen** | weekly/monthly drill-down |
| **AuditScreen** | filter by user, action, date; tap row for diff view |
| **EmployeesScreen** | list + invite button |
| **InviteEmployeeSheet** | name + role; shows 8-digit code |
| **DevicesScreen** | list of device_sessions; revoke action |
| **ExpensesScreen** | list + add; categories pie chart |
| **AddExpenseSheet** | title, amount, category, description |
| **SettingsScreen** | shop info, debt threshold, currency display, language (en/om), dark mode |

### Tab 5 (cashier replacement) — Settings (`/me`)
| Screen | Notes |
|---|---|
| **MyProfileScreen** | name, phone (read-only), change password |
| **MyDevicesScreen** | only this device shown |
| **LanguageScreen** | en / om |

## Cross-cutting overlays

| Component | When |
|---|---|
| **SyncStatusBadge** | always visible top-right; shows unsynced count or spinner |
| **OwnerPinDialog** | gates any sensitive action |
| **OfflineBanner** | thin bar when offline >5min |
| **LowStockToast** | when adding to cart pushes a product below threshold |

## Empty/error states

Every list screen has:
- **Empty** with friendly illustration + primary CTA ("Add your first product")
- **Loading** skeleton (no spinners)
- **Error** with retry, plus diagnostic detail accordion (owner only)

## Animations

Keep under 200ms. Use `AnimatedSwitcher` for state changes, `Hero` only for product → detail. No parallax, no shimmer beyond loading.

## Accessibility

- Min font size 14sp, scalable up to 200%.
- All interactive elements have `Semantics(label: ...)`.
- Color is never the only signal — paired with icon + text.
- High-contrast theme available in settings.

## Notification screens

| Source | Lands you on |
|---|---|
| Low-stock alert | `/inventory?filter=low_stock` |
| Debt due reminder | `/debts/<id>` |
| Sync failure | `/owner` settings → diagnostics (owner) or current screen (cashier) |
| Shift not closed | `/shift` |
