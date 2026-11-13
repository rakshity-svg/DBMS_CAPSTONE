#!/usr/bin/env python3
"""Generator for phase2_procedures_triggers_seed.sql"""

import datetime
import calendar

lines = []

def w(*args):
    lines.append(' '.join(str(a) for a in args))

# ============================================================
# HEADER
# ============================================================
w("""-- ============================================================
--  AutoPay & Track: Integrated Payroll & Attendance Management System
--  Phase 2 — Procedural Logic & Seed Data
-- ============================================================
--  Contents:
--    SECTION 1  : Stored Function  — calculate_tax()
--    SECTION 2  : Stored Procedure — generate_monthly_payroll()
--    SECTION 3  : Triggers         — before_leave_insert, before_attendance_insert
--    SECTION 4  : Seed Data        — Departments, Employees, Attendance,
--                                    Leave_Records, Payroll (via procedure call)
-- ============================================================

USE autopay_track;

-- Allow creation of functions with binary logging enabled
SET GLOBAL log_bin_trust_function_creators = 1;

DELIMITER $$

-- ============================================================
-- SECTION 1: STORED FUNCTION — calculate_tax(monthly_salary)
-- ============================================================
-- Implements Indian New Tax Regime slabs (annual):
--   Up to 3,00,000       : 0%
--   3,00,001 – 7,00,000  : 5%
--   7,00,001 – 10,00,000 : 10%
--  10,00,001 – 15,00,000 : 20%
--  Above 15,00,000       : 30%
-- Input  : monthly gross salary (DECIMAL 12,2)
-- Output : monthly tax amount   (DECIMAL 12,2)
-- ============================================================
DROP FUNCTION IF EXISTS calculate_tax$$

CREATE FUNCTION calculate_tax(salary DECIMAL(12,2))
RETURNS DECIMAL(12,2)
DETERMINISTIC
NO SQL
BEGIN
    DECLARE annual_salary  DECIMAL(14,2);
    DECLARE annual_tax     DECIMAL(14,2) DEFAULT 0.00;

    -- Annualise the monthly salary
    SET annual_salary = salary * 12;

    -- Tiered tax calculation
    IF annual_salary <= 300000 THEN
        SET annual_tax = 0.00;

    ELSEIF annual_salary <= 700000 THEN
        -- 5% on amount above 3,00,000
        SET annual_tax = (annual_salary - 300000) * 0.05;

    ELSEIF annual_salary <= 1000000 THEN
        -- Full 5% slab + 10% on amount above 7,00,000
        SET annual_tax = (400000 * 0.05)
                       + ((annual_salary - 700000) * 0.10);

    ELSEIF annual_salary <= 1500000 THEN
        -- Full 5% + 10% slabs + 20% on amount above 10,00,000
        SET annual_tax = (400000 * 0.05)
                       + (300000 * 0.10)
                       + ((annual_salary - 1000000) * 0.20);

    ELSE
        -- Full 5% + 10% + 20% slabs + 30% on amount above 15,00,000
        SET annual_tax = (400000 * 0.05)
                       + (300000 * 0.10)
                       + (500000 * 0.20)
                       + ((annual_salary - 1500000) * 0.30);
    END IF;

    -- Return the MONTHLY portion of the annual tax
    RETURN ROUND(annual_tax / 12, 2);
END$$


-- ============================================================
-- SECTION 2: STORED PROCEDURE — generate_monthly_payroll()
-- ============================================================
-- Generates payroll records for every active employee for the
-- specified month/year if no record already exists.
-- Uses 22 as the standard number of working days per month.
-- Deducts unpaid leave proportionally from base salary.
-- ============================================================
DROP PROCEDURE IF EXISTS generate_monthly_payroll$$

CREATE PROCEDURE generate_monthly_payroll(IN in_month INT, IN in_year INT)
BEGIN
    -- Cursor variables
    DECLARE v_emp_id          INT;
    DECLARE v_base_salary     DECIMAL(12,2);
    DECLARE v_done            INT DEFAULT 0;

    -- Working variables
    DECLARE v_existing        INT DEFAULT 0;
    DECLARE v_unpaid_days     INT DEFAULT 0;
    DECLARE v_unpaid_deduct   DECIMAL(12,2) DEFAULT 0.00;
    DECLARE v_gross_salary    DECIMAL(12,2) DEFAULT 0.00;
    DECLARE v_tax             DECIMAL(12,2) DEFAULT 0.00;
    DECLARE v_net_salary      DECIMAL(12,2) DEFAULT 0.00;

    -- Constant: standard working days per month
    DECLARE c_working_days    INT DEFAULT 22;

    -- First and last day of the target month (for leave overlap check)
    DECLARE v_month_start     DATE;
    DECLARE v_month_end       DATE;

    -- Cursor: iterate over all employees
    DECLARE emp_cursor CURSOR FOR
        SELECT emp_id, base_salary
        FROM   Employee;

    -- Exit handler for cursor exhaustion
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    -- Compute month boundaries
    SET v_month_start = STR_TO_DATE(CONCAT(in_year, '-', LPAD(in_month, 2, '0'), '-01'), '%Y-%m-%d');
    SET v_month_end   = LAST_DAY(v_month_start);

    OPEN emp_cursor;

    payroll_loop: LOOP
        FETCH emp_cursor INTO v_emp_id, v_base_salary;

        IF v_done = 1 THEN
            LEAVE payroll_loop;
        END IF;

        -- Skip if payroll already exists for this employee/month/year
        SELECT COUNT(*) INTO v_existing
        FROM   Payroll
        WHERE  emp_id    = v_emp_id
          AND  pay_month = in_month
          AND  pay_year  = in_year;

        IF v_existing > 0 THEN
            ITERATE payroll_loop;
        END IF;

        -- Count APPROVED UNPAID leave days that overlap with this month
        -- A leave overlaps if: leave.start_date <= month_end AND leave.end_date >= month_start
        SELECT COALESCE(
                   SUM(
                       DATEDIFF(
                           LEAST(end_date,   v_month_end),
                           GREATEST(start_date, v_month_start)
                       ) + 1
                   ), 0)
        INTO   v_unpaid_days
        FROM   Leave_Record
        WHERE  emp_id     = v_emp_id
          AND  leave_type = 'UNPAID'
          AND  status     = 'APPROVED'
          AND  start_date <= v_month_end
          AND  end_date   >= v_month_start;

        -- Cap unpaid days at the working days ceiling
        IF v_unpaid_days > c_working_days THEN
            SET v_unpaid_days = c_working_days;
        END IF;

        -- Compute payroll components
        SET v_unpaid_deduct = ROUND((v_base_salary / c_working_days) * v_unpaid_days, 2);
        SET v_gross_salary  = v_base_salary - v_unpaid_deduct;
        SET v_tax           = calculate_tax(v_gross_salary);
        SET v_net_salary    = v_gross_salary - v_tax;

        -- Insert payroll record
        INSERT INTO Payroll (
            emp_id, pay_month, pay_year,
            gross_salary, unpaid_leave_deduction, tax_deduction,
            net_salary, payment_status, processed_on
        ) VALUES (
            v_emp_id, in_month, in_year,
            v_gross_salary, v_unpaid_deduct, v_tax,
            v_net_salary, 'PROCESSED', NOW()
        );

    END LOOP payroll_loop;

    CLOSE emp_cursor;
END$$


-- ============================================================
-- SECTION 3: TRIGGERS
-- ============================================================

-- ------------------------------------------------------------
-- Trigger 1: before_leave_insert
-- Prevents inserting a Leave_Record whose dates overlap with
-- an existing APPROVED leave for the same employee.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS before_leave_insert$$

CREATE TRIGGER before_leave_insert
BEFORE INSERT ON Leave_Record
FOR EACH ROW
BEGIN
    DECLARE v_overlap_count INT DEFAULT 0;

    SELECT COUNT(*) INTO v_overlap_count
    FROM   Leave_Record
    WHERE  emp_id     = NEW.emp_id
      AND  status     = 'APPROVED'
      AND  start_date <= NEW.end_date
      AND  end_date   >= NEW.start_date;

    IF v_overlap_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Error: Overlapping approved leave dates exist for this employee.';
    END IF;
END$$


-- ------------------------------------------------------------
-- Trigger 2: before_attendance_insert
-- Auto-marks an employee LATE if they check in after 09:30
-- and the status is recorded as PRESENT.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS before_attendance_insert$$

CREATE TRIGGER before_attendance_insert
BEFORE INSERT ON Attendance
FOR EACH ROW
BEGIN
    IF NEW.check_in IS NOT NULL
       AND NEW.check_in > '09:30:00'
       AND NEW.status = 'PRESENT'
    THEN
        SET NEW.status = 'LATE';
    END IF;
END$$


DELIMITER ;


-- ============================================================
-- SECTION 4: SEED DATA
-- ============================================================

-- ------------------------------------------------------------
-- 4.1  Departments (3)
-- ------------------------------------------------------------
INSERT INTO Department (dept_id, dept_name, location, manager_id) VALUES
(1, 'Information Technology', 'Bengaluru', NULL),
(2, 'Human Resources',        'Mumbai',    NULL),
(3, 'Finance',                'Pune',      NULL);


-- ------------------------------------------------------------
-- 4.2  Employees (10) — salaries in INR/month (40,000–1,50,000)
-- ------------------------------------------------------------
INSERT INTO Employee
    (emp_id, first_name, last_name, email, phone, hire_date, job_title, base_salary, dept_id)
VALUES
-- IT Department (dept_id = 1)
(1,  'Arjun',    'Sharma',    'arjun.sharma@autopay.in',    '9876543210', '2021-03-15', 'Senior Software Engineer',    120000.00, 1),
(2,  'Priya',    'Nair',      'priya.nair@autopay.in',      '9876543211', '2022-06-01', 'Software Engineer',            75000.00, 1),
(3,  'Rahul',    'Verma',     'rahul.verma@autopay.in',     '9876543212', '2020-11-20', 'Lead Developer',              150000.00, 1),
(4,  'Sneha',    'Iyer',      'sneha.iyer@autopay.in',      '9876543213', '2023-01-10', 'Junior Developer',             45000.00, 1),
-- HR Department (dept_id = 2)
(5,  'Kavita',   'Desai',     'kavita.desai@autopay.in',    '9876543214', '2019-07-22', 'HR Manager',                   95000.00, 2),
(6,  'Rohit',    'Kulkarni',  'rohit.kulkarni@autopay.in',  '9876543215', '2021-09-05', 'HR Executive',                 55000.00, 2),
(7,  'Ananya',   'Pillai',    'ananya.pillai@autopay.in',   '9876543216', '2022-04-18', 'Recruitment Specialist',       62000.00, 2),
-- Finance Department (dept_id = 3)
(8,  'Vikram',   'Mehta',     'vikram.mehta@autopay.in',    '9876543217', '2018-05-30', 'Finance Manager',             110000.00, 3),
(9,  'Deepika',  'Joshi',     'deepika.joshi@autopay.in',   '9876543218', '2023-03-01', 'Accountant',                   48000.00, 3),
(10, 'Suresh',   'Reddy',     'suresh.reddy@autopay.in',    '9876543219', '2020-08-12', 'Senior Accountant',            80000.00, 3);


-- Set department managers
UPDATE Department SET manager_id = 3 WHERE dept_id = 1;  -- Rahul Verma leads IT
UPDATE Department SET manager_id = 5 WHERE dept_id = 2;  -- Kavita Desai leads HR
UPDATE Department SET manager_id = 8 WHERE dept_id = 3;  -- Vikram Mehta leads Finance
""")

