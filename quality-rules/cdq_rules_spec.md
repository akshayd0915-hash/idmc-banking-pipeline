# Informatica CDQ — Data Quality Rules
## IDMC Banking Pipeline

All rules are configured in Informatica CDQ (Cloud Data Quality).
Failed records are routed to `ERROR.REJECT_RECORDS` with a structured reject reason.
No records are silently dropped.

---

## Rule Set: RLS_CUSTOMER_QUALITY

Applied to: `BANKING_DW.RAW.CUSTOMERS` (current pipeline run)

| Rule ID | Rule Name             | Field(s)              | CDQ Rule Type   | Condition / Pattern                                    | Action on Fail | Reject Reason Code    |
|---------|-----------------------|-----------------------|-----------------|--------------------------------------------------------|----------------|-----------------------|
| CQ-001  | Customer ID not null  | CUSTOMER_ID           | Null Check      | NOT NULL AND NOT EMPTY                                 | Reject         | NULL_CUSTOMER_ID      |
| CQ-002  | Email format valid    | EMAIL                 | Pattern Match   | `^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$`  | Reject         | INVALID_EMAIL_FORMAT  |
| CQ-003  | Email not null        | EMAIL                 | Null Check      | NOT NULL                                               | Reject         | NULL_EMAIL            |
| CQ-004  | KYC status domain     | KYC_STATUS            | Reference Table | IN ('APPROVED','PENDING','SUSPENDED','REJECTED')       | Reject         | INVALID_KYC_STATUS    |
| CQ-005  | Segment domain        | SEGMENT               | Reference Table | IN ('RETAIL','PRIVATE','BUSINESS','WEALTH')            | Reject         | INVALID_SEGMENT       |
| CQ-006  | CDC operation domain  | CDC_OPERATION         | Reference Table | IN ('INSERT','UPDATE','DELETE')                        | Flag (warn)    | INVALID_CDC_OPERATION |
| CQ-007  | Name fields not null  | FIRST_NAME, LAST_NAME | Null Check      | BOTH not null                                          | Reject         | NULL_NAME_FIELDS      |
| CQ-008  | KYC date not future   | KYC_DATE              | Date Range      | KYC_DATE <= CURRENT_DATE()                             | Reject         | FUTURE_KYC_DATE       |

**Reject threshold:** >10% reject rate → fail the CDQ task and abort taskflow

---

## Reject Record Structure (ERROR.REJECT_RECORDS)

Each failed record is written to the error table with:
- `PIPELINE_RUN_ID` — ties back to the run log
- `SOURCE_ENTITY` — which entity failed (CUSTOMERS)
- `BUSINESS_KEY` — the CUSTOMER_ID of the bad record
- `REJECT_REASON` — the rule ID + reject reason code + field value that failed
- `RAW_RECORD` — full raw record stored as VARIANT (JSON) for reprocessing

### Example reject reason format

```
CQ-002 | INVALID_EMAIL_FORMAT | EMAIL='george.patel@invalidomain'
CQ-004 | INVALID_KYC_STATUS   | KYC_STATUS='UNKNOWN' | CUSTOMER_ID='C007'
```

---

## Why IDMC CDQ over Snowflake SQL for Data Quality

| Approach              | Snowflake SQL CASE/WHEN               | Informatica CDQ                       |
|-----------------------|---------------------------------------|---------------------------------------|
| Rule reusability      | Hardcoded per pipeline                | Reusable rule sets across pipelines   |
| Governance visibility | Not tracked in lineage                | Rules tracked in CDGC lineage catalog |
| Business user access  | Requires SQL knowledge                | CDQ has no-code rule builder          |
| Reject routing        | Manual UNION / CTE logic              | Native routing to reject target       |
| Profiling             | Manual COUNT/GROUP queries            | CDQ profiling runs automatically      |
| Audit trail           | Custom logging tables                 | Built-in CDQ audit dashboard          |

This distinction is a core design principle — quality is enforced in Informatica, not delegated to Snowflake.
