# AutoPay & Track: Integrated Payroll & Attendance Management System
### DBMS Capstone Project — MySQL + Python

---

## Project Overview

**AutoPay & Track** is a production-ready relational database system for a mid-sized IT firm that automates two core HR workflows:

1. **Attendance Management** — daily check-in/check-out, leave applications, approval workflow
2. **Payroll Management** — monthly salary processing with leave deductions, tiered tax, and net-pay computation

**Tech Stack:** MySQL 8.0+ · Python 3.8+ · `mysql-connector-python`

---

## Project Structure

```
DBMS CAPSTONE/
├── phase1_schema.sql                   # Phase 1: 3NF DDL Schema
├── phase2_procedures_triggers_seed.sql  # Phase 2: Procedures, Triggers & Seed Data
├── phase3_reports_indexes.sql          # Phase 3: Analytical Reports & Index Optimization
├── phase4_rbac_transactions_tests.sql   # Phase 4: RBAC, Transactions & Test Cases
├── phase5_python_cli.py                # Phase 5: Python CLI Application
└── README.md                           # This file
```

| File | Lines | Description |
|------|-------|-------------|
| `phase1_schema.sql` | 512 | Database creation, 5 normalized tables, all constraints |
| `phase2_procedures_triggers_seed.sql` | 1,008 | Function, procedure, 2 triggers, 660+ seed rows |
| `phase3_reports_indexes.sql` | 536 | 3 analytical queries + 4 optimized indexes with EXPLAIN |
| `phase4_rbac_transactions_tests.sql` | 656 | RBAC roles/users, ACID transaction, 5 test cases |
| `phase5_python_cli.py` | 594 | Full role-based Python CLI |

---

## Phase 1 — 3NF Data Modeling & DDL Schema

### Entity-Relationship Diagram

```
Department (1) ──< Employee (1) ──< Attendance
                        │
                        ├──< Leave_Record
                        │
                        └──< Payroll
```

### Tables

| Table | Primary Key | Notable Constraints |
|-------|-------------|---------------------|
| `Department` | `dept_id` | `UNIQUE(dept_name)`, FK→Employee (manager, SET NULL) |
| `Employee` | `emp_id` | `UNIQUE(email)`, `CHECK(base_salary > 0)`, FK→Department (RESTRICT) |
| `Attendance` | `att_id` | `UNIQUE(emp_id, att_date)`, FK→Employee (CASCADE) |
| `Leave_Record` | `leave_id` | FK→Employee (CASCADE) |
| `Payroll` | `pay_id` | `UNIQUE(emp_id, pay_month, pay_year)`, `CHECK(pay_month BETWEEN 1 AND 12)` |

### 3NF Justification Summary

- **1NF**: All attributes atomic; no repeating groups; name split into `first_name`/`last_name`
- **2NF**: Single-column surrogates (no partial dependencies); composite keys in Attendance and Payroll have all non-key columns depending on the **full** key
- **3NF**: No transitive dependencies; `dept_id` FK (not `dept_name`) in Employee eliminates the `emp → dept_name → location` chain; payroll monetary values are facts of the payroll event

### How to Run

```sql
SOURCE phase1_schema.sql;
```

---

## Phase 2 — Procedural Logic & Seed Data

### Stored Function: `calculate_tax(salary DECIMAL)`

Implements **Indian New Tax Regime** (annualized):

| Annual Income Slab | Tax Rate |
|-------------------|----------|
| Up to 3,00,000 | 0% |
| 3,00,001 – 7,00,000 | 5% |
| 7,00,001 – 10,00,000 | 10% |
| 10,00,001 – 15,00,000 | 20% |
| Above 15,00,000 | 30% |

Takes **monthly** salary → annualizes → computes annual tax → returns **monthly** tax portion.

### Stored Procedure: `generate_monthly_payroll(in_month, in_year)`

- Iterates all employees via CURSOR with NOT FOUND handler
- Skips if payroll already exists for that period (idempotent)
- Counts approved UNPAID leave days overlapping the target month
- `unpaid_deduction = (base_salary / 22) × unpaid_leave_days`
- `net = base_salary − unpaid_deduction − tax`

### Triggers

| Trigger | Event | Action |
|---------|-------|--------|
| `before_leave_insert` | BEFORE INSERT on Leave_Record | Blocks overlapping APPROVED leave — SIGNAL SQLSTATE '45000' |
| `before_attendance_insert` | BEFORE INSERT on Attendance | Auto-sets status to 'LATE' if check_in > '09:30:00' |

### Seed Data

- **3 Departments**: IT, HR, Finance
- **10 Employees**: Indian names, salaries 45,000–1,50,000/month
- **~660 Attendance records**: Oct–Dec 2024, weekdays only, mix of PRESENT/LATE/ABSENT/HALF_DAY
- **17 Leave records**: Mix of types and statuses
- **Payroll**: Auto-generated via `CALL generate_monthly_payroll()` for Oct, Nov, Dec 2024

### How to Run

