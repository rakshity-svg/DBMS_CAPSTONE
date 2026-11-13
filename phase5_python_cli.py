#!/usr/bin/env python3
"""
================================================================================
  AutoPay & Track: Integrated Payroll & Attendance Management System
  Phase 5 — Python CLI Interface
================================================================================

PREREQUISITES:
    pip install mysql-connector-python

USAGE:
    python phase5_python_cli.py

CREDENTIALS (demo):
    HR Admin   : username=hr_admin,  password=HrAdmin@2024
    Employee   : username=john_doe,  password=JohnDoe@2024

DESCRIPTION:
    Role-based CLI that connects to the autopay_track MySQL database.
    - hr_admin  → Full HR menu (add employees, payroll, reports)
    - john_doe  → Employee self-service (attendance, payslip, leaves)
================================================================================
"""

import os
import sys
import getpass
import datetime

try:
    import mysql.connector
    from mysql.connector import Error as MySQLError
except ImportError:
    print("ERROR: mysql-connector-python is not installed.")
    print("Run:   pip install mysql-connector-python")
    sys.exit(1)


# ==============================================================================
# SECTION 1: CONFIGURATION
# ==============================================================================

# Base DB config (host/database only; credentials are supplied at runtime)
DB_CONFIG = {
    "host": "localhost",
    "database": "autopay_track",
    "autocommit": False,
    "connection_timeout": 10,
}

# Known MySQL user accounts (username → MySQL login)
# In production these would not be hard-coded; they are here for demo clarity.
KNOWN_USERS = {
    "hr_admin": "hr_admin",   # maps CLI username → MySQL user
    "john_doe": "john_doe",
}

# Employee username → emp_id mapping for the demo
# (In production, derive from Employee.email or a users table)
USERNAME_TO_EMP_ID = {
    "john_doe": 1,
}


# ==============================================================================
# SECTION 2: CONNECTION HELPER
# ==============================================================================

def get_connection(username: str, password: str):
    """
    Open and return a mysql.connector connection for the given credentials.
    Returns the connection object on success, or raises MySQLError on failure.
    """
    config = {**DB_CONFIG, "user": username, "password": password}
    conn = mysql.connector.connect(**config)
    return conn


# ==============================================================================
# SECTION 3: UTILITY FUNCTIONS
# ==============================================================================

def clear_screen():
    """Clear the terminal screen (cross-platform)."""
    os.system("cls" if os.name == "nt" else "clear")


def validate_date(date_str: str) -> bool:
    """
    Validate that date_str is in YYYY-MM-DD format and represents a real date.
    Returns True if valid, False otherwise.
    """
    try:
        datetime.datetime.strptime(date_str, "%Y-%m-%d")
        return True
    except ValueError:
        return False


def validate_month_year(month: int, year: int) -> bool:
    """Return True if month is 1-12 and year is reasonable (2000-2100)."""
    return 1 <= month <= 12 and 2000 <= year <= 2100


def prompt_month_year() -> tuple:
    """
    Interactively prompt the user for a month and year.
    Returns (month: int, year: int) or (None, None) on invalid input.
    """
    try:
        month = int(input("  Enter Month (1-12)  : ").strip())
        year  = int(input("  Enter Year (e.g. 2024): ").strip())
    except ValueError:
        print("  [!] Month and Year must be integers.")
        return None, None

    if not validate_month_year(month, year):
        print("  [!] Invalid month or year.")
        return None, None
    return month, year


def print_table(headers: list, rows: list):
    """
    Pretty-print a 2-D dataset as an ASCII table with auto-sized columns.

    Args:
        headers : list of column header strings
        rows    : list of tuples/lists — each is one data row
    """
    if not rows:
        print("  (no records found)\n")
        return

    # Convert every cell to string so we can measure widths
    str_rows = [[str(cell) if cell is not None else "NULL" for cell in row]
                for row in rows]

    # Determine column widths (max of header width and each data cell)
    col_widths = [len(h) for h in headers]
    for row in str_rows:
        for i, cell in enumerate(row):
            col_widths[i] = max(col_widths[i], len(cell))

    # Build format/separator strings
    sep   = "+-" + "-+-".join("-" * w for w in col_widths) + "-+"
    fmt   = "| " + " | ".join(f"{{:<{w}}}" for w in col_widths) + " |"

    print(sep)
    print(fmt.format(*headers))
    print(sep)
    for row in str_rows:
        print(fmt.format(*row))
    print(sep)
    print()


