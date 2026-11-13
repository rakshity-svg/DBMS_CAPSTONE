-- ============================================================================================================================
-- PROJECT  : AutoPay & Track — Integrated Payroll & Attendance Management System
-- PHASE    : 3 — Reporting & Index Optimization
-- FILE     : phase3_reports_indexes.sql
-- AUTHOR   : DBMS Capstone Team
-- DATE     : November 2024
-- ============================================================================================================================
--
-- OVERVIEW
-- --------
-- This phase delivers two key deliverables:
--
--   SECTION 1 — ANALYTICAL QUERIES
--     Three production-ready reporting queries covering:
--       1. Monthly Attendance Summary per Employee  — HR dashboard / attendance register
--       2. Individual Salary Payslip               — Finance / employee self-service payslip
--       3. Company-wide Late-Mark Frequency Report  — HR discipline monitoring
--
--   SECTION 2 — INDEX OPTIMIZATION
--     Demonstration of MySQL EXPLAIN-driven index analysis on the highest-traffic
--     query pattern (attendance date-range lookups), plus four composite indexes
--     that benefit the most common access patterns in this system.
--
-- HOW TO RUN
-- ----------
--   mysql -u root -p < phase3_reports_indexes.sql
--   OR paste each section in MySQL Workbench / DBeaver after selecting the schema.
-- ============================================================================================================================

USE autopay_track;

-- ============================================================================================================================
-- ██████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████
-- SECTION 1 — ANALYTICAL QUERIES
-- ██████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████
-- ============================================================================================================================


-- ============================================================================================================================
-- QUERY 1: Monthly Attendance Summary per Employee
-- ============================================================================================================================
-- PURPOSE
-- -------
-- Gives HR/management a consolidated view of every employee's attendance behaviour for a
-- chosen calendar month.  Returned columns:
--   emp_id            — unique employee identifier
--   full_name         — concatenated first + last name
--   department        — department the employee belongs to
--   total_present     — days marked PRESENT
--   total_late        — days marked LATE (arrived after cut-off time)
--   total_absent      — days marked ABSENT (unauthorised absence)
--   total_half_day    — days marked HALF_DAY
--   total_days_recorded — total rows in Attendance for this employee/month
--                         (useful for spotting missing records)
--
-- PARAMETER CUSTOMISATION
-- -----------------------
-- To change the target month/year, replace the two literals below:
--   MONTH(a.att_date) = <target_month>   e.g. 11  for November
--   YEAR(a.att_date)  = <target_year>    e.g. 2024
--
-- Current example: October 2024  (month=10, year=2024)
--
-- DESIGN NOTES
-- ------------
-- • INNER JOIN to Employee ensures only employees with at least one attendance record for
--   the period are shown.  Change to LEFT JOIN on Attendance if you want employees with
--   ZERO records visible (they would show all-zero counts).
-- • Conditional aggregation (SUM + CASE WHEN) is preferred over multiple sub-queries
--   because it makes a single pass over the filtered rows — O(n) rather than O(k*n).
-- • GROUP BY uses emp_id (the primary key) which is deterministic; full_name and dept_name
--   are functionally dependent on emp_id/dept_id so including them in the SELECT is valid
--   under MySQL's default sql_mode (and correct regardless of mode because they are
--   logically dependent on the GROUP BY key).
-- • ORDER BY d.dept_name, full_name gives a natural alphabetical listing useful for
--   printed attendance registers.
-- ============================================================================================================================

-- ► To change month: replace 10 with 1-12.  To change year: replace 2024.
SELECT
    e.emp_id                                                AS emp_id,
    CONCAT(e.first_name, ' ', e.last_name)                  AS full_name,
    d.dept_name                                             AS department,

    -- Count rows where status = 'PRESENT' for the month
    SUM(CASE WHEN a.status = 'PRESENT'  THEN 1 ELSE 0 END) AS total_present,

    -- Count rows where status = 'LATE' for the month
    SUM(CASE WHEN a.status = 'LATE'     THEN 1 ELSE 0 END) AS total_late,

    -- Count rows where status = 'ABSENT' for the month
    SUM(CASE WHEN a.status = 'ABSENT'   THEN 1 ELSE 0 END) AS total_absent,

    -- Count rows where status = 'HALF_DAY' for the month
    SUM(CASE WHEN a.status = 'HALF_DAY' THEN 1 ELSE 0 END) AS total_half_day,

    -- Total rows recorded for this employee in the month (should equal working days)
    COUNT(a.att_id)                                         AS total_days_recorded

