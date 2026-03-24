# IDMC Banking Data Pipeline — Portfolio Project

**Stack:** Informatica IDMC (CDI + CDQ + CDGC) · Snowflake (storage only) · CSV / API source simulation

---

## What This Project Demonstrates

This project simulates a production-grade banking data platform built on **Informatica IDMC** as the
primary orchestration, transformation and governance layer, with Snowflake acting purely as the target
storage layer. It directly reflects the architecture decisions relevant to greenfield banking platform
implementations at regional banks.

**Core capabilities demonstrated:**

| Capability | Implementation |
|---|---|
| IDMC-native thinking | All ETL logic in CDI mappings — zero Snowflake SQL transforms |
| CDC detection | `cdc_operation` field + hash comparison for insert vs update routing |
| SCD Type 2 | Customer dimension with full historical tracking and effective dating |
| Parameterized pipelines | Runtime parameter sets for file paths, dates, run IDs, connections |
| Data quality enforcement | CDQ rules with reject routing to error table (no silent drops) |
| CDGC governance | Data domain tagging, business glossary alignment, lineage tracking |
| Banking domain model | Customer → Account (deposits) → Transaction → Balance snapshot chain |
| Error handling | Reject threshold gates, fail-fast rules, run log with audit trail |
| Reusable design | Same taskflow runs daily with zero code change via parameter file |

---

## Project Structure

```
idmc-banking-pipeline/
│
├── datasets/
│   ├── customers_full_load.csv                  Initial customer master (10 records)
│   ├── customers_cdc_delta_20240320.csv          CDC delta: 2 updates, 1 new, 1 bad record
│   ├── accounts_full_load.csv                   15 deposit accounts across all customers
│   ├── transactions_20240319_20240320.csv        15 transactions — includes intentional rejects
│   └── account_balances_20240319.csv             Daily end-of-day balance snapshot
│
├── ddl/
│   └── snowflake_ddl.sql                        Full DDL: RAW, CURATED, ERROR, CONTROL schemas
│
├── mapping-specs/
│   └── cdi_mapping_specs.md                     6 CDI mapping designs with full transformation logic
│
├── taskflow/
│   └── taskflow_design.md                       Master taskflow with parallel/sequential structure
│
├── quality-rules/
│   └── cdq_rules_spec.md                        4 CDQ rule sets (customer, account, txn, balances)
│
└── docs/
    └── README.md                                This file
```

---

## Data Model

### Source Entities
- **Customers** — master dimension, CDC-sourced from core banking (FIS-style)
- **Accounts** — deposit accounts (CHECKING, SAVINGS, MONEY_MARKET)
- **Transactions** — daily debit/credit activity across all channels
- **Account Balances** — end-of-day snapshot per account

### Snowflake Target (star schema in CURATED layer)

```
DIM_DATE ──────────────────────────────────────────────┐
                                                        ▼
DIM_CUSTOMER (SCD2) ──── FACT_TRANSACTIONS ────── DIM_ACCOUNT (Type 1)
                    └─── FACT_ACCOUNT_BALANCES
```

### Layer Architecture

| Layer    | Schema              | Purpose                                         |
|----------|---------------------|-------------------------------------------------|
| RAW      | BANKING_DW.RAW      | As-landed records — immutable, append-only log  |
| CURATED  | BANKING_DW.CURATED  | Dimensional model — dims + facts                |
| ERROR    | BANKING_DW.ERROR    | Rejected records with reason codes              |
| CONTROL  | BANKING_DW.CONTROL  | Pipeline watermarks + run audit log             |

---

## Key Design Decisions

### Why Snowflake is storage-only

A common mistake in IDMC implementations is using Snowflake dynamic tables or dbt
to perform transformations that should live in Informatica. In a regulated banking
environment, keeping all transformation logic in IDMC ensures:

1. **Lineage is captured automatically** in CDGC (Snowflake SQL transforms are invisible to Informatica lineage)
2. **Data quality rules** are centrally governed in CDQ, not scattered across SQL scripts
3. **Non-technical governance users** can see and manage rules via CDGC without SQL access
4. **Audit trail** is uniform — one system owns transformation provenance

### Why SCD Type 2 on customers only

SCD Type 2 is expensive (doubles row count over time, complicates joins). It is applied
selectively — only where history genuinely matters for regulatory or business reasons:
- **Customer profile (DIM_CUSTOMER):** KYC status, segment and address changes must be
  tracked for BSA/AML audit. Knowing a customer was "RETAIL" when a transaction occurred
  and later upgraded to "PRIVATE" is material for risk reporting.
- **Accounts (DIM_ACCOUNT):** Status changes (ACTIVE→SUSPENDED) are overwritten (Type 1).
  The raw layer preserves the full history for audit if needed.

