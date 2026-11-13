-- ============================================================================================================================
-- PROJECT  : AutoPay & Track — Integrated Payroll & Attendance Management System
-- PHASE    : 4 — Transactions, Role-Based Access Control (RBAC) & Test Cases
-- FILE     : phase4_rbac_transactions_tests.sql
-- AUTHOR   : Capstone Team
-- ENGINE   : MySQL 8.0+  (InnoDB, utf8mb4)
-- PURPOSE  : Implements security (Views + Roles + Users), an ACID-compliant stored procedure
--            for salary bonus processing, and a full suite of SQL test cases covering
--            constraint violations, trigger behaviour, and privilege enforcement.
-- ============================================================================================================================

USE autopay_track;

-- ============================================================================================================================
-- ██████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████
-- SECTION 1 : ROLE-BASED ACCESS CONTROL (RBAC) SETUP
-- ██████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████
-- ============================================================================================================================

-- ------------------------------------------------------------
-- 1-A  VIEWS — Restricted projections of sensitive tables
-- ------------------------------------------------------------
-- Views act as the first line of defence: they expose only the
-- columns that a given role needs to see, hiding confidential
-- or auditable fields (e.g. tax_deduction, unpaid_leave_deduction,
-- check_in/check_out times are still visible here but raw table
-- DML is blocked for the employee role).
-- ------------------------------------------------------------

-- Drop if already exists so this script is safely re-runnable
DROP VIEW IF EXISTS vw_emp_attendance;
DROP VIEW IF EXISTS vw_emp_payroll;

-- View 1 : Employee attendance — read-only snapshot
--   Exposed  : att_id, emp_id, att_date, check_in, check_out, status
--   Hidden   : nothing additional at the column level, but DML is
--              blocked for the 'employee_role' at the GRANT level.
CREATE VIEW vw_emp_attendance AS
    SELECT
        att_id,
        emp_id,
        att_date,
        check_in,
        check_out,
        status
    FROM Attendance;

-- View 2 : Employee payroll — sanitised payslip view
--   Exposed  : pay_id, emp_id, pay_month, pay_year, gross_salary,
--              net_salary, payment_status
--   Hidden   : unpaid_leave_deduction, tax_deduction, processed_on
--              (internal accounting fields not meant for employees)
CREATE VIEW vw_emp_payroll AS
    SELECT
        pay_id,
        emp_id,
        pay_month,
        pay_year,
        gross_salary,
        net_salary,
        payment_status
    FROM Payroll;

-- ------------------------------------------------------------
-- 1-B  ROLES & USERS
-- ------------------------------------------------------------

-- ── Roles ──────────────────────────────────────────────────

-- admin_hr_role : Full DBA/HR access to the entire schema
DROP ROLE IF EXISTS 'admin_hr_role';
CREATE ROLE 'admin_hr_role';
GRANT ALL PRIVILEGES ON autopay_track.* TO 'admin_hr_role';

-- employee_role : Read-only access to the two sanitised views
DROP ROLE IF EXISTS 'employee_role';
CREATE ROLE 'employee_role';
GRANT SELECT ON autopay_track.vw_emp_attendance TO 'employee_role';
GRANT SELECT ON autopay_track.vw_emp_payroll    TO 'employee_role';

-- ── Users ───────────────────────────────────────────────────

-- hr_admin : HR administrator — maps to admin_hr_role
DROP USER IF EXISTS 'hr_admin'@'localhost';
CREATE USER 'hr_admin'@'localhost' IDENTIFIED BY 'HrAdmin@2024';
GRANT 'admin_hr_role' TO 'hr_admin'@'localhost';

-- john_doe : Regular employee — maps to employee_role
DROP USER IF EXISTS 'john_doe'@'localhost';
CREATE USER 'john_doe'@'localhost' IDENTIFIED BY 'JohnDoe@2024';
GRANT 'employee_role' TO 'john_doe'@'localhost';

-- Activate the roles automatically on login (MySQL 8 default-role)
SET DEFAULT ROLE ALL TO 'hr_admin'@'localhost', 'john_doe'@'localhost';

-- ── Flush to apply immediately ──────────────────────────────
FLUSH PRIVILEGES;

