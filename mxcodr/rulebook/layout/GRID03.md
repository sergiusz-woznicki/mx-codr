---
step: layout
level: block
check: layout_rules/grid_filters.cjs#missingFilterFindings
key: document
---

# GRID03 — grid columns have filters

## What it checks
Every column of a data grid that is bound to an attribute has a filter, on every grid in the app: overview and detail grids alike, whatever the row count today, because the rows grow with the app. The filter sits in the column's own braces, or in the grid's `controlbar { }` linked to that column -- the filter bar above the table, when the request asks for one. Columns without an Attribute, and columns of buttons only, are left alone.

## Fix
In the finding.

## A filter bar above the grid
The grid's own `controlbar { }`, each filter linked to its column (measured with mx check on Mendix 11.12):

```sql
datagrid LoanOverview_LoansGrid (DataSource: database from Lib.Loan) {
  controlbar {
    dropdownfilter LoanOverview_StatusFilter (attrchoice: linked, attributes: [Lib.Loan.Status], multiSelect: true)
    dropdownfilter LoanOverview_MemberFilter (association: Lib.Loan_Member, datasource: database Lib.Member, captionattribute: Name)
    datefilter LoanOverview_BorrowedFilter (attrchoice: linked, attributes: [Lib.Loan.Borrowed], defaultFilter: between)
  }
  column (Attribute: Status, Caption: 'Status')
  column (Attribute: Loan_Member/Name, Caption: 'Member')
  column (Attribute: Borrowed, Caption: 'Borrowed')
}
```

Filters in one bar combine with AND.

## Local
# level: block
# except: Module.Page   # why
