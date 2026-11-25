-- ============================================================================
-- ICT371 Advanced Database
-- Question 6: Monthly Payroll Processing (PostgreSQL / PL/pgSQL)
-- ============================================================================

-- (a) Database and seed data
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(120) NOT NULL,
    basic_salary NUMERIC(12, 2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (allowance >= 0),
    deduction    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL CHECK (DATE_TRUNC('month', pay_month)::date = pay_month),
    gross_pay   NUMERIC(12, 2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12, 2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12, 2) NOT NULL CHECK (old_salary >= 0),
    new_salary  NUMERIC(12, 2) NOT NULL CHECK (new_salary >= 0),
    changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Dr. Grace Chileshe', 18000.00, 3000.00, 2500.00, TRUE),
    ('Mr. Benson Mwansa',  12000.00, 1500.00, 1000.00, TRUE),
    ('Ms. Ruth Kalumba',    9500.00, 1000.00,  800.00, FALSE);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic     NUMERIC(12, 2);
    v_allowance NUMERIC(12, 2);
    v_deduction NUMERIC(12, 2);
    v_net       NUMERIC(12, 2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allowance, v_deduction
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := ROUND((v_basic + v_allowance - v_deduction)::numeric, 2);
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Computed net pay is negative (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_emp   RECORD;
    v_gross NUMERIC(12, 2);
    v_net   NUMERIC(12, 2);
BEGIN
    IF p_month IS NULL OR DATE_TRUNC('month', p_month)::date <> p_month THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;

    FOR v_emp IN
        SELECT employee_id, basic_salary, allowance, deduction
        FROM employees
        WHERE active = TRUE
    LOOP
        v_gross := ROUND((v_emp.basic_salary + v_emp.allowance)::numeric, 2);
        v_net   := fn_net_pay(v_emp.employee_id);

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (v_emp.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_log_salary_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
EXECUTE FUNCTION fn_log_salary_change();

-- Process two payroll months
CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '2 months')::date);
CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::date);

-- (e) View
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- (f) Index, Query, and EXPLAIN
-- Justification: Single-column index on pay_month accelerates month-wide payroll reports without duplicating (employee_id, pay_month).
CREATE INDEX idx_payroll_pay_month
ON payroll (pay_month);

EXPLAIN
SELECT payroll_id, employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE_TRUNC('month', CURRENT_DATE)::date;

-- (g) Scheduled job & inspection
-- Run at 02:00 on the 1st of each month for the previous month's start date
SELECT cron.schedule(
    'monthly_payroll_job',
    '0 2 1 * *',
    $$CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::date);$$
);

-- Inspect scheduled jobs
SELECT jobid, jobname, schedule, command, active
FROM cron.job;

-- Inspect job run history
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY start_time DESC;