-- ------------------------------------------------------------
-- 1-C  ACCESS CONTROL DOCUMENTATION
-- ------------------------------------------------------------
/*
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │                      RBAC ACCESS MATRIX                                      │
  ├─────────────────┬────────────────┬─────────────────────────────────────────-─┤
  │ User            │ Role           │ Access summary                             │
  ├─────────────────┼────────────────┼────────────────────────────────────────────┤
  │ hr_admin        │ admin_hr_role  │ ✔ ALL PRIVILEGES on autopay_track.*        │
  │ @localhost      │                │   - SELECT / INSERT / UPDATE / DELETE on   │
  │                 │                │     ALL tables and views                   │
  │                 │                │   - CREATE / DROP / ALTER objects          │
  │                 │                │   - EXECUTE stored procedures & functions  │
  │                 │                │   - CALL generate_monthly_payroll(...)     │
  │                 │                │   - CALL process_salary_bonus(...)         │
  ├─────────────────┼────────────────┼────────────────────────────────────────────┤
  │ john_doe        │ employee_role  │ ✔ SELECT on vw_emp_attendance (view only)  │
  │ @localhost      │                │ ✔ SELECT on vw_emp_payroll   (view only)   │
  │                 │                │                                            │
  │                 │                │ ✘ NO SELECT on base tables directly        │
  │                 │                │   (Employee, Attendance, Payroll, etc.)    │
  │                 │                │ ✘ NO INSERT / UPDATE / DELETE anywhere     │
  │                 │                │ ✘ NO EXECUTE on stored procedures          │
  │                 │                │ ✘ NO CREATE / DROP / ALTER                 │
  │                 │                │ ✘ Cannot see tax_deduction,                │
  │                 │                │   unpaid_leave_deduction, processed_on     │
  │                 │                │   (hidden by the view projection)          │
  └─────────────────┴────────────────┴────────────────────────────────────────────┘

  Design rationale
  ─────────────────
  • Views replace direct table grants for employees: even if a user somehow
    obtained a SELECT grant on Payroll, the view still filters sensitive columns.
  • MySQL 8 roles make privilege bundles reusable — adding a new employee just
    means GRANT 'employee_role' TO '<new_user>'@'localhost', no per-user GRANT
    churn needed.
  • SET DEFAULT ROLE ALL ensures roles are auto-activated at login without
    requiring every session to call SET ROLE manually.
  • Passwords use a mix of upper/lower/digit/symbol to satisfy the default
    validate_password plugin (policy = MEDIUM).
*/


-- ============================================================================================================================
-- ██████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████
-- SECTION 2 : ACID TRANSACTION — process_salary_bonus STORED PROCEDURE
-- ██████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████
-- ============================================================================================================================

/*
  ACID properties demonstrated by this procedure
  ───────────────────────────────────────────────
  Atomicity   : All five steps (validate → lock → update salary → insert payroll
                → verify net_salary) succeed together or the whole transaction
                rolls back via the SQLEXCEPTION handler.
  Consistency : The CHECK (base_salary > 0) constraint on Employee, the UNIQUE
                (emp_id, pay_month, pay_year) constraint on Payroll, and the
                net_salary > 0 business rule are all enforced; a violation
                triggers ROLLBACK, keeping data valid.
  Isolation   : SELECT … FOR UPDATE places a row-level exclusive lock on the
                Employee row for the duration of the transaction, preventing
                concurrent sessions from reading a stale salary before our UPDATE
                is visible (READ COMMITTED / REPEATABLE READ compatible).
  Durability  : COMMIT flushes the change to the InnoDB redo log; a crash after
                COMMIT will not lose the salary increment or the payroll record.
*/

DROP PROCEDURE IF EXISTS process_salary_bonus;

DELIMITER $$