# ============================================================
# 4.3  Attendance — October, November, December 2024
# ============================================================
# Pattern (10-day repeating cycle) per employee:
#   P=PRESENT  09:00:00 in / 18:00:00 out
#   L=LATE     10:15:00 or 10:30:00 in / 18:30:00 out
#   A=ABSENT   NULL in / NULL out
#   H=HALF_DAY 09:00:00 in / 13:00:00 out

PATTERNS = {
    1:  list('PPLPPPAPH P'),  # emp 1
    2:  list('PLPPAPPH PL'),
    3:  list('LPPPHAAP PL'),
    4:  list('PPPLPHPP AP'),
    5:  list('PALPPPHP PL'),
    6:  list('LPPAPPLPH P'),
    7:  list('PPHDLPP AP P'),
    8:  list('PLPPP AH PLP'),
    9:  list('APPL PPPH PP'),
    10: list('PPL PH PPP AL'),
}

# Cleaner patterns as simple 10-char strings (no spaces)
PATTERNS = {
    1:  'PPLPPPAPHP',
    2:  'PLPPAPPHPL',
    3:  'LPPPHAAPLP',  # note A appears at index 6
    4:  'PPPLPHPPAP',
    5:  'PALPPPHPLP',
    6:  'LPPAPPYLHP',
    7:  'PPHPLPPAPP',
    8:  'PLPPPAHLPP',
    9:  'APPLPPPHLP',  # changed Y to L
    10: 'PPLPHPPPLA',
}