```sql
SOURCE phase2_procedures_triggers_seed.sql;
```

---

## Phase 3 — Reporting & Index Optimization

### Analytical Queries

**Query 1 — Monthly Attendance Summary per Employee**
Shows: emp_id, name, dept, present count, late count, absent count, half-day count

**Query 2 — Individual Salary Payslip**
Shows: formatted payslip with currency-formatted monetary values

**Query 3 — Company-wide Late-Mark Frequency Report**
Shows: all employees with >= 1 late mark, ordered by frequency DESC, includes avg per month

### Index Optimization

High-traffic query: `WHERE emp_id = 1 AND att_date BETWEEN '2024-10-01' AND '2024-10-31'`

| Stage | EXPLAIN type | Rows Scanned |
|-------|-------------|--------------|
| Before | `ALL` (full scan) | ~660 |
| After | `range` (B-tree) | ~22 |

```sql
CREATE INDEX idx_attendance_emp_date ON Attendance(emp_id, att_date);
-- Composite: equality on emp_id first, then range on att_date — optimal order
```

### How to Run

```sql
SOURCE phase3_reports_indexes.sql;
```

---

## Phase 4 — Transactions, RBAC & Test Cases

### RBAC

| User | Role | Permissions |
|------|------|-------------|
| `hr_admin@localhost` | `admin_hr_role` | ALL PRIVILEGES on `autopay_track.*` |
| `john_doe@localhost` | `employee_role` | SELECT on views only |

### ACID Transaction: `process_salary_bonus(p_emp_id, p_bonus_pct)`

```
START TRANSACTION
  → SELECT … FOR UPDATE  (Isolation: row lock)
  → UPDATE base_salary × (1 + bonus%)  (Atomicity)
  → INSERT/UPDATE Payroll for Jan 2025  (Consistency)
  → Validate net_salary > 0
  → COMMIT  (Durability via InnoDB redo log)
  
  On any error → EXIT HANDLER → ROLLBACK + SIGNAL
```

### Test Cases

| # | Test | Mechanism | Expected |
|---|------|-----------|---------|
| 1 | `CALL process_salary_bonus(1, 10.00)` | Valid ACID commit | Salary +10% |
| 2 | `UPDATE base_salary = -5000` | CHECK constraint | ERROR 3819 |
| 3 | Duplicate attendance same day | UNIQUE constraint | ERROR 1062 |
| 4 | Overlapping approved leave | Trigger SIGNAL | SQLSTATE 45000 |
| 5 | INSERT as `john_doe` | RBAC enforcement | ERROR 1142 |

### How to Run

```sql
SOURCE phase4_rbac_transactions_tests.sql;
```

---

## Phase 5 — Python CLI Interface

### Setup

```bash
pip install mysql-connector-python
python3 phase5_python_cli.py
```

### Login Credentials

| Username | Password | Role |
|----------|----------|------|
| `hr_admin` | `HrAdmin@2024` | HR/Admin — full menu |
| `john_doe` | `JohnDoe@2024` | Employee — personal data only |

### HR Admin Menu
1. Add New Employee (with validation)
2. Generate Monthly Payroll (calls stored procedure)
3. View Monthly Attendance Report (formatted table)
4. View All Employees
5. Exit

### Employee Menu
1. View My Monthly Attendance
2. View My Payslip (formatted payslip box)
3. View My Leave History
4. Exit

---

## Execution Order (Critical)

```bash
# 1 — Schema
mysql -u root -p < phase1_schema.sql

# 2 — Procedures, triggers, seed data
mysql -u root -p < phase2_procedures_triggers_seed.sql

# 3 — Reports and indexes
mysql -u root -p < phase3_reports_indexes.sql

# 4 — RBAC and test cases
mysql -u root -p < phase4_rbac_transactions_tests.sql

# 5 — Python CLI
pip install mysql-connector-python
python3 phase5_python_cli.py
```

---

## Prerequisites

- **MySQL 8.0.16+** (required for CHECK constraint enforcement)
- **Python 3.8+**
- **`mysql-connector-python`** (`pip install mysql-connector-python`)
- MySQL root access to create databases, roles, and users

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Surrogate PKs (AUTO_INCREMENT) | Avoids natural-key fragility; stable FK targets |
| `DECIMAL(12,2)` for money | Exact precision; avoids floating-point rounding errors |
| `ON DELETE CASCADE` for Attendance/Leave/Payroll | Employee deletion cleanly removes all dependent records |
| `ON DELETE RESTRICT` for Employee→Department | Prevents orphaning employees; HR must reassign first |
| `ON DELETE SET NULL` for Department→Manager | Department survives; manager slot becomes vacant |
| Payroll stores computed values | Audit trail — historical payslip accurate even after salary changes |
| 22 working days standard | Standard Indian corporate norm; easily configurable constant |
| `before_attendance_insert` trigger | Enforces 09:30 cutoff automatically — no app-layer dependency |

---

*AutoPay & Track — DBMS Capstone Project | MySQL + Python*