CREATE PROCEDURE process_salary_bonus(
    IN  p_emp_id     INT,
    IN  p_bonus_pct  DECIMAL(5,2)   -- e.g. 10.00 means 10 %
)
BEGIN
    -- ── Local variables ────────────────────────────────────────────────────────
    DECLARE v_emp_count       INT            DEFAULT 0;
    DECLARE v_current_salary  DECIMAL(12,2)  DEFAULT 0.00;
    DECLARE v_new_salary      DECIMAL(12,2)  DEFAULT 0.00;
    DECLARE v_gross_salary    DECIMAL(12,2)  DEFAULT 0.00;
    DECLARE v_tax             DECIMAL(12,2)  DEFAULT 0.00;
    DECLARE v_net_salary      DECIMAL(12,2)  DEFAULT 0.00;
    DECLARE v_payroll_exists  INT            DEFAULT 0;

    -- ── Error-handling flag ────────────────────────────────────────────────────
    DECLARE v_error_occurred  TINYINT        DEFAULT 0;
    DECLARE v_error_msg       VARCHAR(500)   DEFAULT '';

    -- ── SQLEXCEPTION handler — catches ANY MySQL error ─────────────────────────
    -- Sets a flag; actual ROLLBACK + SIGNAL happen in the procedural block below
    -- (handlers inside a transaction cannot themselves contain ROLLBACK in older
    --  MySQL; we roll back in the ELSE branch after checking the flag).
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1
            v_error_msg = MESSAGE_TEXT;
        SET v_error_occurred = 1;
        ROLLBACK;
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = v_error_msg;
    END;

    -- ── Input validation ───────────────────────────────────────────────────────
    IF p_bonus_pct <= 0 OR p_bonus_pct > 100 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Error: bonus_pct must be between 0.01 and 100.00';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════════
    START TRANSACTION;
    -- ══════════════════════════════════════════════════════════════════════════

    -- ── Step 1 : Validate employee exists & lock the row ──────────────────────
    -- FOR UPDATE acquires an exclusive row lock preventing concurrent salary
    -- updates until this transaction commits or rolls back.
    SELECT base_salary
      INTO v_current_salary
      FROM Employee
     WHERE emp_id = p_emp_id
       FOR UPDATE;

    -- ROW NOT FOUND → handler fires; we signal explicitly for clarity
    IF v_current_salary IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Error: Employee not found.';
    END IF;

    -- ── Step 2 : Calculate new salary (bonus applied) ─────────────────────────
    -- v_new_salary = current_salary * (1 + bonus_pct / 100)
    SET v_new_salary = ROUND(v_current_salary * (1 + p_bonus_pct / 100.00), 2);

    -- Safety net: new salary must remain positive
    IF v_new_salary <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Error: Computed new salary is not positive.';
    END IF;

    -- ── Step 3 : Apply the salary increase ───────────────────────────────────
    UPDATE Employee
       SET base_salary = v_new_salary
     WHERE emp_id = p_emp_id;

    -- ── Step 4 : Regenerate payroll for January 2025 ─────────────────────────
    -- Check whether a payroll record already exists for Jan 2025
    SELECT COUNT(*)
      INTO v_payroll_exists
      FROM Payroll
     WHERE emp_id      = p_emp_id
       AND pay_month   = 1
       AND pay_year    = 2025;

    -- Compute payroll components
    SET v_gross_salary = v_new_salary;                           -- no unpaid leaves assumed at bonus time
    SET v_tax          = ROUND(calculate_tax(v_gross_salary), 2);-- reuse Phase 2 tax function
    SET v_net_salary   = ROUND(v_gross_salary - v_tax, 2);

    IF v_payroll_exists = 0 THEN
        -- Fresh insert for Jan 2025
        INSERT INTO Payroll (
            emp_id, pay_month, pay_year,
            gross_salary, unpaid_leave_deduction, tax_deduction,
            net_salary, payment_status
        ) VALUES (
            p_emp_id, 1, 2025,
            v_gross_salary, 0.00, v_tax,
            v_net_salary, 'PENDING'
        );
    ELSE
        -- Record already exists — update it to reflect the new salary
        UPDATE Payroll
           SET gross_salary           = v_gross_salary,
               unpaid_leave_deduction = 0.00,
               tax_deduction          = v_tax,
               net_salary             = v_net_salary,
               payment_status         = 'PENDING',
               processed_on           = CURRENT_TIMESTAMP
         WHERE emp_id    = p_emp_id
           AND pay_month = 1
           AND pay_year  = 2025;
    END IF;

    -- ── Step 5 : Verify net_salary > 0 (business-rule check) ─────────────────
    SELECT net_salary
      INTO v_net_salary
      FROM Payroll
     WHERE emp_id    = p_emp_id
       AND pay_month = 1
       AND pay_year  = 2025;

    IF v_net_salary <= 0 THEN
        -- This should never happen with valid data, but we guard against it
        ROLLBACK;
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Error: Net salary is zero or negative after payroll insert — transaction rolled back.';
    END IF;

    -- ── All steps passed — make changes permanent ─────────────────────────────
    COMMIT;

    -- ── Success summary ───────────────────────────────────────────────────────
    SELECT
        p_emp_id                            AS emp_id,
        v_current_salary                    AS salary_before,
        v_new_salary                        AS salary_after,
        CONCAT(p_bonus_pct, '%')            AS bonus_applied,
        v_gross_salary                      AS jan2025_gross,
        v_tax                               AS jan2025_tax_deduction,
        v_net_salary                        AS jan2025_net_salary,
        'COMMITTED'                         AS transaction_status;