FROM       Employee   e
INNER JOIN Department d  ON d.dept_id = e.dept_id

-- Join only the attendance rows that fall in the target month & year
INNER JOIN Attendance  a  ON a.emp_id = e.emp_id
                          AND MONTH(a.att_date) = 10   -- ← change month here (1-12)
                          AND YEAR(a.att_date)  = 2024 -- ← change year  here

GROUP BY
    e.emp_id,
    full_name,
    d.dept_name

ORDER BY
    d.dept_name   ASC,   -- alphabetical by department first
    full_name     ASC;   -- then alphabetical by employee name within department


-- ============================================================================================================================
-- QUERY 2: Individual Salary Payslip
-- ============================================================================================================================
-- PURPOSE
-- -------
-- Generates a single-row payslip for a specific employee and pay period.  This is the
-- canonical output for the "View Payslip" feature in an employee self-service portal.
--
-- Returned fields (all aliased to human-readable labels):
--   Employee Name         — full name
--   Job Title             — designation / role
--   Department            — department name
--   Pay Period            — human-readable "Month / Year" label
--   Base Salary           — contracted monthly CTC base (from Employee table)
--   Gross Salary          — base minus unpaid-leave deduction (from Payroll table)
--   Unpaid Leave Deduction— amount deducted for unpaid leave days
--   Tax Deduction         — computed tax (via calculate_tax() in Phase 2)
--   Net Salary            — final take-home amount
--   Payment Status        — PENDING / PROCESSED / FAILED
--
-- PARAMETER CUSTOMISATION
-- -----------------------
-- Replace the literals in the WHERE clause to generate a different payslip:
--   p.emp_id    = <employee_id>   e.g. 3  for employee #3
--   p.pay_month = <month>         e.g. 11 for November
--   p.pay_year  = <year>          e.g. 2024
--
-- Current example: Employee #1, December 2024  (emp_id=1, month=12, year=2024)
--
-- DESIGN NOTES
-- ------------
-- • CONCAT_WS(' / ', ...) produces a readable "12 / 2024" label for the pay period.
-- • LPAD is used to zero-pad the month so "2 / 2024" becomes "02 / 2024" — consistent
--   with standard payslip formatting.
-- • FORMAT(value, 2) would add thousands-separators for display (optional); raw DECIMAL
--   values are returned here so application layer can apply locale-specific formatting.
-- • The query returns at most 1 row (enforced by the UNIQUE(emp_id, pay_month, pay_year)
--   constraint on the Payroll table, plus the emp_id filter).
-- ============================================================================================================================

-- ► To change employee: replace emp_id = 1.  To change period: replace pay_month / pay_year.
SELECT
    -- Identity block
    CONCAT(e.first_name, ' ', e.last_name)                                        AS `Employee Name`,
    e.job_title                                                                    AS `Job Title`,
    d.dept_name                                                                    AS `Department`,

    -- Pay period formatted as "MM / YYYY"
    CONCAT(LPAD(p.pay_month, 2, '0'), ' / ', p.pay_year)                          AS `Pay Period (MM/YYYY)`,

    -- Earnings & deductions block
    CONCAT('₹ ', FORMAT(e.base_salary,              2))                           AS `Base Salary (₹)`,
    CONCAT('₹ ', FORMAT(p.gross_salary,             2))                           AS `Gross Salary (₹)`,
    CONCAT('₹ ', FORMAT(p.unpaid_leave_deduction,   2))                           AS `Unpaid Leave Deduction (₹)`,
    CONCAT('₹ ', FORMAT(p.tax_deduction,            2))                           AS `Tax Deduction (₹)`,
    CONCAT('₹ ', FORMAT(p.net_salary,               2))                           AS `Net Salary (Take-Home) (₹)`,

    -- Status
    p.payment_status                                                               AS `Payment Status`

FROM       Payroll     p
INNER JOIN Employee    e  ON e.emp_id  = p.emp_id
INNER JOIN Department  d  ON d.dept_id = e.dept_id

WHERE
    p.emp_id    = 1   -- ← change employee ID here
    AND p.pay_month = 12  -- ← change pay month here (1-12)
    AND p.pay_year  = 2024; -- ← change pay year  here


