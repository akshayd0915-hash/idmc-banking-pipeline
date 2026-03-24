-- =============================================================
-- IDMC Banking Pipeline — Snowflake DDL
-- Snowflake is STORAGE ONLY. All transformation logic lives in
-- Informatica CDI mappings and taskflows.
-- =============================================================

-- ---------------------------------------------------------------
-- DATABASE & SCHEMA SETUP
-- ---------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS BANKING_DW;

CREATE SCHEMA IF NOT EXISTS BANKING_DW.RAW;       -- Bronze: as-landed, no transforms
CREATE SCHEMA IF NOT EXISTS BANKING_DW.CURATED;   -- Gold: dimensional model
CREATE SCHEMA IF NOT EXISTS BANKING_DW.ERROR;     -- Reject records + audit log

-- ---------------------------------------------------------------
-- RAW LAYER  (CDI lands data here directly from source)
-- ---------------------------------------------------------------

CREATE OR REPLACE TABLE BANKING_DW.RAW.CUSTOMERS (
    CUSTOMER_ID         VARCHAR(20),
    FIRST_NAME          VARCHAR(100),
    LAST_NAME           VARCHAR(100),
    EMAIL               VARCHAR(200),
    PHONE               VARCHAR(20),
    ADDRESS             VARCHAR(300),
    CITY                VARCHAR(100),
    STATE               VARCHAR(2),
    ZIP                 VARCHAR(10),
    SEGMENT             VARCHAR(20),
    KYC_STATUS          VARCHAR(20),
    KYC_DATE            DATE,
    CREATED_DATE        DATE,
    LAST_UPDATED        DATE,
    CDC_OPERATION       VARCHAR(10),           -- INSERT / UPDATE / DELETE
    -- Pipeline metadata
    PIPELINE_RUN_ID     VARCHAR(50),
    SOURCE_FILE_NAME    VARCHAR(300),
    LOAD_TIMESTAMP      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE BANKING_DW.RAW.ACCOUNTS (
    ACCOUNT_ID          VARCHAR(20),
    CUSTOMER_ID         VARCHAR(20),
    ACCOUNT_TYPE        VARCHAR(20),
    ACCOUNT_SUBTYPE     VARCHAR(30),
    STATUS              VARCHAR(20),
    OPEN_DATE           DATE,
    CLOSE_DATE          DATE,
    INTEREST_RATE       NUMBER(6,4),
    OVERDRAFT_LIMIT     NUMBER(15,2),
    BRANCH_CODE         VARCHAR(10),
    CREATED_DATE        DATE,
    LAST_UPDATED        DATE,
    PIPELINE_RUN_ID     VARCHAR(50),
    SOURCE_FILE_NAME    VARCHAR(300),
    LOAD_TIMESTAMP      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE BANKING_DW.RAW.TRANSACTIONS (
    TRANSACTION_ID      VARCHAR(50),
    ACCOUNT_ID          VARCHAR(20),
    CUSTOMER_ID         VARCHAR(20),
    TRANSACTION_DATE    DATE,
    TRANSACTION_TIME    TIME,
    TRANSACTION_TYPE    VARCHAR(10),
    AMOUNT              NUMBER(18,2),
    CURRENCY            VARCHAR(3),
    CHANNEL             VARCHAR(20),
    DESCRIPTION         VARCHAR(500),
    STATUS              VARCHAR(20),
    REFERENCE_NO        VARCHAR(50),
    PIPELINE_RUN_ID     VARCHAR(50),
    SOURCE_FILE_NAME    VARCHAR(300),
    LOAD_TIMESTAMP      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE BANKING_DW.RAW.ACCOUNT_BALANCES (
    ACCOUNT_ID          VARCHAR(20),
    CUSTOMER_ID         VARCHAR(20),
    SNAPSHOT_DATE       DATE,
    OPENING_BALANCE     NUMBER(18,2),
    CLOSING_BALANCE     NUMBER(18,2),
    AVAILABLE_BALANCE   NUMBER(18,2),
    CURRENCY            VARCHAR(3),
    TOTAL_DEBITS        NUMBER(18,2),
    TOTAL_CREDITS       NUMBER(18,2),
    TRANSACTION_COUNT   INT,
    STATUS              VARCHAR(20),
    PIPELINE_RUN_ID     VARCHAR(50),
    SOURCE_FILE_NAME    VARCHAR(300),
    LOAD_TIMESTAMP      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------
-- CURATED LAYER — Dimensional model (star schema)
-- SCD Type 2 on DIM_CUSTOMER. All logic driven by CDI.
-- ---------------------------------------------------------------

-- DIM_CUSTOMER  (SCD Type 2 — history preserved per segment/KYC change)
CREATE OR REPLACE TABLE BANKING_DW.CURATED.DIM_CUSTOMER (
    CUSTOMER_SK         NUMBER AUTOINCREMENT PRIMARY KEY,   -- Surrogate key (CDI sequence)
    CUSTOMER_ID         VARCHAR(20)     NOT NULL,           -- Business key
    FIRST_NAME          VARCHAR(100),
    LAST_NAME           VARCHAR(100),
    EMAIL               VARCHAR(200),
    PHONE               VARCHAR(20),
    ADDRESS             VARCHAR(300),
    CITY                VARCHAR(100),
    STATE               VARCHAR(2),
    ZIP                 VARCHAR(10),
    SEGMENT             VARCHAR(20),
    KYC_STATUS          VARCHAR(20),
    KYC_DATE            DATE,
    -- SCD2 tracking columns
    EFF_START_DATE      DATE            NOT NULL,
    EFF_END_DATE        DATE,                               -- NULL = current record
    IS_CURRENT          BOOLEAN         DEFAULT TRUE,
    RECORD_HASH         VARCHAR(64),                        -- MD5 of tracked columns
    -- Audit
    CREATED_BY_PIPELINE VARCHAR(100),
    LOAD_TIMESTAMP      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- DIM_ACCOUNT (Type 1 — no history needed; status changes overwrite)
CREATE OR REPLACE TABLE BANKING_DW.CURATED.DIM_ACCOUNT (
    ACCOUNT_SK          NUMBER AUTOINCREMENT PRIMARY KEY,
    ACCOUNT_ID          VARCHAR(20)     NOT NULL,
    CUSTOMER_SK         NUMBER,                             -- FK to DIM_CUSTOMER
    CUSTOMER_ID         VARCHAR(20),
    ACCOUNT_TYPE        VARCHAR(20),
    ACCOUNT_SUBTYPE     VARCHAR(30),
    STATUS              VARCHAR(20),
    OPEN_DATE           DATE,
    CLOSE_DATE          DATE,
    INTEREST_RATE       NUMBER(6,4),
    OVERDRAFT_LIMIT     NUMBER(15,2),
    BRANCH_CODE         VARCHAR(10),
    LOAD_TIMESTAMP      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- DIM_DATE (pre-populated — loaded once)
CREATE OR REPLACE TABLE BANKING_DW.CURATED.DIM_DATE (
    DATE_SK             INT             PRIMARY KEY,        -- YYYYMMDD integer key
    FULL_DATE           DATE            NOT NULL,
    DAY_OF_WEEK         VARCHAR(10),
    DAY_NUM             INT,
    WEEK_NUM            INT,
    MONTH_NUM           INT,
    MONTH_NAME          VARCHAR(10),
    QUARTER             INT,
    YEAR                INT,
    IS_WEEKEND          BOOLEAN,
    IS_BANK_HOLIDAY     BOOLEAN DEFAULT FALSE
);

-- FACT_TRANSACTIONS
CREATE OR REPLACE TABLE BANKING_DW.CURATED.FACT_TRANSACTIONS (
    TRANSACTION_SK      NUMBER AUTOINCREMENT PRIMARY KEY,
    TRANSACTION_ID      VARCHAR(50)     NOT NULL,           -- Business key (dedup)
    ACCOUNT_SK          NUMBER,                             -- FK to DIM_ACCOUNT
    CUSTOMER_SK         NUMBER,                             -- FK to DIM_CUSTOMER (current)
    DATE_SK             INT,                                -- FK to DIM_DATE
    TRANSACTION_DATE    DATE,
    TRANSACTION_TYPE    VARCHAR(10),
    AMOUNT              NUMBER(18,2),
    CURRENCY            VARCHAR(3),
    CHANNEL             VARCHAR(20),
    DESCRIPTION         VARCHAR(500),
    STATUS              VARCHAR(20),
    REFERENCE_NO        VARCHAR(50),
    PIPELINE_RUN_ID     VARCHAR(50),
    LOAD_TIMESTAMP      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- FACT_ACCOUNT_BALANCES  (incremental snapshot — appended daily by business date)
CREATE OR REPLACE TABLE BANKING_DW.CURATED.FACT_ACCOUNT_BALANCES (
    BALANCE_SK          NUMBER AUTOINCREMENT PRIMARY KEY,
    ACCOUNT_SK          NUMBER,
    CUSTOMER_SK         NUMBER,
    DATE_SK             INT,
    SNAPSHOT_DATE       DATE            NOT NULL,
    OPENING_BALANCE     NUMBER(18,2),
    CLOSING_BALANCE     NUMBER(18,2),
    AVAILABLE_BALANCE   NUMBER(18,2),
    CURRENCY            VARCHAR(3),
    TOTAL_DEBITS        NUMBER(18,2),
    TOTAL_CREDITS       NUMBER(18,2),
    TRANSACTION_COUNT   INT,
    PIPELINE_RUN_ID     VARCHAR(50),
    LOAD_TIMESTAMP      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------
-- ERROR LAYER — Reject routing from CDQ
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE BANKING_DW.ERROR.REJECT_RECORDS (
    REJECT_SK           NUMBER AUTOINCREMENT PRIMARY KEY,
    PIPELINE_RUN_ID     VARCHAR(50),
    SOURCE_ENTITY       VARCHAR(50),                        -- customers / accounts / transactions
    SOURCE_FILE_NAME    VARCHAR(300),
    BUSINESS_KEY        VARCHAR(100),                       -- customer_id / account_id / txn_id
    REJECT_REASON       VARCHAR(1000),                      -- CDQ rule name + detail
    RAW_RECORD          VARIANT,                            -- Full failed record as JSON
    REJECT_TIMESTAMP    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------
-- Seed DIM_DATE for 2023-2025
-- ---------------------------------------------------------------
INSERT INTO BANKING_DW.CURATED.DIM_DATE
SELECT
    TO_NUMBER(TO_CHAR(d, 'YYYYMMDD'))          AS DATE_SK,
    d                                           AS FULL_DATE,
    DAYNAME(d)                                  AS DAY_OF_WEEK,
    DAYOFWEEK(d)                                AS DAY_NUM,
    WEEKOFYEAR(d)                               AS WEEK_NUM,
    MONTH(d)                                    AS MONTH_NUM,
    MONTHNAME(d)                                AS MONTH_NAME,
    QUARTER(d)                                  AS QUARTER,
    YEAR(d)                                     AS YEAR,
    DAYOFWEEK(d) IN (0, 6)                      AS IS_WEEKEND,
    FALSE                                       AS IS_BANK_HOLIDAY
FROM (
    SELECT DATEADD(DAY, SEQ4(), '2023-01-01') AS d
    FROM TABLE(GENERATOR(ROWCOUNT => 1096))   -- 3 years
)
WHERE d <= '2025-12-31';