END$$

DELIMITER ;

-- ============================================================================================================================
-- ██████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████
-- SECTION 3 : TEST CASES
-- ██████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████
-- ============================================================================================================================

/*
  ╔══════════════════════════════════════════════════════════════════════════════════════════════════════╗
  ║                               TEST CASE DOCUMENTATION TABLE                                        ║
  ╠════╦═══════════════════════════════════════╦════════════════════════════╦════════════════════════════╣
  ║ #  ║ Test Name                             ║ What is tested             ║ Expected Outcome           ║
  ╠════╬═══════════════════════════════════════╬════════════════════════════╬════════════════════════════╣
  ║ 1  ║ Valid Transaction Commit              ║ process_salary_bonus SP    ║ Salary +10 %, payroll      ║
  ║    ║                                       ║ ACID commit path           ║ inserted for Jan 2025      ║
  ╠════╬═══════════════════════════════════════╬════════════════════════════╬════════════════════════════╣
  ║ 2  ║ Negative Salary Violation             ║ CHECK (base_salary > 0)    ║ ERROR 3819 — Check         ║
  ║    ║                                       ║ constraint on Employee     ║ constraint violated        ║
  ╠════╬═══════════════════════════════════════╬════════════════════════════╬════════════════════════════╣
  ║ 3  ║ Duplicate Same-Day Attendance         ║ UNIQUE (emp_id, att_date)  ║ ERROR 1062 — Duplicate     ║
  ║    ║                                       ║ on Attendance table        ║ entry; INSERT IGNORE skips ║
  ╠════╬═══════════════════════════════════════╬════════════════════════════╬════════════════════════════╣
  ║ 4  ║ Overlapping Leave Trigger Block       ║ BEFORE INSERT trigger on   ║ SQLSTATE '45000' —         ║
  ║    ║                                       ║ Leave_Record               ║ Overlapping approved leave ║
  ╠════╬═══════════════════════════════════════╬════════════════════════════╬════════════════════════════╣
  ║ 5  ║ Unauthorized Write (employee_role)    ║ MySQL RBAC privilege check ║ ERROR 1142 — INSERT denied ║
  ║    ║                                       ║ for john_doe               ║ SHOW GRANTS confirms scope ║
  ╚════╩═══════════════════════════════════════╩════════════════════════════╩════════════════════════════╝
*/


-- ============================================================================================================================
-- TEST 1 : Valid Transaction Commit
-- ============================================================================================================================
/*
  ┌───────────────────────────────────────────────────────────────────────────┐
  │ TEST 1 — Valid Transaction Commit                                          │
  │ Objective : Confirm that process_salary_bonus correctly raises base_salary │
  │             by the requested percentage AND inserts/updates a payroll      │
  │             record for January 2025, all within one atomic transaction.    │
  │                                                                            │
  │ Pre-condition : emp_id = 1 exists in Employee.                             │
  │ Steps        : 1. Record salary before the call.                           │
  │                2. CALL process_salary_bonus(1, 10.00).                     │
  │                3. SELECT salary after the call.                            │
  │                4. Verify Payroll row for Jan 2025 exists.                  │
  │                                                                            │
  │ Expected Result :                                                          │
  │   • base_salary after = base_salary before * 1.10                         │
  │   • Payroll row (emp_id=1, pay_month=1, pay_year=2025) present            │
  │   • net_salary > 0                                                         │
  │   • transaction_status column = 'COMMITTED'                               │
  └───────────────────────────────────────────────────────────────────────────┘
*/

-- Step 1 : Snapshot salary BEFORE the bonus
SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS employee_name,
    base_salary                         AS salary_before_bonus
FROM Employee
WHERE emp_id = 1;

-- Step 2 : Apply 10% performance bonus (wraps a full ACID transaction internally)
CALL process_salary_bonus(1, 10.00);