### CDC detection approach (without database redo logs)

In this project, CDC is file-based (simulating a core banking batch extract):
1. Source system stamps each record with `cdc_operation` (INSERT/UPDATE/DELETE)
2. CDI reads the delta file and routes via **Router transformation**
3. For UPDATE records, an **Expression transformation** computes `MD5` hash of
   tracked fields (segment, KYC status, email, address)
4. A **Lookup** on DIM_CUSTOMER compares the incoming hash to the stored hash
5. Only records with hash mismatch proceed to the SCD2 expire-and-insert logic

In a real-world IDMC deployment against Oracle, this would use Informatica CDC connector
with redo log capture — the SCD2 mapping logic is identical regardless of CDC source.

### Parameterization strategy

Every file path, date reference, connection name and run identifier is a runtime parameter.
The taskflow never hardcodes a date or filename. This means:
- The same taskflow XML runs in DEV, UAT and PROD with different parameter sets
- Re-running a historical date requires only changing `$$LOAD_DATE` in the parameter file
- Adding a new source file requires only a new parameter — no mapping changes

---

## Intentional Reject Scenarios in Sample Data

The datasets include deliberate bad records to demonstrate CDQ rule enforcement:

| Record | File | Expected Failure | CDQ Rule |
|---|---|---|---|
| `C012 george.patel@invalidomain` | customers_cdc_delta | INVALID_EMAIL_FORMAT | CQ-002 |
| `TXN-20240319-0012` amount = -50.00 | transactions | INVALID_AMOUNT_NON_POSITIVE | TQ-003 |
| `TXN-20240319-0011` status = DECLINED | transactions | Valid record — loads to fact; status is domain-valid | — |
| `A10013 C009` SUSPENDED account | accounts | Valid record — status SUSPENDED is in domain | — |

These records test that CDQ correctly distinguishes genuinely invalid data from
valid-but-unusual banking scenarios (a declined transaction is not a bad record —
it is a real banking event that must be tracked).

---

## CDGC Governance Artifacts

The following governance artifacts would be configured in Informatica CDGC:

**Data Domains (classification)**
- `banking.customer.pii` — covers FIRST_NAME, LAST_NAME, EMAIL, PHONE, ADDRESS
- `banking.account.financial` — covers balances, interest rates, overdraft limits
- `banking.transaction.financial` — covers AMOUNT, CURRENCY, REFERENCE_NO

**Business Glossary Terms**
- `Customer Segment` → links to DIM_CUSTOMER.SEGMENT
- `KYC Status` → links to DIM_CUSTOMER.KYC_STATUS (regulatory term: Know Your Customer)
- `Money Market Account` → links to DIM_ACCOUNT where ACCOUNT_SUBTYPE = 'MONEY_MARKET'
- `Closing Balance` → links to FACT_ACCOUNT_BALANCES.CLOSING_BALANCE

**Policy Tags**
- PII fields tagged → triggers data masking in lower environments
- Financial fields tagged → triggers access control review quarterly

**Lineage (auto-captured by CDGC)**
- `customers_cdc_delta.csv` → RAW.CUSTOMERS → CDI mapping → CURATED.DIM_CUSTOMER

---

## How to Run (with IDMC trial account)

1. **Snowflake:** Execute `ddl/snowflake_ddl.sql` to create all schemas and tables
2. **IDMC CDI:** Create a Snowflake connection using `$$SF_CONNECTION` name
3. **IDMC CDI:** Build mappings per specs in `mapping-specs/cdi_mapping_specs.md`
4. **IDMC CDQ:** Configure rule sets per `quality-rules/cdq_rules_spec.md`
5. **IDMC CDI:** Create parameter set `PS_BANKING_DAILY` with values from taskflow doc
6. **IDMC CDI:** Build master taskflow `TF_BANKING_DAILY_LOAD` per `taskflow/taskflow_design.md`
7. **Run:** Execute with `$$LOAD_DATE=2024-03-20`, observe reject routing and SCD2 behavior

---

## Interview Context

This project was designed to address the following evaluation dimensions observed in
a technical interview for a data engineering role at a regional bank:

- **IDMC-first thinking** — not Snowflake-first or PowerCenter-style
- **Banking domain awareness** — deposit products, KYC, balance snapshots, GL linkage
- **CDC + SCD2 capability** — production-grade historical tracking
- **CDQ familiarity** — rule-based quality, not ad hoc SQL filters
- **CDGC awareness** — governance layer beyond just integration
- **Parameterized, reusable design** — not hardcoded one-time scripts
- **Error handling** — reject routing, audit trail, safe re-run

---

*Built as a portfolio demonstration of Informatica IDMC (CDI + CDQ + CDGC) banking pipeline design.*