def print_banner():
    """Print the application banner."""
    clear_screen()
    print("=" * 60)
    print("   AutoPay & Track — Payroll & Attendance Management")
    print("=" * 60)
    print()


# ==============================================================================
# SECTION 4: HR ADMIN MENU ACTIONS
# ==============================================================================

def hr_add_employee(conn):
    """Prompt for new employee data, validate, and INSERT into Employee."""
    print("\n--- Add New Employee ---")
    try:
        first_name  = input("  First Name   : ").strip()
        last_name   = input("  Last Name    : ").strip()
        email       = input("  Email        : ").strip()
        phone       = input("  Phone        : ").strip()
        hire_date   = input("  Hire Date (YYYY-MM-DD): ").strip()
        job_title   = input("  Job Title    : ").strip()
        base_salary = input("  Base Salary  : ").strip()
        dept_id     = input("  Dept ID      : ").strip()
    except (EOFError, KeyboardInterrupt):
        print("\n  [!] Input cancelled.")
        return

    # --- Validation ---
    if not validate_date(hire_date):
        print("  [!] Invalid hire_date — must be YYYY-MM-DD.")
        return
    try:
        base_salary = float(base_salary)
        dept_id     = int(dept_id)
    except ValueError:
        print("  [!] base_salary must be a number and dept_id must be an integer.")
        return
    if base_salary <= 0:
        print("  [!] base_salary must be greater than 0.")
        return

    # --- INSERT ---
    sql = """
        INSERT INTO Employee
            (first_name, last_name, email, phone, hire_date,
             job_title, base_salary, dept_id)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
    """
    try:
        cursor = conn.cursor()
        cursor.execute(sql, (first_name, last_name, email, phone, hire_date,
                             job_title, base_salary, dept_id))
        conn.commit()
        new_id = cursor.lastrowid
        print(f"\n  [✓] Employee added successfully! New emp_id = {new_id}\n")
        cursor.close()
    except MySQLError as err:
        conn.rollback()
        print(f"\n  [MySQL Error] {err}\n")


def hr_generate_payroll(conn):
    """Call generate_monthly_payroll stored procedure and show a summary."""
    print("\n--- Generate Monthly Payroll ---")
    month, year = prompt_month_year()
    if month is None:
        return

    try:
        cursor = conn.cursor()
        # Call the stored procedure
        cursor.callproc("generate_monthly_payroll", (month, year))
        conn.commit()
        print(f"\n  [✓] Payroll generated successfully for {month:02d}/{year}\n")

        # Show summary: count records for this period
        cursor.execute(
            "SELECT COUNT(*) FROM Payroll WHERE pay_month=%s AND pay_year=%s",
            (month, year)
        )
        (count,) = cursor.fetchone()
        print(f"  Total payroll records for {month:02d}/{year}: {count}\n")
        cursor.close()
    except MySQLError as err:
        conn.rollback()
        print(f"\n  [MySQL Error] {err}\n")


def hr_attendance_report(conn):
    """Print monthly attendance summary for all employees."""
    print("\n--- Monthly Attendance Report ---")
    month, year = prompt_month_year()
    if month is None:
        return

    sql = """
        SELECT
            e.emp_id,
            CONCAT(e.first_name, ' ', e.last_name)                      AS name,
            SUM(CASE WHEN a.status = 'PRESENT'  THEN 1 ELSE 0 END)      AS present,
            SUM(CASE WHEN a.status = 'LATE'     THEN 1 ELSE 0 END)      AS late,
            SUM(CASE WHEN a.status = 'ABSENT'   THEN 1 ELSE 0 END)      AS absent,
            SUM(CASE WHEN a.status = 'HALF_DAY' THEN 1 ELSE 0 END)      AS half_day
        FROM Employee e
        LEFT JOIN Attendance a
            ON e.emp_id = a.emp_id
           AND MONTH(a.att_date) = %s
           AND YEAR(a.att_date)  = %s
        GROUP BY e.emp_id, e.first_name, e.last_name
        ORDER BY e.emp_id
    """
    try:
        cursor = conn.cursor()
        cursor.execute(sql, (month, year))
        rows = cursor.fetchall()
        cursor.close()
        print(f"\n  Attendance Report — {month:02d}/{year}\n")
        headers = ["EmpID", "Name", "Present", "Late", "Absent", "Half Day"]
        print_table(headers, rows)
    except MySQLError as err:
        print(f"\n  [MySQL Error] {err}\n")