-- Step 3 : Confirm salary AFTER the bonus
SELECT
    emp_id,
    CONCAT(first_name, ' ', last_name) AS employee_name,
    base_salary                         AS salary_after_bonus
FROM Employee
WHERE emp_id = 1;

-- Step 4 : Confirm payroll record for January 2025
SELECT
    pay_id,
    emp_id,
    pay_month,
    pay_year,
    gross_salary,
    tax_deduction,
    net_salary,
    payment_status
FROM Payroll
WHERE emp_id = 1
  AND pay_month = 1
  AND pay_year  = 2025;

/*
  ✔  PASS criteria :
     salary_after_bonus  = salary_before_bonus × 1.10
     Payroll row exists  AND  net_salary > 0
*/


-- ============================================================================================================================
-- TEST 2 : Negative Salary Violation — CHECK Constraint
-- ============================================================================================================================
/*
  ┌───────────────────────────────────────────────────────────────────────────┐
  │ TEST 2 — Negative Salary Violation (CHECK Constraint)                     │
  │ Objective : Confirm that MySQL enforces the CHECK (base_salary > 0)       │
  │             constraint defined on the Employee table (Phase 1 DDL).       │
  │                                                                            │
  │ Pre-condition : emp_id = 2 exists.                                        │
  │ Steps        : Attempt to set base_salary to a negative value.            │
  │                                                                            │
  │ Expected Result :                                                          │
  │   ERROR 3819 (HY000): Check constraint 'employee_chk_1' is violated.      │
  │   (The exact constraint name may vary; the SQLSTATE is HY000.)            │
  │   The UPDATE must be rejected; original salary must remain unchanged.     │
  └───────────────────────────────────────────────────────────────────────────┘
*/

-- Record salary before the failed attempt
SELECT emp_id, base_salary AS salary_before FROM Employee WHERE emp_id = 2;

-- !! This statement WILL raise an error — that is the expected behaviour !!
-- Expected: ERROR 3819 (HY000): Check constraint 'Employee_chk_1' is violated.
UPDATE Employee
   SET base_salary = -5000
 WHERE emp_id = 2;

-- Confirm salary is UNCHANGED (only reached if running in a tool that continues after errors)
SELECT emp_id, base_salary AS salary_after_failed_update FROM Employee WHERE emp_id = 2;

/*
  ✔  PASS criteria :
     UPDATE raises ERROR 3819 (or similar CHECK violation error).
     base_salary for emp_id = 2 remains at its original positive value.
*/


-- ============================================================================================================================
-- TEST 3 : Duplicate Same-Day Attendance — UNIQUE Constraint
-- ============================================================================================================================
/*
  ┌───────────────────────────────────────────────────────────────────────────┐
  │ TEST 3 — Duplicate Same-Day Attendance (UNIQUE Constraint)                │
  │ Objective : Confirm that UNIQUE(emp_id, att_date) prevents two attendance │
  │             entries for the same employee on the same date, and that       │
  │             INSERT IGNORE silently discards the duplicate.                 │
  │                                                                            │
  │ Pre-condition : emp_id = 5 must NOT already have an attendance record      │
  │                for '2025-01-15'.  Clean up below handles that.             │
  │                                                                            │
  │ Expected Result (Part A — regular INSERT) :                                │
  │   ERROR 1062 (23000): Duplicate entry '5-2025-01-15' for key              │
  │   'Attendance.emp_id_att_date_unique' (or similar key name).              │
  │                                                                            │
  │ Expected Result (Part B — INSERT IGNORE) :                                 │
  │   Query OK, 0 rows affected — duplicate silently skipped.                 │
  └───────────────────────────────────────────────────────────────────────────┘
*/

-- Clean slate for the test date
DELETE FROM Attendance WHERE emp_id = 5 AND att_date = '2025-01-15';

-- Part A : First insert — should SUCCEED
INSERT INTO Attendance (emp_id, att_date, check_in, check_out, status)
VALUES (5, '2025-01-15', '09:00:00', '18:00:00', 'PRESENT');

SELECT att_id, emp_id, att_date, status
FROM Attendance
WHERE emp_id = 5 AND att_date = '2025-01-15';

-- Part A : Second insert — SAME emp_id & att_date → should FAIL with ERROR 1062
-- Expected: ERROR 1062 (23000): Duplicate entry '5-2025-01-15' for key 'Attendance.emp_id'
INSERT INTO Attendance (emp_id, att_date, check_in, check_out, status)
VALUES (5, '2025-01-15', '09:05:00', '18:00:00', 'LATE');

