# Informatica CDI — Taskflow Design
## IDMC Banking Pipeline

All orchestration runs inside Informatica CDI Taskflows.
An enterprise scheduler (e.g., CA7 / Tivoli) triggers the master taskflow once daily — no Airflow, no Snowflake Tasks.

---

## Master Taskflow: TF_BANKING_DAILY_LOAD

**Trigger:** Enterprise scheduler at 06:00 EST (after source files land)
**Parameter Set:** PS_BANKING_DAILY (resolves all `$$VARIABLES` at runtime)

```
TF_BANKING_DAILY_LOAD
│
├── [TASKFLOW] TF_INGEST_RAW
│     │
│     ├── MT_CUSTOMER_INGEST_RAW    → M_CUSTOMER_INGEST_RAW
│     └── MT_TRANSACTION_INGEST_RAW → M_TRANSACTIONS_INGEST_AND_LOAD (RAW only)
│
│     On any failure: abort taskflow immediately
│
├── [TASKFLOW] TF_QUALITY_CHECK
│     │
│     └── MT_CDQ_CUSTOMER_RULES
│           CDQ rule set RLS_CUSTOMER_QUALITY on RAW.CUSTOMERS
│           Rejects → ERROR.REJECT_RECORDS
│           If reject rate > 10%: fail task and abort
│
└── [TASKFLOW] TF_CURATED_LOAD  (sequential — order enforces FK dependency)
      │
      ├── MT_CUSTOMER_SCD2       → M_CUSTOMER_CDC_SCD2
      │     Must run first (CUSTOMER_SK required downstream)
      │
      └── MT_TRANSACTIONS_CURATED → M_TRANSACTIONS_INGEST_AND_LOAD (CURATED target)
            Requires DIM_CUSTOMER to be current before loading FACT_TRANSACTIONS
```

---

## Error Handling

| Scenario                           | Behaviour                                             |
|------------------------------------|-------------------------------------------------------|
| RAW ingest failure                 | Abort entire taskflow — no partial loads              |
| CDQ reject rate > 10%              | Fail quality task and abort — data quality breach     |
| Individual rejects within threshold | Route to ERROR.REJECT_RECORDS, continue              |
| Curated load failure               | Abort — never load a partial dimension                |

---

## Parameter File Example

```
$$SOURCE_DIR=/data/inbound/banking/
$$SOURCE_FILE_CUSTOMERS=customers_cdc_delta_20240320.csv
$$SOURCE_FILE_TXN=transactions_20240320.csv
$$LOAD_DATE=2024-03-20
$$PIPELINE_RUN_ID=RUN-20240320-001
$$SF_CONNECTION=SNOWFLAKE_BANKING_CONN
```

**Why parameterization matters:**
The same taskflow runs every day with zero code changes. The scheduler passes `$$LOAD_DATE` and the CDI parameter set resolves all filenames and connection names dynamically. One taskflow definition, 365 daily runs, no manual edits — this is what production-grade IDMC design looks like.