# Fix: replace any non-PLAH chars
def clean(p):
    result = []
    for c in p:
        if c in 'PLAH':
            result.append(c)
        else:
            result.append('P')
    return result

PATTERNS = {k: clean(v) for k,v in PATTERNS.items()}

CHECK_IN  = {'P': "'09:00:00'", 'L': None, 'A': 'NULL', 'H': "'09:00:00'"}
CHECK_OUT = {'P': "'18:00:00'", 'L': None, 'A': 'NULL', 'H': "'13:00:00'"}

LATE_TIMES = ["'10:15:00'", "'10:30:00'", "'10:45:00'", "'11:00:00'"]

def get_status_sql(s):
    return {'P': "'PRESENT'", 'L': "'LATE'", 'A': "'ABSENT'", 'H': "'HALF_DAY'"}[s]

months = [(2024,10),(2024,11),(2024,12)]

w("\n-- ------------------------------------------------------------")
w("-- 4.3  Attendance — October, November, December 2024")
w("--      ~660 rows; INSERT IGNORE skips any duplicates")
w("-- ------------------------------------------------------------")
w("INSERT IGNORE INTO Attendance (emp_id, att_date, check_in, check_out, status) VALUES")

rows = []
for y, m in months:
    total_days = calendar.monthrange(y, m)[1]
    weekdays = [datetime.date(y, m, d) for d in range(1, total_days+1)
                if datetime.date(y, m, d).weekday() < 5]
    for emp_id in range(1, 11):
        pat = PATTERNS[emp_id]
        for idx, day in enumerate(weekdays):
            s = pat[idx % len(pat)]
            ci = CHECK_IN[s]
            co = CHECK_OUT[s]
            if s == 'L':
                late_t = LATE_TIMES[(emp_id + idx) % len(LATE_TIMES)]
                ci = late_t
                co = "'18:30:00'"
            rows.append(f"({emp_id}, '{day}', {ci}, {co}, {get_status_sql(s)})")