-- Part B : Same duplicate with INSERT IGNORE — should produce 0 warnings and 0 new rows
INSERT IGNORE INTO Attendance (emp_id, att_date, check_in, check_out, status)
VALUES (5, '2025-01-15', '09:10:00', '18:00:00', 'LATE');

-- Verify only ONE row exists (the original PRESENT record)
SELECT att_id, emp_id, att_date, check_in, status
FROM Attendance
WHERE emp_id = 5 AND att_date = '2025-01-15';

/*
  ✔  PASS criteria :
     Regular INSERT → ERROR 1062.
     INSERT IGNORE  → 0 rows affected, no error.
     Final SELECT   → exactly 1 row with status = 'PRESENT'.
*/


-- ============================================================================================================================
-- TEST 4 : Overlapping Leave — Trigger Block
-- ============================================================================================================================
/*
  ┌───────────────────────────────────────────────────────────────────────────┐
  │ TEST 4 — Overlapping Leave (Trigger Block)                                │
  │ Objective : Confirm that the BEFORE INSERT trigger on Leave_Record        │
  │             (defined in Phase 2/3) prevents inserting a leave request     │
  │             whose date range overlaps an existing APPROVED leave for the  │
  │             same employee.                                                 │
  │                                                                            │
  │ Pre-condition : No APPROVED leave for emp_id = 3 overlapping              │
  │                '2024-10-15' – '2024-10-20'.                               │
  │                                                                            │
  │ Expected Result (Part A) : INSERT succeeds — first leave approved.        │
  │ Expected Result (Part B) : SIGNAL from trigger:                           │
  │   SQLSTATE '45000'                                                        │
  │   MESSAGE_TEXT = 'Error: Overlapping approved leave dates exist for       │
  │                   this employee.'                                          │
  └───────────────────────────────────────────────────────────────────────────┘
*/

-- Clean slate: remove any leaves for emp_id = 3 in the target range
DELETE FROM Leave_Record
 WHERE emp_id = 3
   AND start_date <= '2024-10-25'
   AND end_date   >= '2024-10-15';

-- Part A : Insert a valid APPROVED leave for emp_id = 3
-- Expected: INSERT succeeds, 1 row affected
INSERT INTO Leave_Record (emp_id, leave_type, start_date, end_date, reason, status)
VALUES (3, 'EARNED', '2024-10-15', '2024-10-20', 'Annual vacation', 'APPROVED');

-- Confirm it was inserted
SELECT leave_id, emp_id, leave_type, start_date, end_date, status
FROM Leave_Record
WHERE emp_id = 3 AND status = 'APPROVED'
  AND start_date = '2024-10-15';

-- Part B : Attempt an overlapping leave for the same employee
-- Date range '2024-10-18' – '2024-10-25' overlaps the APPROVED '2024-10-15' – '2024-10-20'
-- Expected: ERROR — trigger fires SIGNAL SQLSTATE '45000'
--           MESSAGE_TEXT: 'Error: Overlapping approved leave dates exist for this employee.'
INSERT INTO Leave_Record (emp_id, leave_type, start_date, end_date, reason, status)
VALUES (3, 'CASUAL', '2024-10-18', '2024-10-25', 'Extension of vacation', 'APPROVED');

/*
  ✔  PASS criteria :
     Part A INSERT  → 1 row affected, no error.
     Part B INSERT  → SQLSTATE 45000, trigger message about overlapping dates.
     Leave_Record for emp_id=3 contains only the original approved row.
*/


-- ============================================================================================================================
-- TEST 5 : Unauthorized Write Under employee_role
-- ============================================================================================================================
/*
  ┌───────────────────────────────────────────────────────────────────────────┐
  │ TEST 5 — Unauthorized Write Under employee_role (john_doe)                │
  │ Objective : Confirm that the user john_doe (assigned employee_role)       │
  │             cannot perform any INSERT/UPDATE/DELETE on base tables, and   │
  │             that SHOW GRANTS confirms the restricted privilege set.        │
  │                                                                            │
  │ Note      : MySQL scripts run as a single user; we cannot inline a user   │
  │             switch (SYSTEM/PROXY is not applicable here). The INSERT      │
  │             below is therefore annotated to show what would happen when   │
  │             executed in a session authenticated as john_doe. The          │
  │             SHOW GRANTS query CAN be run from any privileged session.     │
  │                                                                            │
  │ Expected Result :                                                          │
  │   INSERT → ERROR 1142 (42000): INSERT command denied to user              │
  │            'john_doe'@'localhost' on table 'Employee'                     │
  │   SHOW GRANTS → lists only SELECT on the two views, confirming that no    │
  │             write privilege exists.                                        │
  └───────────────────────────────────────────────────────────────────────────┘
*/

