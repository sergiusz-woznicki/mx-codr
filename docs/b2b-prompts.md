# B2B order app: prompts

The initial prompt (part 1) first, then part 2 in four turns. Give the turns in order; start the next only after `bash tests/gate.sh` said DONE. DeepSeek 4.1 flash in Pi built the InvoiceB2B demo app this way.

## Initial prompt (part 1)

```text
Build a web application for managing B2B orders.  
0. User roles and access levels:
* The application has two access levels:
    * Employee: sees everything. Can view and filter all orders, change order statuses, generate invoices, and view all customers in the customer panel.
    * Customer: logs in as one specific customer (choose from a dropdown list of the seed customers, e.g. "Log in as: [Customer Name]"). Can only see their own orders and their own invoices — no access to other customers' data, no access to the internal dashboard, and no ability to change order statuses or generate invoices (read-only view).
* After choosing a role, show a simple top bar indicating who is logged in (e.g. "Logged in as: Employee — Anna Kowalska" or "Logged in as: Customer — Acme Sp. z o.o.") with a button to switch/log out and pick a different role or account.
* Routing/visible sections must differ by role: Employee sees Order List, Customer Panel (for any customer), and Dashboard. Customer sees only their own order history and invoices (essentially their own view of what would otherwise be the "Customer panel," restricted to themselves).
1. Data model — exact fields:
* Customer: id, name (string), taxId (string, exactly 10 digits, validate the format), address (street, city, postal code), creditLimit (number, currency), email, phone.
* Product: id, sku (string, unique), name, price (number, currency, net), vatRate (default 23%), stockQuantity (integer, ≥0).
* OrderLineItem: productId, quantity (integer >0), unitPriceNet (number, copied from the product at the moment the order is placed — not a live reference), netValue (calculated = quantity × price).
* I(format: ORD/YYYY/0001, auto-incremented per year), customerId, dateCreated, lineItems: OrderLineItem[], status (enum: New | Confirmed | InProgress | Shipped | Delivered | Invoiced), statusHistory: {status, date, user}[], totalNetValue, totalGrossValue.
* Invoice: id, invoiceNumber (format: INV/YYYY/0001), orderId, issueDate, dueDate (defaults to issueDate + 14 days), grossAmount, paymentStatus (enum: Unpaid | Paid | Overdue — Overdue is calculated automatically if today > dueDate and paymentStatus !== Paid; this is not a field set manually).
2. Business rules (implement literally, do not simplify):
* An order cannot be created if its total gross value would exceed the customer's available credit limit (limit minus the sum of that customer's unpaid invoices). Show an error message with the calculated available amount.
* The order status can only move forward, in this order: New → Confirmed → InProgress → Shipped → Delivered → Invoiced. Attempting to revert or skip a stage (e.g., jumping from New straight to Shipped) must be blocked both in the UI (disabled button) and in the logic. Only an Employee can trigger this action.
* Every status change appends an entry to statusHistory with the current date/time and the name of the logged-in employee performing the change.
* An invoice can only be generated for an order with status Delivered, and only by an Employee. Generating an invoice automatically changes the order's status to Invoiced.
* When an order's status changes from Confirmed to InProgress, subtract the ordered quantities from the stockQuantity of the relevant products. If stock is insufficient for any line item, block the status change and show which products are short and by how much.
3. Order list view (Employee only):
* A table with columns: order number, customer, date created, gross value, status (as a colored badge), actions.
* Filters (shown as a bar above the table, combined with AND, not OR): status (multi-select), customer (dropdown), date-created range (from–to).
* Clickable column sorting: date, value, order number (ascending/descending).
* Clicking a row opens the order details: full list of line items, a timeline of status history, a status-change button (only to the next allowed stage), and an invoice-generation button (enabled only when status = Delivered).
* User must be able to create an order selecting meny product from catalog to one order.
4. Customer panel:
* Employee view: select any customer from a list/dropdown, see a table of their order history with the total of all orders, a table of their invoices with payment status, a visible count and total of overdue receivables (invoices with status Overdue, visually highlighted), and the available credit limit = creditLimit − sum of unpaid and overdue invoices.
* Customer view (logged in as a customer): the same content and layout as above, but automatically scoped to their own account only — no customer selector, no ability to switch to another customer's data.
5. Dashboard (Employee only, separate view/tab):
* KPI cards at the top: (a) total value of orders created in the current calendar month, (b) average fulfillment time in days — calculated as the difference between the New and Delivered status dates from statusHistory, averaged across orders that reached Delivered, (c) number of invoices with status Overdue.
* A simple bar chart: total order value per month (last 6 months, based on demo data).
* All KPIs must be genuinely calculated from the application's data, not hardcoded.
6. Invoice PDF generator (Employee only):
* A "Generate PDF" button in the invoice details.
* The generated document includes: seller details (you may use a sample company), buyer details (customer name, tax ID, address), invoice number, issue date and due date, a table of line items (product name, quantity, net price, net value, VAT, gross value), and the net/VAT/gross totals at the bottom.
7. Seed data:
* Generate at least: 5 customers, 10 products, 15 orders across various statuses (spread over the last 3 months, so the dashboard and filters have data to show), and corresponding invoices for orders with status Invoiced (some paid, some unpaid, some deliberately with a due date in the past so that the Overdue status is triggered). Also seed at least 2 sample employee accounts for the login selector.
8. Data formatting:
* Format all amounts with two decimal places and a thousands separator.
* Format all dates as DD/MM/YYYY.
9. integration, order status is coming from external system that delivers API: OrderNumber and Order status, both are coming from API as strings, match oreder number  with our orders from mock data so user can test system at works. Make internal mock with UserRest service and integrat it with our app I dont want mock to be external service for this demo we want it to be internal rest mock. Make mock change status In correct order every mock call per order. Integrate this status changes mock into our app as rest service that our app is integrate too. 
Make all decisions yourself dont ask me.
```