def hr_view_employees(conn):
    """Print a formatted list of all employees with department info."""
    print("\n--- All Employees ---\n")
    sql = """
        SELECT
            e.emp_id,
            CONCAT(e.first_name, ' ', e.last_name) AS full_name,
            e.job_title,
            d.dept_name,
            e.base_salary
        FROM Employee e
        JOIN Department d ON e.dept_id = d.dept_id
        ORDER BY e.emp_id
    """
    try:
        cursor = conn.cursor()
        cursor.execute(sql)
        rows = cursor.fetchall()
        cursor.close()
        headers = ["EmpID", "Full Name", "Job Title", "Department", "Base Salary"]
        print_table(headers, rows)
    except MySQLError as err:
        print(f"\n  [MySQL Error] {err}\n")


def hr_menu(conn):
    """Main HR Admin menu loop."""
    while True:
        print("=" * 50)
        print("  HR ADMIN MENU")
        print("=" * 50)
        print("  1. Add New Employee")
        print("  2. Generate Monthly Payroll")
        print("  3. View Monthly Attendance Report")
        print("  4. View All Employees")
        print("  5. Exit")
        print("=" * 50)
        choice = input("  Select option: ").strip()

        if choice == "1":
            hr_add_employee(conn)
        elif choice == "2":
            hr_generate_payroll(conn)
        elif choice == "3":
            hr_attendance_report(conn)
        elif choice == "4":
            hr_view_employees(conn)
        elif choice == "5":
            print("\n  Goodbye!\n")
            break
        else:
            print("  [!] Invalid option. Please choose 1-5.\n")


# ==============================================================================
# SECTION 5: EMPLOYEE SELF-SERVICE MENU ACTIONS
# ==============================================================================

def emp_view_attendance(conn, emp_id: int):
    """Display the employee's attendance for a chosen month/year."""
    print("\n--- My Monthly Attendance ---")
    month, year = prompt_month_year()
    if month is None:
        return

    sql = """
        SELECT
            att_date,
            check_in,
            check_out,
            status
        FROM vw_emp_attendance
        WHERE emp_id    = %s
          AND MONTH(att_date) = %s
          AND YEAR(att_date)  = %s
        ORDER BY att_date
    """
    try:
        cursor = conn.cursor()
        cursor.execute(sql, (emp_id, month, year))
        rows = cursor.fetchall()
        cursor.close()
        print(f"\n  Attendance — {month:02d}/{year}\n")
        headers = ["Date", "Check-In", "Check-Out", "Status"]
        print_table(headers, rows)
    except MySQLError:
        print("\n  [!] Unable to retrieve attendance data. Please contact HR.\n")


def emp_view_payslip(conn, emp_id: int):
    """Display a formatted payslip for the employee."""
    print("\n--- My Payslip ---")
    month, year = prompt_month_year()
    if month is None:
        return

    # Fetch from vw_emp_payroll (employee-safe view) first;
    # fall back to Payroll table if view is unavailable.
    sql = """
        SELECT
            emp_id,
            pay_month,
            pay_year,
            gross_salary,
            unpaid_leave_deduction,
            tax_deduction,
            net_salary,
            payment_status
        FROM vw_emp_payroll
        WHERE emp_id    = %s
          AND pay_month = %s
          AND pay_year  = %s
    """
    try:
        cursor = conn.cursor()
        cursor.execute(sql, (emp_id, month, year))
        row = cursor.fetchone()
        cursor.close()

        if not row:
            print(f"\n  [!] No payslip found for {month:02d}/{year}.\n")
            return

        (eid, pm, py, gross, leave_ded, tax_ded, net, status) = row

        # Pretty payslip box
        line = "=" * 51
        print(f"\n{line}")
        print(f"{'PAYSLIP':^51}")
        print(line)
        print(f"  Employee ID  : {eid}")
        print(f"  Period       : {pm:02d}/{py}")
        print(line)
        print(f"  Gross Salary : {float(gross):>12,.2f}")
        print(f"  Leave Deduct : {-float(leave_ded):>12,.2f}")
        print(f"  Tax Deducted : {-float(tax_ded):>12,.2f}")
        print(line)
        print(f"  Net Salary   : {float(net):>12,.2f}")
        print(f"  Status       : {status}")
        print(f"{line}\n")

    except MySQLError:
        print("\n  [!] Unable to retrieve payslip. Please contact HR.\n")


