# Informatica CDI — Mapping Specifications
## IDMC Banking Pipeline

All mappings are built in Informatica CDI (Cloud Data Integration).
Snowflake is the target storage layer only — no transformation logic runs in Snowflake SQL.

---

## Runtime Parameters (defined in CDI Parameter Set)

| Parameter Name            | Type   | Example Value                          | Purpose                          |
|---------------------------|--------|----------------------------------------|----------------------------------|
| `$$SOURCE_DIR`            | String | `/data/inbound/banking/`               | Root directory for source files  |
| `$$SOURCE_FILE_CUSTOMERS` | String | `customers_cdc_delta_${LOAD_DATE}.csv` | Dynamic filename with date token |
| `$$SOURCE_FILE_TXN`       | String | `transactions_${LOAD_DATE}.csv`        | Transactions daily file          |
| `$$LOAD_DATE`             | Date   | `2024-03-20`                           | Business date of the run         |
| `$$PIPELINE_RUN_ID`       | String | `RUN-20240320-001`                     | Unique run identifier            |
| `$$SF_CONNECTION`         | String | `SNOWFLAKE_BANKING_CONN`               | Snowflake connection object name |

---

## Mapping 1: M_CUSTOMER_INGEST_RAW

**Purpose:** Read customer CDC delta CSV and land into RAW.CUSTOMERS.
**CDI Type:** Flat File → Snowflake

### Source (Flat File Reader)
- File path: `$$SOURCE_DIR + $$SOURCE_FILE_CUSTOMERS`
- Format: Delimited, comma separator, first row as header
- Encoding: UTF-8
- Error on missing file: Yes (fail the task)

### Transformations

**EXP_ADD_METADATA** (Expression)

| Output Field     | Expression                                            |
|------------------|-------------------------------------------------------|
| PIPELINE_RUN_ID  | `$$PIPELINE_RUN_ID`                                   |
| SOURCE_FILE_NAME | `$$SOURCE_FILE_CUSTOMERS`                             |
| LOAD_TIMESTAMP   | `SYSTIMESTAMP()`                                      |
| CDC_OPERATION    | `IIF(ISNULL(CDC_OPERATION), 'INSERT', CDC_OPERATION)` |

### Target (Snowflake)
- Table: `BANKING_DW.RAW.CUSTOMERS`
- Load type: Insert (append — RAW is immutable log)
- Bulk load: Enabled via Snowflake connector

---

## Mapping 2: M_CUSTOMER_CDC_SCD2

**Purpose:** Detect inserts and updates from RAW; apply SCD Type 2 logic to CURATED.DIM_CUSTOMER.
**CDI Type:** Snowflake → Snowflake (no Snowflake SQL transform — all logic in CDI)

### Source 1 — Incoming records
- Table: `BANKING_DW.RAW.CUSTOMERS`
- Filter: `PIPELINE_RUN_ID = '$$PIPELINE_RUN_ID'`

### Source 2 — Current dimension records (Lookup)
- Table: `BANKING_DW.CURATED.DIM_CUSTOMER`
- Filter: `IS_CURRENT = TRUE`
- Lookup condition: `CUSTOMER_ID = CUSTOMER_ID`
- Return: `CUSTOMER_SK`, `RECORD_HASH`, `EFF_START_DATE`

### Transformations

**EXP_HASH** (Expression — compute change hash)

| Output Field | Expression                                                                  |
|--------------|-----------------------------------------------------------------------------|
| NEW_HASH     | `MD5(SEGMENT \|\| KYC_STATUS \|\| EMAIL \|\| ADDRESS \|\| CITY \|\| STATE)` |

**FIL_CHANGED** (Filter — pass only genuine changes)
- Condition: `ISNULL(LKP_CUSTOMER_SK) OR NEW_HASH != LKP_RECORD_HASH`

**RTR_INSERT_UPDATE** (Router — separate INSERTs from UPDATEs)
- Group NEW: `ISNULL(LKP_CUSTOMER_SK)` → new customer
- Group CHANGED: `NOT ISNULL(LKP_CUSTOMER_SK) AND NEW_HASH != LKP_RECORD_HASH` → changed customer

### Targets

**Target A — Expire old record (UPDATE)**
- Table: `BANKING_DW.CURATED.DIM_CUSTOMER`
- Load type: Update
- Update condition: `CUSTOMER_SK = LKP_CUSTOMER_SK`
- Fields set: `EFF_END_DATE = DATEADD(DAY,-1,$$LOAD_DATE)`, `IS_CURRENT = FALSE`

**Target B — Insert new/updated version (INSERT)**
- Table: `BANKING_DW.CURATED.DIM_CUSTOMER`
- Load type: Insert
- Key fields mapped:
  - `CUSTOMER_SK` → (sequence generator, CDI-managed)
  - `EFF_START_DATE` → `$$LOAD_DATE`
  - `EFF_END_DATE` → NULL
  - `IS_CURRENT` → TRUE
  - `RECORD_HASH` → `NEW_HASH`
  - `CREATED_BY_PIPELINE` → `$$PIPELINE_RUN_ID`

---

## Mapping 3: M_TRANSACTIONS_INGEST_AND_LOAD

**Purpose:** Incremental transaction load with deduplication and reject routing.
**CDI Type:** Flat File → Snowflake (RAW + CURATED + ERROR)

### Source
- File: `$$SOURCE_DIR + $$SOURCE_FILE_TXN`

### Transformations

**FIL_VALID** (Filter — pre-quality gate)
- Condition: `AMOUNT > 0 AND NOT ISNULL(TRANSACTION_ID)`
- Failed records: routed to EXP_REJECT_PREP

**EXP_REJECT_PREP** (Expression — build reject record)

| Output Field  | Expression                                                                   |
|---------------|------------------------------------------------------------------------------|
| SOURCE_ENTITY | `'TRANSACTIONS'`                                                             |
| BUSINESS_KEY  | `TRANSACTION_ID`                                                             |
| REJECT_REASON | `IIF(AMOUNT <= 0, 'INVALID_AMOUNT: amount <= 0', 'NULL_TRANSACTION_ID')`     |
| RAW_RECORD    | Concatenated field string (JSON-formatted)                                   |

**LKP_DIM_ACCOUNT** (Lookup)
- Table: `BANKING_DW.CURATED.DIM_ACCOUNT`
- Condition: `ACCOUNT_ID = ACCOUNT_ID`
- Return: `ACCOUNT_SK`, `CUSTOMER_SK`

**LKP_DIM_DATE** (Lookup)
- Table: `BANKING_DW.CURATED.DIM_DATE`
- Condition: `DATE_SK = TO_NUMBER(TO_CHAR(TRANSACTION_DATE,'YYYYMMDD'))`
- Return: `DATE_SK`

**LKP_DEDUP** (Lookup — prevent duplicate loads)
- Table: `BANKING_DW.CURATED.FACT_TRANSACTIONS`
- Condition: `TRANSACTION_ID = TRANSACTION_ID`
- Return: `TRANSACTION_SK`
- FIL_NEW: `ISNULL(LKP_TRANSACTION_SK)` — only new records proceed

### Targets
1. `BANKING_DW.RAW.TRANSACTIONS` → Insert
2. `BANKING_DW.CURATED.FACT_TRANSACTIONS` → Insert (new records only)
3. `BANKING_DW.ERROR.REJECT_RECORDS` → Insert (failed filter records)