-- ============================================================================================================================
-- QUERY 3: Company-wide Late-Mark Frequency Report
-- ============================================================================================================================
-- PURPOSE
-- -------
-- Surfaces the employees who arrive late most frequently, helping HR identify patterns of
-- habitual tardiness.  Only employees with at least one late mark ever are included.
--
-- Returned columns:
--   emp_id              — employee identifier
--   full_name           — full name
--   department          — department name
--   total_late_marks    — lifetime count of LATE attendance records
--   latest_late_date    — the most recent date the employee was marked LATE
--   avg_late_marks_per_month — total_late_marks divided by the number of distinct
--                              calendar months in which ANY attendance was recorded
--                              (gives a normalised rate even if data spans different
--                              periods for different employees)
--
-- DESIGN NOTES
-- ------------
-- • HAVING COUNT(...) >= 1 filters out employees with zero late marks efficiently —
--   the aggregate is computed only once from the already-grouped rows.
-- • avg_late_marks_per_month uses COUNT(DISTINCT YEAR(a.att_date)*100 + MONTH(a.att_date))
--   as the denominator, which counts the number of unique year-month combinations present
--   in the Attendance table for that employee.  This avoids division by zero (an employee
--   must have at least one row to appear) and handles employees hired mid-dataset.
-- • ROUND(..., 2) gives a 2-decimal precision average suitable for display.
-- • ORDER BY total_late_marks DESC brings the most problematic employees to the top.
-- ============================================================================================================================