# Write in chunks
CHUNK = 20
for i in range(0, len(rows), CHUNK):
    chunk = rows[i:i+CHUNK]
    is_last_chunk = (i + CHUNK >= len(rows))
    sep = ';' if is_last_chunk else ','
    w(',\n'.join(chunk) + sep)

w(f"\n-- Total attendance rows inserted: {len(rows)}")

# ============================================================
# 4.4  Leave Records (15+)
# ============================================================
w("""
-- ------------------------------------------------------------
-- 4.4  Leave Records (15 entries — mix of types & statuses)
--      Includes UNPAID leaves so payroll deductions are testable
-- ------------------------------------------------------------
INSERT INTO Leave_Record
    (emp_id, leave_type, start_date, end_date, reason, status, applied_on)
VALUES
-- Employee 1 (Arjun Sharma, IT)
(1,  'SICK',    '2024-10-07', '2024-10-08', 'High fever and flu',                            'APPROVED',  '2024-10-05 09:00:00'),
(1,  'EARNED',  '2024-12-23', '2024-12-24', 'Year-end personal trip',                        'APPROVED',  '2024-12-10 10:00:00'),
-- Employee 2 (Priya Nair, IT)
(2,  'CASUAL',  '2024-10-21', '2024-10-21', 'Personal errand',                               'APPROVED',  '2024-10-18 11:00:00'),
(2,  'UNPAID',  '2024-11-25', '2024-11-26', 'Extended personal leave — no paid leave left',  'APPROVED',  '2024-11-20 09:30:00'),
-- Employee 3 (Rahul Verma, IT)
(3,  'EARNED',  '2024-11-04', '2024-11-05', 'Family function',                               'APPROVED',  '2024-10-28 08:00:00'),
(3,  'SICK',    '2024-12-09', '2024-12-09', 'Migraine',                                      'APPROVED',  '2024-12-08 20:00:00'),
-- Employee 4 (Sneha Iyer, IT)
(4,  'CASUAL',  '2024-10-14', '2024-10-14', 'Bank work',                                     'PENDING',   '2024-10-11 09:00:00'),
(4,  'UNPAID',  '2024-12-02', '2024-12-03', 'Personal travel — unpaid',                      'APPROVED',  '2024-11-28 10:00:00'),
-- Employee 5 (Kavita Desai, HR)
(5,  'EARNED',  '2024-10-28', '2024-10-30', 'Vacation',                                      'APPROVED',  '2024-10-15 09:00:00'),
(5,  'SICK',    '2024-11-18', '2024-11-18', 'Severe cold',                                   'APPROVED',  '2024-11-17 22:00:00'),
-- Employee 6 (Rohit Kulkarni, HR)
(6,  'CASUAL',  '2024-11-11', '2024-11-11', 'Vehicle service',                               'REJECTED',  '2024-11-08 09:00:00'),
(6,  'UNPAID',  '2024-12-16', '2024-12-17', 'Personal — out of paid leaves',                 'APPROVED',  '2024-12-10 11:00:00'),
-- Employee 7 (Ananya Pillai, HR)
(7,  'SICK',    '2024-10-22', '2024-10-23', 'Viral infection',                               'APPROVED',  '2024-10-21 21:00:00'),
-- Employee 8 (Vikram Mehta, Finance)
(8,  'EARNED',  '2024-11-25', '2024-11-29', 'Annual family vacation',                        'APPROVED',  '2024-11-01 09:00:00'),
-- Employee 9 (Deepika Joshi, Finance)
(9,  'CASUAL',  '2024-12-19', '2024-12-19', 'Personal appointment',                          'PENDING',   '2024-12-16 09:00:00'),
-- Employee 10 (Suresh Reddy, Finance)
(10, 'UNPAID',  '2024-10-28', '2024-10-29', 'Extended leave — quota exhausted',              'APPROVED',  '2024-10-25 09:00:00'),
(10, 'SICK',    '2024-11-20', '2024-11-20', 'Back pain',                                     'APPROVED',  '2024-11-19 22:00:00');
""")

