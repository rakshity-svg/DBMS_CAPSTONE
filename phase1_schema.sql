-- =============================================================================
-- PROJECT:  AutoPay & Track: Integrated Payroll & Attendance Management System
-- PHASE:    Phase 1 — 3NF Data Modeling & DDL Schema
-- DATABASE: autopay_track
-- ENGINE:   InnoDB  |  CHARSET: utf8mb4  |  COLLATION: utf8mb4_unicode_ci
-- AUTHOR:   DBMS Capstone Team
-- DATE:     2024
-- =============================================================================
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PROJECT OVERVIEW
-- ─────────────────────────────────────────────────────────────────────────────
-- AutoPay & Track is a relational database system designed for a mid-sized
-- IT firm to automate and centralise two core HR workflows:
--
--   1. ATTENDANCE MANAGEMENT  — daily check-in/check-out tracking, leave
--      application and approval, and holiday/half-day recording.
--
--   2. PAYROLL MANAGEMENT     — monthly salary computation with gross pay,
--      leave deductions, tax deductions, and net-pay settlement tracking.
--
-- The schema is intentionally kept at five normalised tables so that all
-- queries remain straightforward JOINs rather than complex sub-selects, while
-- still eliminating every form of redundancy that the normal-form rules target.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- ENTITY–RELATIONSHIP SUMMARY
-- ─────────────────────────────────────────────────────────────────────────────
--
--   ┌─────────────┐        ┌──────────────┐       ┌──────────────┐
--   │  Department │ 1────N │   Employee   │ 1────N │  Attendance  │
--   │             │        │              │        │              │
--   │ dept_id (PK)│        │ emp_id  (PK) │        │ att_id  (PK) │
--   │ dept_name   │        │ first_name   │        │ emp_id  (FK) │
--   │ location    │        │ last_name    │        │ att_date     │
--   │ manager_id ◄├──┐     │ email        │        │ check_in     │
--   └─────────────┘  │     │ phone        │        │ check_out    │
--                    │     │ hire_date    │        │ status       │
--                    └─────┤ job_title    │        └──────────────┘
--   (self-ref via ALTER)   │ base_salary  │
--                          │ dept_id (FK) │        ┌──────────────┐
--                          └──────────────┘  1────N│ Leave_Record │
--                                 │                │              │
--                                 │                │ leave_id(PK) │
--                                 │                │ emp_id  (FK) │
--                                 │                │ leave_type   │
--                                 │                │ start_date   │
--                                 │                │ end_date     │
--                                 │                │ reason       │
--                                 │                │ status       │
--                                 │                │ applied_on   │
--                                 │                └──────────────┘
--                                 │
--                                 │                ┌──────────────┐
--                                 └──────────── 1─N│   Payroll    │
--                                                  │              │
--                                                  │ pay_id  (PK) │
--                                                  │ emp_id  (FK) │
--                                                  │ pay_month    │
--                                                  │ pay_year     │
--                                                  │ gross_salary │
--                                                  │ deductions…  │
--                                                  │ net_salary   │
--                                                  │ pay_status   │
--                                                  │ processed_on │
--                                                  └──────────────┘
--
-- ─────────────────────────────────────────────────────────────────────────────
-- 3NF NORMALIZATION RATIONALE  (per table)
-- ─────────────────────────────────────────────────────────────────────────────
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ TABLE: Department                                                       │
-- ├────────────┬────────────────────────────────────────────────────────────┤
-- │ 1NF        │ All attributes are atomic (single-valued). dept_name is a  │
-- │            │ simple string; location is a single-city value. No         │
-- │            │ repeating groups.                                           │
-- ├────────────┼────────────────────────────────────────────────────────────┤
-- │ 2NF        │ The PK is a single surrogate (dept_id), so there can be no │
-- │            │ partial dependency on a composite key. All non-key columns  │
-- │            │ (dept_name, location, manager_id) depend fully on dept_id. │
-- ├────────────┼────────────────────────────────────────────────────────────┤
-- │ 3NF        │ No transitive dependencies exist: location is a property   │
-- │            │ of the department, not of its manager, and manager_id is   │
-- │            │ merely a reference — no manager's personal data lives here.│
-- │            │ All attributes depend ONLY on the PK.                      │
-- └────────────┴────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ TABLE: Employee                                                         │
-- ├────────────┬────────────────────────────────────────────────────────────┤
-- │ 1NF        │ Each attribute holds exactly one value. Name is split into │
-- │            │ first_name / last_name to allow independent sorting and     │
-- │            │ filtering. No multi-valued or composite attributes.        │
-- ├────────────┼────────────────────────────────────────────────────────────┤
-- │ 2NF        │ Single-column PK (emp_id) means no partial dependency is   │
-- │            │ possible. Every column describes one employee.             │
-- ├────────────┼────────────────────────────────────────────────────────────┤
-- │ 3NF        │ dept_id is a FK, not dept_name — avoiding transitive       │
-- │            │ dependency (emp→dept_name→location). Department data lives │
-- │            │ in its own table. base_salary is an intrinsic property of  │
-- │            │ the employee contract, not derived from job_title, so no   │
-- │            │ transitive path exists (job_title is merely a label here). │
-- └────────────┴────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ TABLE: Attendance                                                       │
-- ├────────────┬────────────────────────────────────────────────────────────┤
-- │ 1NF        │ Each row represents one employee's attendance on one date. │
-- │            │ check_in and check_out are separate TIME columns (atomic). │
-- │            │ UNIQUE(emp_id, att_date) enforces one record per day.      │
-- ├────────────┼────────────────────────────────────────────────────────────┤
-- │ 2NF        │ Composite candidate key is (emp_id, att_date). check_in,   │
-- │            │ check_out, and status all depend on the FULL composite key │
-- │            │ — no partial dependency (e.g., status is not a property of │
-- │            │ emp_id alone, nor of att_date alone).                      │
-- ├────────────┼────────────────────────────────────────────────────────────┤
-- │ 3NF        │ No attribute is transitively derived: status is recorded   │
-- │            │ directly (not computed from check_in/check_out in the      │
-- │            │ schema layer, allowing manual overrides for holidays). No  │
-- │            │ non-key attribute determines another non-key attribute.    │
-- └────────────┴────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ TABLE: Leave_Record                                                     │
-- ├────────────┬────────────────────────────────────────────────────────────┤
-- │ 1NF        │ All columns are single-valued. leave_type and status are   │
-- │            │ ENUM — a controlled domain, still atomic. Reason is free   │
-- │            │ text (TEXT), which is a single attribute.                  │
-- ├────────────┼────────────────────────────────────────────────────────────┤
-- │ 2NF        │ Single surrogate PK (leave_id). Every attribute describes  │
-- │            │ exactly one leave application — no partial dependency.     │
-- ├────────────┼────────────────────────────────────────────────────────────┤
-- │ 3NF        │ emp_id is a FK (not employee name or department). No       │
-- │            │ attribute depends on another non-key attribute. The status │
-- │            │ of the leave is stored here (not in Employee), eliminating │
-- │            │ any transitive path through the employee record.           │
-- └────────────┴────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ TABLE: Payroll                                                          │
-- ├────────────┬────────────────────────────────────────────────────────────┤
-- │ 1NF        │ Each row is one payslip for one employee for one calendar  │
-- │            │ month. All monetary values are separate DECIMAL columns.   │
-- │            │ UNIQUE(emp_id, pay_month, pay_year) prevents duplicates.   │
-- ├────────────┼────────────────────────────────────────────────────────────┤
-- │ 2NF        │ Composite candidate key is (emp_id, pay_month, pay_year).  │
-- │            │ gross_salary, deductions, net_salary, and payment_status   │
-- │            │ all depend on the FULL composite key — not on emp_id alone │
-- │            │ or the period alone.                                        │
-- ├────────────┼────────────────────────────────────────────────────────────┤
-- │ 3NF        │ gross_salary is stored (not re-derived from Employee.      │
-- │            │ base_salary at query time) so historical payslips remain   │
-- │            │ accurate even after a salary change — this is a valid      │
-- │            │ design choice, not a 3NF violation (it is a fact about the │
-- │            │ payroll event, not a property of the employee).            │
-- │            │ net_salary = gross - deductions is a derived value stored  │
-- │            │ for audit integrity; this is acceptable in payroll systems │
-- │            │ where the computed value itself is a legal record.         │
-- │            │ No non-key column determines another non-key column.       │
-- └────────────┴────────────────────────────────────────────────────────────┘
--
-- =============================================================================