SELECT
    e.emp_id                                                               AS emp_id,
    CONCAT(e.first_name, ' ', e.last_name)                                 AS full_name,
    d.dept_name                                                            AS department,

    -- Total LATE marks across ALL recorded months
    SUM(CASE WHEN a.status = 'LATE' THEN 1 ELSE 0 END)                    AS total_late_marks,

    -- Most recent date this employee was marked LATE
    MAX(CASE WHEN a.status = 'LATE' THEN a.att_date ELSE NULL END)         AS latest_late_date,

    -- Average late marks per month (normalised across the employee's data span)
    -- Denominator = number of distinct YEAR-MONTH combinations in attendance
    ROUND(
        SUM(CASE WHEN a.status = 'LATE' THEN 1 ELSE 0 END)
        /
        COUNT(DISTINCT YEAR(a.att_date) * 100 + MONTH(a.att_date))
    , 2)                                                                   AS avg_late_marks_per_month

FROM       Attendance  a
INNER JOIN Employee    e  ON e.emp_id  = a.emp_id
INNER JOIN Department  d  ON d.dept_id = e.dept_id

GROUP BY
    e.emp_id,
    full_name,
    department

-- Only include employees who have been LATE at least once
HAVING
    SUM(CASE WHEN a.status = 'LATE' THEN 1 ELSE 0 END) >= 1

ORDER BY
    total_late_marks DESC,   -- most tardiness first
    full_name        ASC;    -- alphabetical tie-break


-- ============================================================================================================================
-- ██████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████
-- SECTION 2 — INDEX OPTIMIZATION
-- ██████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████
-- ============================================================================================================================
--
-- BACKGROUND — WHY INDEXES MATTER
-- --------------------------------
-- Without any index on a column used in WHERE / JOIN / ORDER BY, MySQL performs a
-- FULL TABLE SCAN: every row in the table is read, compared, and either kept or
-- discarded.  For a table with 660+ attendance rows today that is acceptable, but as
-- the company grows — 3 years × 500 employees × 22 days = 330 000 rows — a full scan
-- becomes prohibitively slow.
--
-- An INDEX is a sorted, secondary data structure (B-tree in InnoDB) that lets the
-- storage engine jump directly to the first matching row and traverse a small, ordered
-- range instead of reading every row.
--
-- KEY EXPLAIN OUTPUT COLUMNS
-- --------------------------
--   type        — access method used by the optimizer:
--                   ALL   = full table scan  (worst for large tables)
--                   index = full index scan  (better than ALL, still reads entire index)
--                   range = index range scan (excellent — reads only matching range)
--                   ref   = non-unique index lookup (excellent for equality)
--                   eq_ref= unique index lookup     (best possible for joins)
--                   const = single-row lookup via primary/unique key (best for single row)
--
--   key         — which index the optimizer chose (NULL = no index used)
--   key_len     — number of bytes of the index used (longer = more columns used)
--   rows        — estimated number of rows examined (lower = more selective/efficient)
--   Extra       — supplementary info:
--                   "Using index"           = covering index (no table row fetch needed)
--                   "Using where"           = post-index filter still applied
--                   "Using index condition" = Index Condition Pushdown (ICP) active
--
-- HIGH-TRAFFIC QUERY CHOSEN FOR ANALYSIS
-- ---------------------------------------
-- Pattern: Monthly attendance lookup for a given employee
--   SELECT * FROM Attendance WHERE emp_id = ? AND att_date BETWEEN ? AND ?;
--
-- Why high-traffic?
--   • Called every time an employee views their attendance calendar.
--   • Called by generate_monthly_payroll() internally for EVERY employee EVERY month.
--   • Called by Query 1 above (attendance summary) for every employee in the report.
-- ============================================================================================================================


-- ----------------------------------------------------------------------------------------------------------------------------
-- STEP 1: EXPLAIN BEFORE INDEX — expect type=ALL (full table scan)
-- ----------------------------------------------------------------------------------------------------------------------------
-- With no composite index on (emp_id, att_date), MySQL must:
--   1. Read every row in Attendance from the first leaf page to the last.
--   2. For each row, evaluate: does emp_id = 1 AND att_date BETWEEN '...' AND '...'?
--   3. Keep only matching rows.
--
-- Expected EXPLAIN output (approximate):
--   id | select_type | table      | type | key  | rows | Extra
--    1 | SIMPLE      | Attendance | ALL  | NULL |  660 | Using where
--
-- "type=ALL" and "key=NULL" confirm zero index usage.
-- "rows≈660" means the engine reads ALL 660 rows just to find ~22 that match.
-- ----------------------------------------------------------------------------------------------------------------------------

-- Before index — full table scan expected
EXPLAIN
SELECT *
FROM   Attendance
WHERE  emp_id   = 1
  AND  att_date BETWEEN '2024-10-01' AND '2024-10-31';


-- ----------------------------------------------------------------------------------------------------------------------------
-- STEP 2: CREATE COMPOSITE INDEX idx_attendance_emp_date ON Attendance(emp_id, att_date)
-- ----------------------------------------------------------------------------------------------------------------------------
-- HOW A COMPOSITE (MULTI-COLUMN) INDEX WORKS
-- -------------------------------------------
-- A composite index sorts rows first by the leftmost column (emp_id), then within
-- equal emp_id values by the next column (att_date).  Conceptually the B-tree leaf
-- entries look like:
--
--   (emp_id=1, att_date=2024-10-01) → rowid
--   (emp_id=1, att_date=2024-10-02) → rowid
--   ...
--   (emp_id=1, att_date=2024-12-31) → rowid
--   (emp_id=2, att_date=2024-10-01) → rowid
--   ...
--
-- For the query  WHERE emp_id = 1 AND att_date BETWEEN '2024-10-01' AND '2024-10-31':
--   1. MySQL uses the emp_id part to jump straight to the section of the index where
--      emp_id=1 (eliminating all other employees' rows without reading them).
--   2. Within that section, it performs a range scan on att_date between Oct 1 and Oct 31.
--   3. Only ~22 rows are read instead of 660.
--
-- WHY COLUMN ORDER MATTERS
-- ------------------------
-- The rule is: columns used for EQUALITY conditions first, range/BETWEEN columns last.
-- • (emp_id, att_date) — correct. emp_id is the equality predicate; att_date is the range.
-- • (att_date, emp_id) — wrong for this query. The range on att_date would prevent MySQL
--   from using the second column (emp_id) for filtering in the same range scan.  The
--   optimizer would still have to read all dates then filter by emp_id.
--
-- If MySQL already created a unique index on (emp_id, att_date) for the UNIQUE constraint
-- defined in the DDL, this index may already exist under a system-generated name.
-- Using CREATE INDEX with IF NOT EXISTS (MySQL 8.0+) or simply running it and checking
-- for duplicate key errors is the safe approach; we include IF NOT EXISTS here.
-- ----------------------------------------------------------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_attendance_emp_date
    ON Attendance(emp_id, att_date);
-- Composite index: emp_id (equality) first, att_date (range) second.
-- Enables efficient monthly/range lookups per employee.


-- ----------------------------------------------------------------------------------------------------------------------------
-- STEP 3: EXPLAIN AFTER INDEX — expect type=range, dramatically fewer rows examined
-- ----------------------------------------------------------------------------------------------------------------------------
-- After the index is created MySQL's optimizer will recognise that it can satisfy the
-- entire WHERE clause via an index range scan.
--
-- Expected EXPLAIN output (approximate):
--   id | select_type | table      | type  | key                      | key_len | rows | Extra
--    1 | SIMPLE      | Attendance | range | idx_attendance_emp_date  |    7    |  22  | Using index condition
--
-- Key improvements:
--   type    : ALL  → range   (full table scan eliminated)
--   key     : NULL → idx_attendance_emp_date  (index chosen)
--   rows    : 660  → ~22     (only the rows for employee #1 in October are examined)
--   Extra   : "Using index condition" — ICP active; att_date filter evaluated at engine
--             level while reading the index, before fetching the full row
--   key_len : 7 bytes = 4 (INT for emp_id) + 3 (DATE for att_date)
--             — both columns of the composite index are being used
-- ----------------------------------------------------------------------------------------------------------------------------

-- After index — index range scan, reduced rows
EXPLAIN
SELECT *
FROM   Attendance
WHERE  emp_id   = 1
  AND  att_date BETWEEN '2024-10-01' AND '2024-10-31';


-- ============================================================================================================================
-- STEP 4: ADDITIONAL SUPPORTING INDEXES
-- ============================================================================================================================
-- Beyond the primary attendance lookup, the following indexes cover the remaining
-- high-frequency access patterns identified in Phase 2 (stored procedure, trigger)
-- and Phase 3 (the three analytical queries above).
-- ============================================================================================================================


-- ----------------------------------------------------------------------------------------------------------------------------
-- INDEX: idx_payroll_emp_month  ON Payroll(emp_id, pay_month, pay_year)
-- ----------------------------------------------------------------------------------------------------------------------------
-- QUERY PATTERNS OPTIMISED
-- • generate_monthly_payroll() checks:
--     SELECT ... FROM Payroll WHERE emp_id = ? AND pay_month = ? AND pay_year = ?
--   (duplicate-payroll guard before INSERT)
-- • Query 2 (payslip) filters:
--     WHERE p.emp_id = ? AND p.pay_month = ? AND p.pay_year = ?
-- • Any "fetch last N months of payroll" report filters by emp_id.
--
-- HOW IT HELPS
-- • emp_id equality → jumps to that employee's payroll rows.
-- • pay_month & pay_year equality (or range) → narrows to the exact month(s) needed.
-- • With only 3 rows per employee (Oct/Nov/Dec) in this dataset the benefit is modest,
--   but as years accumulate the index prevents full scans over hundreds of rows per employee.
-- • NOTE: The UNIQUE(emp_id, pay_month, pay_year) constraint defined on the table already
--   creates an implicit unique index; this explicit named index is therefore typically
--   redundant if the unique key already exists. It is shown here for documentation clarity.
--   In a production system, verify with SHOW INDEX FROM Payroll; before running.
-- ----------------------------------------------------------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_payroll_emp_month
    ON Payroll(emp_id, pay_month, pay_year);
-- Composite index on Payroll: supports payroll existence checks in the stored
-- procedure and payslip lookup queries filtering by employee + month + year.


-- ----------------------------------------------------------------------------------------------------------------------------
-- INDEX: idx_leave_emp_dates  ON Leave_Record(emp_id, start_date, end_date)
-- ----------------------------------------------------------------------------------------------------------------------------
-- QUERY PATTERNS OPTIMISED
-- • generate_monthly_payroll() counts unpaid leaves:
--     SELECT COUNT(*) FROM Leave_Record
--     WHERE emp_id = ? AND leave_type = 'UNPAID' AND status = 'APPROVED'
--       AND start_date <= last_day AND end_date >= first_day
--   (determines how many unpaid-leave days fall within the pay period)
-- • Any "leave calendar" query filtering by employee and overlapping date range.
--
-- HOW IT HELPS
-- • emp_id equality → jumps directly to that employee's leave records.
-- • start_date range → then scans only leaves starting on or before the month end.
-- • end_date is included in the index as a covering column so the BETWEEN / >= filter
--   on end_date can be evaluated from the index without fetching the full row
--   (Index Condition Pushdown).
--
-- COLUMN ORDER RATIONALE
-- • (emp_id, start_date, end_date): equality on emp_id allows the range on start_date
--   to be used efficiently.  end_date follows to allow partial covering reads.
--   Reversing to (start_date, end_date, emp_id) would only help queries filtering by
--   date range across ALL employees — not the per-employee pattern used here.
-- ----------------------------------------------------------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_leave_emp_dates
    ON Leave_Record(emp_id, start_date, end_date);
-- Composite index on Leave_Record: supports per-employee overlapping date range
-- lookups used in payroll generation and leave calendar views.


-- ----------------------------------------------------------------------------------------------------------------------------
-- INDEX: idx_attendance_status  ON Attendance(status, att_date)
-- ----------------------------------------------------------------------------------------------------------------------------
-- QUERY PATTERNS OPTIMISED
-- • Query 3 (Late-Mark Frequency Report) in a simplified variant:
--     SELECT * FROM Attendance WHERE status = 'LATE' AND att_date >= '2024-01-01'
-- • Any HR query filtering all LATE/ABSENT records across a date range company-wide,
--   e.g. "show me all ABSENT records in December 2024".
-- • Dashboard widgets counting absences or late arrivals for a specific period.
--
-- HOW IT HELPS
-- • status (low cardinality ENUM, 5 values) is the leading column because queries of
--   this type always specify an exact status value (equality predicate), making it
--   highly selective for a given status category.
-- • att_date follows as the range column; within a given status value the dates are
--   sorted, so a date BETWEEN filter reads only the relevant range of rows.
--
-- NOTE ON CARDINALITY
-- Low-cardinality columns (like ENUM with 5 values) can sometimes lead the optimizer
-- to skip an index and prefer a full table scan if most rows share the same status value.
-- For example, if 60% of rows are PRESENT, an index scan for status='PRESENT' might
-- read more rows than a full scan skips.  The optimizer uses statistics to decide.
-- This index is most beneficial when querying minority statuses like 'ABSENT' or 'HOLIDAY'.
-- Use FORCE INDEX(idx_attendance_status) in a specific query only if profiling shows
-- the optimizer is not choosing it when it should.
-- ----------------------------------------------------------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_attendance_status
    ON Attendance(status, att_date);
-- Composite index on Attendance: optimises status-filtered + date-ranged queries
-- (e.g., "all LATE records in October", "all ABSENT records this quarter").


-- ============================================================================================================================
-- COMPOSITE INDEX SUMMARY TABLE
-- ============================================================================================================================
--
--  Index Name                 | Table         | Columns                        | Primary Benefit
--  ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
--  idx_attendance_emp_date    | Attendance    | emp_id, att_date               | Per-employee monthly/range lookups
--  idx_payroll_emp_month      | Payroll       | emp_id, pay_month, pay_year    | Payslip fetch; duplicate-payroll check
--  idx_leave_emp_dates        | Leave_Record  | emp_id, start_date, end_date   | Per-employee leave overlap detection
--  idx_attendance_status      | Attendance    | status, att_date               | Status-category date-range reports
--  ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
--
-- GENERAL INDEX DESIGN PRINCIPLES APPLIED
-- ----------------------------------------
-- 1. EQUALITY BEFORE RANGE: columns used with = or IN come before columns used with
--    BETWEEN, >, <, or LIKE in a composite index — this lets MySQL use the index for
--    the full prefix, not just the first column.
--
-- 2. SELECTIVITY: place the most selective (highest cardinality) column first among
--    equality columns.  emp_id (10 values in test data, thousands in production) is
--    more selective than status (5 values) for per-employee queries.
--
-- 3. COVERING INDEXES: when all columns needed by a query are IN the index, MySQL can
--    serve the query entirely from the index without touching the clustered (primary)
--    index — shown as "Using index" in EXPLAIN Extra.  Consider adding frequently
--    SELECT-ed columns to composite indexes as trailing columns for this benefit.
--
-- 4. INDEX MAINTENANCE COST: every INSERT/UPDATE/DELETE must update all indexes on the
--    table.  Avoid creating redundant or overlapping indexes.  Review with
--    SHOW INDEX FROM <table>; and use performance_schema.table_io_waits_summary_by_index_usage
--    to identify unused indexes for removal.
--
-- 5. EXPLAIN IS ALWAYS APPROXIMATE: the optimizer uses cost estimates based on table
--    statistics.  Run ANALYZE TABLE <name>; after bulk data loads to refresh statistics
--    so the optimizer makes well-informed decisions.
-- ============================================================================================================================

-- End of Phase 3 — Reporting & Index Optimization