## Turn 1 of 4: Real sign-in, a Manager role, and data isolation

```text
This is turn 1 of 4 extending the B2B order application that already exists in this Mendix project. Do not rebuild what is there: first run bash tests/orient.sh and read the existing modules, entities, pages and microflows, and keep their names. Build only what this turn asks for. At the end the whole app must work, with this turn's features in it, and `bash tests/gate.sh` must say DONE.

* Security level Production with real sign-in. If the app still picks a user from a list, replace that with real accounts.
* Add a Manager role: everything an Employee can do, and the dashboard becomes Manager-only.
* Row-level isolation with entity access rules (XPath on the signed-in user), not only hidden pages: a Customer must not be able to read another customer's orders or invoices, not even through a URL or a data source.
* Add an internalNote attribute to Order and to Customer. Member-level access: Employees and Managers read and write it, Customers cannot see it. A Customer can read their own creditLimit but not change it.
* Password policy: at least 12 characters, with a digit and mixed case.
* Demo users: one Employee, one Manager and two Customers, each Customer linked to a different seed customer.
* When an Employee creates a customer, the same form creates that customer's own login account (name and password) with the Customer role.
* The page header and the signed-in-user bar become snippets, used on every page.
* Browser tests (tests/verify-*.test.sh): each role signs in and sees only its own menu; a Customer cannot read another customer's orders, checked in the database and not only on screen; a Customer cannot see internalNote; creating a customer also creates a working login.

Work on your own without asking me questions. When done, report in plain language what you added and anything you could not build and why.
```

## Turn 2 of 4: Richer data, the catalog, and stricter logic

```text
This is turn 2 of 4 extending the B2B order application in this Mendix project. Turn 1 (real sign-in, the Manager role, data isolation) is already built. Do not rebuild what is there: first run bash tests/orient.sh and read the existing modules, entities, pages and microflows, and keep their names. Build only what this turn asks for. At the end the whole app must work, with this turn's features in it, and `bash tests/gate.sh` must say DONE.

* Customer: a logo image, shown in the customer panel.
* Product: a product photo, a description, and a many-to-many set of Tags (a new Tag entity). The default vatRate comes from a constant (23).
* Product catalog page: a gallery of product cards with photo, price and tags. A product edit pop-up with image upload and tag selection.
* Order: a new status Cancelled, allowed only from New or Confirmed, recorded in the status history like every other change. A Cancel button on the order detail, enabled only in New or Confirmed.
* Order detail: tabs for Lines, Status history and Invoice.
* Invoice: the dueDate uses a payment-terms constant (default 14 days) instead of a fixed 14. The generated PDF is stored on the invoice as a file document and can be downloaded from the invoice.
* A view entity (OQL) CustomerBalance: per customer, the sum of Unpaid and Overdue invoices and the available credit (creditLimit minus that sum). Use it everywhere available credit is shown and in the credit rule.
* A non-persistent OrderFilter entity holds the order-list filter values.
* A nanoflow checks the quantity on an order line on the client before saving: it must be greater than 0, and a warning appears if it is higher than the stock.
* A Java action validates the taxId checksum (Polish NIP: weights 6,5,7,2,3,4,5,6,7, the sum mod 11 equals the last digit). Saving a customer uses it. Make sure the seed customers have valid tax IDs.
* The stock subtraction (Confirmed to InProgress) uses error handling that rolls the whole change back and logs the failure, in addition to the message listing the short products.
* Seed, only when empty: tags on every product, and one Cancelled order. A reset action for tests restores the seed data.
* Browser tests for the catalog, the product pop-up, Cancel, the stored PDF, the quantity warning, the invalid tax ID message, and the stock rollback.
* Microflow unit tests (.test.mdl) for the credit rule on CustomerBalance, the status transitions including Cancelled, and the taxId checksum.

Work on your own without asking me questions. When done, report in plain language what you added and anything you could not build and why.
```