# ============================================================
# 4.5  Payroll — call the procedure 3 times
# ============================================================
w("""
-- ------------------------------------------------------------
-- 4.5  Generate Payroll for Oct, Nov, Dec 2024
--      The stored procedure handles all salary computations,
--      UNPAID deductions, and tax calculations automatically.
-- ------------------------------------------------------------
CALL generate_monthly_payroll(10, 2024);
CALL generate_monthly_payroll(11, 2024);
CALL generate_monthly_payroll(12, 2024);


-- ============================================================
-- END OF PHASE 2
-- ============================================================
-- Verification queries (run manually to confirm):
--
--   SELECT * FROM Department;
--   SELECT emp_id, CONCAT(first_name,' ',last_name) AS name,
--          base_salary, dept_id FROM Employee;
--   SELECT status, COUNT(*) FROM Attendance GROUP BY status;
--   SELECT leave_type, status, COUNT(*) FROM Leave_Record
--     GROUP BY leave_type, status;
--   SELECT emp_id, pay_month, pay_year, gross_salary,
--          unpaid_leave_deduction, tax_deduction, net_salary,
--          payment_status FROM Payroll ORDER BY emp_id, pay_year, pay_month;
-- ============================================================
""")

# Write out
output = '\n'.join(lines)
with open('/Users/rakshityadav/Desktop/DBMS CAPSTONE/phase2_procedures_triggers_seed.sql', 'w') as f:
    f.write(output)

print(f"Done. Lines written: {len(lines)}")
print(f"Attendance rows: {len(rows)}")