-- ── PART A : Privilege inspection (run as any admin / root session) ──────────
-- This confirms what john_doe is and is NOT allowed to do.
SHOW GRANTS FOR 'john_doe'@'localhost';

/*
  Expected output of SHOW GRANTS (approximate):
  ┌────────────────────────────────────────────────────────────────────────────────────┐
  │ Grants for john_doe@localhost                                                       │
  ├────────────────────────────────────────────────────────────────────────────────────┤
  │ GRANT USAGE ON *.* TO `john_doe`@`localhost`                                       │
  │ GRANT `employee_role` TO `john_doe`@`localhost`                                    │
  └────────────────────────────────────────────────────────────────────────────────────┘
  And via the role:
  GRANT SELECT ON autopay_track.vw_emp_attendance TO 'employee_role'@'%'
  GRANT SELECT ON autopay_track.vw_emp_payroll    TO 'employee_role'@'%'

  No INSERT / UPDATE / DELETE / EXECUTE / CREATE / DROP privileges exist.
*/

-- ── PART B : Simulated unauthorised INSERT (would be run as john_doe) ────────
-- To reproduce locally:
--   mysql -u john_doe -pJohnDoe@2024 autopay_track
--   INSERT INTO Employee (first_name) VALUES ('Hacker');
--
-- The statement below is commented out because this script runs as a privileged
-- user.  Uncomment and run only in a john_doe session to trigger the error.
--
-- INSERT INTO Employee (first_name) VALUES ('Hacker');
--
-- Expected error when executed as john_doe:
--   ERROR 1142 (42000): INSERT command denied to user 'john_doe'@'localhost'
--   on table 'Employee'

-- ── PART C : Confirm allowed operations — john_doe CAN select from views ──
-- (Also safe to run from the admin session as a quick sanity check)
SELECT * FROM vw_emp_attendance LIMIT 3;
SELECT * FROM vw_emp_payroll    LIMIT 3;

/*
  ✔  PASS criteria :
     SHOW GRANTS  → only employee_role, SELECT on two views.
     INSERT       → ERROR 1142 when executed as john_doe.
     SELECT views → returns rows without error (from admin session or john_doe).
*/


-- ============================================================================================================================
-- END OF PHASE 4
-- ============================================================================================================================
/*
  Summary of Phase 4 deliverables
  ────────────────────────────────
  ✔  Section 1 — RBAC
       • 2 security views    : vw_emp_attendance, vw_emp_payroll
       • 2 MySQL roles       : admin_hr_role (ALL), employee_role (SELECT on views)
       • 2 MySQL users       : hr_admin (admin_hr_role), john_doe (employee_role)
       • Access matrix       : documented in comment block above

  ✔  Section 2 — ACID Transaction (Stored Procedure)
       • process_salary_bonus(IN p_emp_id INT, IN p_bonus_pct DECIMAL(5,2))
       • Implements all 4 ACID properties:
           Atomicity   — EXIT HANDLER FOR SQLEXCEPTION → ROLLBACK
           Consistency — CHECK constraint + net_salary > 0 guard
           Isolation   — SELECT … FOR UPDATE row-level lock
           Durability  — explicit COMMIT to InnoDB redo log
       • 5-step transaction : validate → lock → update → insert payroll → verify

  ✔  Section 3 — Test Cases (5 tests)
       Test 1 — Valid commit          : process_salary_bonus succeeds, salary +10%
       Test 2 — CHECK constraint      : negative salary rejected (ERROR 3819)
       Test 3 — UNIQUE constraint     : duplicate attendance rejected (ERROR 1062);
                                        INSERT IGNORE handles gracefully
       Test 4 — Trigger overlap block : overlapping APPROVED leave rejected (SQLSTATE 45000)
       Test 5 — RBAC enforcement      : john_doe INSERT denied (ERROR 1142);
                                        SHOW GRANTS confirms view-only access
*/