def emp_view_leave_history(conn, emp_id: int):
    """Display all leave records for the employee."""
    print("\n--- My Leave History ---\n")
    sql = """
        SELECT
            leave_id,
            leave_type,
            start_date,
            end_date,
            status,
            applied_on
        FROM Leave_Record
        WHERE emp_id = %s
        ORDER BY applied_on DESC
    """
    try:
        cursor = conn.cursor()
        cursor.execute(sql, (emp_id,))
        rows = cursor.fetchall()
        cursor.close()
        headers = ["LeaveID", "Type", "Start Date", "End Date", "Status", "Applied On"]
        print_table(headers, rows)
    except MySQLError:
        print("\n  [!] Unable to retrieve leave records. Please contact HR.\n")


def employee_menu(conn, emp_id: int, username: str):
    """Main Employee self-service menu loop."""
    while True:
        print("=" * 50)
        print(f"  EMPLOYEE MENU  (Logged in as: {username}  |  EmpID: {emp_id})")
        print("=" * 50)
        print("  1. View My Monthly Attendance")
        print("  2. View My Payslip")
        print("  3. View My Leave History")
        print("  4. Exit")
        print("=" * 50)
        choice = input("  Select option: ").strip()

        if choice == "1":
            emp_view_attendance(conn, emp_id)
        elif choice == "2":
            emp_view_payslip(conn, emp_id)
        elif choice == "3":
            emp_view_leave_history(conn, emp_id)
        elif choice == "4":
            print("\n  Goodbye!\n")
            break
        else:
            print("  [!] Invalid option. Please choose 1-4.\n")


# ==============================================================================
# SECTION 6: LOGIN & MAIN ORCHESTRATION
# ==============================================================================

def resolve_emp_id(conn, username: str) -> int:
    """
    Determine the emp_id for a logged-in employee.
    Strategy:
      1. Check static mapping (USERNAME_TO_EMP_ID).
      2. Fall back: query Employee WHERE email starts with username.
      3. Last resort: prompt user to enter their emp_id.
    Returns emp_id as int, or None if not found/invalid.
    """
    # Static mapping (fastest, works for demo)
    if username in USERNAME_TO_EMP_ID:
        return USERNAME_TO_EMP_ID[username]

    # Dynamic lookup via email prefix
    try:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT emp_id FROM Employee WHERE email LIKE %s LIMIT 1",
            (f"{username}%",)
        )
        row = cursor.fetchone()
        cursor.close()
        if row:
            return row[0]
    except MySQLError:
        pass  # fall through to manual prompt

    # Manual fallback
    try:
        emp_id = int(input("  Could not auto-detect Employee ID.\n"
                           "  Please enter your Employee ID: ").strip())
        return emp_id
    except (ValueError, EOFError):
        return None


def login() -> tuple:
    """
    Handle role-based login with up to 3 attempts.
    Returns (conn, username, role) on success, or raises SystemExit on failure.

    Roles:
        'hr'       → username == 'hr_admin'
        'employee' → any other username
    """
    MAX_ATTEMPTS = 3
    print_banner()
    print("  Please log in to continue.\n")

    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            username = input(f"  Username [{attempt}/{MAX_ATTEMPTS}]: ").strip()
            password = getpass.getpass("  Password             : ")
        except (EOFError, KeyboardInterrupt):
            print("\n\n  Login cancelled. Exiting.\n")
            sys.exit(0)

        if not username:
            print("  [!] Username cannot be empty.\n")
            continue

        # Map CLI username to MySQL user; default to the username itself
        mysql_user = KNOWN_USERS.get(username, username)
        role = "hr" if username == "hr_admin" else "employee"

        try:
            conn = get_connection(mysql_user, password)
            print(f"\n  [✓] Login successful! Welcome, {username}.\n")
            return conn, username, role
        except MySQLError as err:
            remaining = MAX_ATTEMPTS - attempt
            if remaining:
                print(f"  [!] Login failed: {err.msg}\n"
                      f"      {remaining} attempt(s) remaining.\n")
            else:
                print(f"  [!] Login failed: {err.msg}\n"
                      "      Maximum attempts reached. Exiting.\n")

    sys.exit(1)


def main():
    """Entry point: handle login then dispatch to the appropriate menu."""
    conn = None
    try:
        conn, username, role = login()

        if role == "hr":
            hr_menu(conn)
        else:
            # Resolve employee ID before showing the menu
            emp_id = resolve_emp_id(conn, username)
            if emp_id is None:
                print("  [!] Could not determine your Employee ID. "
                      "Please contact HR.\n")
                sys.exit(1)
            employee_menu(conn, emp_id, username)

    except KeyboardInterrupt:
        print("\n\n  Interrupted. Exiting gracefully.\n")
    finally:
        if conn and conn.is_connected():
            conn.close()


# ==============================================================================
# ENTRY POINT
# ==============================================================================

if __name__ == "__main__":
    main()