## Turn 3 of 4: Approval workflow and background processing

```text
This is turn 3 of 4 extending the B2B order application in this Mendix project. Turns 1 and 2 (security and the Manager role; the catalog, Cancelled, CustomerBalance and the stricter logic) are already built. Do not rebuild what is there: first run bash tests/orient.sh and read the existing modules, entities, pages and microflows, and keep their names. Build only what this turn asks for. At the end the whole app must work, with this turn's features in it, and `bash tests/gate.sh` must say DONE.

* Order: a requiresApproval boolean. Orders above a threshold constant (default 50,000 gross) set it and need a Manager's approval through a Mendix workflow before they can be confirmed. The Confirm button stays disabled until the approval is given.
* The workflow has a user task for a Manager (approve, or reject with a reason), a decision on the outcome, and, in parallel, a notification task for the Employee who created the order.
* A rejected order becomes Cancelled, with the reason recorded in the status history.
* A "My approvals" page shows a Manager their open workflow tasks. The order detail gets an Approval tab showing the approval state and reason.
* A scheduled event runs every night and marks invoices Overdue when today is after the dueDate and the invoice is not Paid. The microflow it calls can also be started by hand from an Employee action, for tests.
* When an order becomes Shipped, publish a business event OrderShipped carrying the order number, the customer's tax ID and the gross value.
* Seed, only when empty: one order above the threshold waiting for approval.
* Browser tests: a large order is approved by the Manager and can then be confirmed; another is rejected and ends Cancelled with the reason; the Overdue job run by hand marks a past-due invoice Overdue.

Work on your own without asking me questions. When done, report in plain language what you added and anything you could not build and why.
```

## Turn 4 of 4: Integrations

```text
This is turn 4 of 4 extending the B2B order application in this Mendix project. Turns 1 to 3 (security, the catalog and stricter logic, the approval workflow and background jobs) are already built. Do not rebuild what is there: first run bash tests/orient.sh and read the existing modules, entities, pages and microflows, and keep their names. Build only what this turn asks for, in a new module called `Integration`. At the end the whole app must work, with this turn's features in it, and `bash tests/gate.sh` must say DONE.

* Exchange rates: an internal mock published REST service returns today's EUR and USD rates against PLN as JSON. Consume it through a JSON structure, an import mapping and a REST client whose base URL is a constant, so a real service could replace the mock. A microflow stores today's rates. The order detail also shows the gross value in EUR.
* Publish a read-only REST service for Employees: GET /orders?status=... and GET /orders/{orderNumber} with its lines, built with an export mapping.
* Publish a read-only OData service with Customers, Orders and Invoices for BI tools.
* Read warehouse stock from an external PostgreSQL database connection (a query that returns sku and quantity). Use the PostgreSQL the app already runs against locally, with its own warehouse-stock table that you create and fill. Add an Employee action "Sync stock from warehouse" that updates product stock.
* Only if this project's Mendix version supports agent documents: an agent that drafts a polite payment-reminder e-mail for an overdue invoice, shown to the Employee for review before anything is sent. Otherwise skip it and say so in the report.
* Browser tests: the EUR value on an order; GET /orders and GET /orders/{orderNumber} return the right orders for an Employee and are refused without sign-in; the OData service lists customers; "Sync stock from warehouse" changes a product's stock to the warehouse value.

Work on your own without asking me questions. When done, report in plain language what you added across all four turns, which mxcli features you used for what, and anything you could not build and why.
```