-- =============================================================================
-- DATABASE SETUP
-- =============================================================================

-- Drop and recreate the database for a clean slate (development / migration).
-- Remove the DROP line in production if the schema already exists.
DROP DATABASE IF EXISTS autopay_track;

CREATE DATABASE autopay_track
    CHARACTER SET  utf8mb4          -- Full Unicode, including emoji & multi-byte
    COLLATE        utf8mb4_unicode_ci; -- Case-insensitive, accent-sensitive collation

USE autopay_track;


-- =============================================================================
-- TABLE 1: Department
-- =============================================================================
-- Stores organisational departments within the IT firm.
-- manager_id (FK → Employee) is added via ALTER TABLE after Employee is created
-- because of the circular dependency: Department references Employee and
-- Employee references Department (dept_id). The two-step approach breaks the
-- chicken-and-egg problem without using NULLABLE forward references in DDL.
-- =============================================================================

CREATE TABLE Department (
    -- Surrogate primary key; auto-incremented by InnoDB for insert performance.
    dept_id    INT             NOT NULL AUTO_INCREMENT,

    -- Human-readable department name; UNIQUE enforces no duplicate departments.
    -- NOT NULL because a department without a name is meaningless.
    dept_name  VARCHAR(100)    NOT NULL,

    -- Physical or virtual office location of the department. Nullable because
    -- remote-only departments may not have a fixed location.
    location   VARCHAR(150)    NULL,

    -- FK to Employee.emp_id — identifies the department head.
    -- Added via ALTER TABLE below; declared here as NULL to allow the column
    -- to exist before the referenced Employee table is created.
    manager_id INT             NULL,   -- FK added after Employee table creation

    -- -------------------------------------------------------------------------
    CONSTRAINT pk_department PRIMARY KEY (dept_id),

    -- Unique constraint on dept_name prevents accidental duplicates like
    -- "Engineering" and "engineering" (collation handles case-insensitivity).
    CONSTRAINT uq_department_name UNIQUE (dept_name)

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Organisational departments; manager FK added post-Employee creation';


-- =============================================================================
-- TABLE 2: Employee
-- =============================================================================
-- Core entity of the system. Every attendance record, leave request, and
-- payslip is anchored to an employee row via emp_id.
-- dept_id FK uses ON DELETE RESTRICT: an employee cannot be orphaned by
-- deleting their department; the department must be reassigned first.
-- =============================================================================

CREATE TABLE Employee (
    -- Surrogate PK. INT UNSIGNED would give a larger range, but plain INT is
    -- sufficient for a mid-sized firm and simplifies FK declarations.
    emp_id       INT              NOT NULL AUTO_INCREMENT,

    -- Name split into two columns for flexible sorting, searching, and display.
    first_name   VARCHAR(60)      NOT NULL,
    last_name    VARCHAR(60)      NOT NULL,

    -- Business-unique identifier; used for login and communication.
    -- UNIQUE index automatically created by MySQL on UNIQUE columns.
    email        VARCHAR(254)     NOT NULL,  -- 254 is the RFC 5321 max length

    -- Optional contact number; stored as VARCHAR to preserve leading zeros
    -- and international prefixes (e.g., +91-9876543210).
    phone        VARCHAR(20)      NULL,

    -- Date on which the employee joined; used for tenure calculations.
    hire_date    DATE             NOT NULL,

    -- Free-form job title label (e.g., "Senior Software Engineer").
    -- Not normalised into a separate table because titles are firm-specific
    -- strings that change independently per employee, not a controlled list.
    job_title    VARCHAR(100)     NOT NULL,

    -- Agreed monthly base salary. DECIMAL(12,2) supports values up to
    -- 9,999,999,999.99 — ample for any realistic salary.
    -- CHECK constraint ensures salary is always positive (MySQL 8.0.16+).
    base_salary  DECIMAL(12, 2)  NOT NULL
                 CONSTRAINT chk_emp_salary CHECK (base_salary > 0),

    -- FK to Department. ON DELETE RESTRICT prevents deleting a department
    -- that still has employees — HR must reassign them first.
    dept_id      INT              NOT NULL,

    -- -------------------------------------------------------------------------
    CONSTRAINT pk_employee        PRIMARY KEY (emp_id),
    CONSTRAINT uq_employee_email  UNIQUE      (email),

    -- Index on dept_id speeds up JOINs with Department.
    CONSTRAINT fk_employee_dept
        FOREIGN KEY (dept_id)
        REFERENCES  Department (dept_id)
        ON DELETE   RESTRICT     -- Block department deletion while employees exist
        ON UPDATE   CASCADE      -- Propagate dept_id changes (rare with surrogates)

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Core employee master table; anchors all attendance and payroll records';


-- =============================================================================
-- ALTER TABLE: Add manager_id FK on Department → Employee
-- =============================================================================
-- Now that Employee exists, we can add the foreign key for manager_id.
-- ON DELETE SET NULL: if the manager employee row is deleted, the department
-- is left without a manager (NULL) rather than cascading the deletion of the
-- entire department — a business-safe choice.
-- ON UPDATE CASCADE: if the manager's emp_id changes (edge case with surrogates),
-- the reference is updated automatically.
-- =============================================================================

ALTER TABLE Department
    ADD CONSTRAINT fk_department_manager
        FOREIGN KEY (manager_id)
        REFERENCES  Employee (emp_id)
        ON DELETE   SET NULL   -- Department stays; manager slot becomes vacant
        ON UPDATE   CASCADE;


-- =============================================================================
-- TABLE 3: Attendance
-- =============================================================================
-- Records daily attendance events for each employee.
-- One row per (employee, date) pair enforced by the UNIQUE composite constraint,
-- preventing duplicate entries for the same employee on the same day.
-- ON DELETE CASCADE: when an employee is removed, their attendance history
-- is also removed to avoid orphaned records.
-- =============================================================================

CREATE TABLE Attendance (
    -- Surrogate PK for fast indexed lookups and FK references in future tables.
    att_id      INT         NOT NULL AUTO_INCREMENT,

    -- References the employee whose attendance is being recorded.
    emp_id      INT         NOT NULL,

    -- The calendar date of attendance. Stored as DATE (not DATETIME) because
    -- the business domain treats attendance in whole-day units.
    att_date    DATE        NOT NULL,

    -- Exact time the employee clocked in. NULL when status is ABSENT/HOLIDAY.
    check_in    TIME        NULL,

    -- Exact time the employee clocked out. NULL when status is ABSENT/HOLIDAY
    -- or when the employee has checked in but not yet out.
    check_out   TIME        NULL,

    -- Attendance classification for the day.
    -- PRESENT   — full workday completed
    -- ABSENT    — no show without an approved leave
    -- LATE      — arrived after the official start time
    -- HALF_DAY  — worked approximately half the standard shift
    -- HOLIDAY   — company-declared holiday; no attendance expected
    status      ENUM('PRESENT', 'ABSENT', 'LATE', 'HALF_DAY', 'HOLIDAY')
                NOT NULL,

    -- -------------------------------------------------------------------------
    CONSTRAINT pk_attendance PRIMARY KEY (att_id),

    -- Composite unique constraint: one attendance record per employee per day.
    CONSTRAINT uq_attendance_emp_date UNIQUE (emp_id, att_date),

    -- Cascading delete: removing an employee also removes their attendance log.
    CONSTRAINT fk_attendance_emp
        FOREIGN KEY (emp_id)
        REFERENCES  Employee (emp_id)
        ON DELETE   CASCADE    -- Attendance is meaningless without the employee
        ON UPDATE   CASCADE

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Daily attendance log; one row per employee per calendar date';


-- =============================================================================
-- TABLE 4: Leave_Record
-- =============================================================================
-- Tracks leave applications submitted by employees, their type, duration,
-- and approval workflow status.
-- ON DELETE CASCADE: employee deletion removes their leave history along with
-- attendance — a consistent data-lifecycle policy for departed employees.
-- =============================================================================

CREATE TABLE Leave_Record (
    -- Surrogate PK for each leave application.
    leave_id    INT         NOT NULL AUTO_INCREMENT,

    -- The employee submitting the leave request.
    emp_id      INT         NOT NULL,

    -- Category of leave:
    -- SICK    — medical / health-related absence
    -- CASUAL  — short personal errands (typically limited per year)
    -- EARNED  — accrued paid leave
    -- UNPAID  — leave without pay (triggers deduction in Payroll)
    leave_type  ENUM('SICK', 'CASUAL', 'EARNED', 'UNPAID')
                NOT NULL,

    -- Inclusive start and end dates of the leave period.
    -- end_date must be >= start_date — enforced at application layer.
    start_date  DATE        NOT NULL,
    end_date    DATE        NOT NULL,

    -- Optional free-text reason provided by the employee.
    reason      TEXT        NULL,

    -- Workflow status of the leave application.
    -- PENDING  — awaiting HR / manager review (default on submission)
    -- APPROVED — leave sanctioned; Payroll will apply UNPAID deduction if needed
    -- REJECTED — leave denied; employee must report to work
    status      ENUM('PENDING', 'APPROVED', 'REJECTED')
                NOT NULL
                DEFAULT 'PENDING',

    -- Automatic timestamp recording when the application was submitted.
    -- DEFAULT CURRENT_TIMESTAMP removes the need for application-layer timestamping.
    applied_on  TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- -------------------------------------------------------------------------
    CONSTRAINT pk_leave_record PRIMARY KEY (leave_id),

    CONSTRAINT fk_leave_emp
        FOREIGN KEY (emp_id)
        REFERENCES  Employee (emp_id)
        ON DELETE   CASCADE    -- Leave records are intrinsically tied to the employee
        ON UPDATE   CASCADE

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Employee leave applications and their HR approval workflow status';


-- =============================================================================
-- TABLE 5: Payroll
-- =============================================================================
-- Stores one payslip record per employee per calendar month.
-- Monetary values are stored (not re-computed at query time) to preserve
-- a legally auditable record even if the employee's base_salary is later revised.
-- ON DELETE CASCADE: departing employee's payroll history is removed with them,
-- consistent with the data-lifecycle policy applied to Attendance and Leave_Record.
-- =============================================================================

CREATE TABLE Payroll (
    -- Surrogate PK for the payslip record.
    pay_id                   INT              NOT NULL AUTO_INCREMENT,

    -- Employee to whom this payslip belongs.
    emp_id                   INT              NOT NULL,

    -- Calendar month (1 = January … 12 = December).
    -- CHECK constraint enforces valid month range (MySQL 8.0.16+).
    pay_month                INT              NOT NULL
                             CONSTRAINT chk_payroll_month
                             CHECK (pay_month BETWEEN 1 AND 12),

    -- Four-digit calendar year. CHECK prevents absurd historical dates.
    pay_year                 INT              NOT NULL
                             CONSTRAINT chk_payroll_year
                             CHECK (pay_year > 2000),

    -- Gross pay before any deductions; typically sourced from base_salary
    -- at the time of processing plus any bonuses/allowances.
    gross_salary             DECIMAL(12, 2)  NOT NULL,

    -- Monetary deduction for UNPAID leave days taken during the pay period.
    -- Defaults to 0 when no unpaid leave was taken.
    unpaid_leave_deduction   DECIMAL(12, 2)  NOT NULL DEFAULT 0.00,

    -- Income tax or TDS deduction applicable for the pay period.
    -- Defaults to 0; actual value computed by the payroll processing engine.
    tax_deduction            DECIMAL(12, 2)  NOT NULL DEFAULT 0.00,

    -- Stored net pay = gross_salary − unpaid_leave_deduction − tax_deduction.
    -- Stored (not generated/virtual) so the payslip is a self-contained record
    -- that remains accurate regardless of future deduction rule changes.
    net_salary               DECIMAL(12, 2)  NOT NULL,

    -- Processing workflow status:
    -- PENDING   — payroll run initiated but not yet disbursed
    -- PROCESSED — payment successfully transferred to employee account
    -- FAILED    — disbursement attempt failed (bank error, account issue, etc.)
    payment_status           ENUM('PENDING', 'PROCESSED', 'FAILED')
                             NOT NULL
                             DEFAULT 'PENDING',

    -- Timestamp when the payroll record was created / last processed.
    processed_on             TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- -------------------------------------------------------------------------
    CONSTRAINT pk_payroll PRIMARY KEY (pay_id),

    -- Composite unique constraint: exactly one payslip per employee per month-year.
    -- Prevents double-processing of payroll for the same period.
    CONSTRAINT uq_payroll_emp_period UNIQUE (emp_id, pay_month, pay_year),

    CONSTRAINT fk_payroll_emp
        FOREIGN KEY (emp_id)
        REFERENCES  Employee (emp_id)
        ON DELETE   CASCADE    -- Remove payroll history when employee is deleted
        ON UPDATE   CASCADE

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Monthly payslip records; stores gross pay, deductions, and net pay per employee';


-- =============================================================================
-- SCHEMA SUMMARY
-- =============================================================================
--
--  Table           Rows / Purpose                         Key Constraints
--  ─────────────── ────────────────────────────────────── ───────────────────────────
--  Department      Organisational units of the firm        PK, UQ(dept_name), FK→Emp
--  Employee        Employee master record                  PK, UQ(email), FK→Dept
--  Attendance      Daily clock-in/out per employee         PK, UQ(emp_id,att_date)
--  Leave_Record    Leave applications & approvals          PK, FK→Emp CASCADE
--  Payroll         Monthly payslip & payment status        PK, UQ(emp,month,year)
--
--  Foreign Key policy:
--    Employee  → Department  : ON DELETE RESTRICT  (protect active dept)
--    Department→ Employee    : ON DELETE SET NULL  (manager slot vacated)
--    Attendance→ Employee    : ON DELETE CASCADE   (log removed with emp)
--    Leave_Record→Employee   : ON DELETE CASCADE   (record removed with emp)
--    Payroll   → Employee    : ON DELETE CASCADE   (payslip removed with emp)
--
-- =============================================================================
-- END OF PHASE 1 — phase1_schema.sql
-- =============================================================================
