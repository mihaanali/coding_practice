/*
================================================================================
  CLAIMS PROCESSING LOGIC FOR [Prominence].[dbo].[ClaimDetails]
================================================================================

  PURPOSE:  Determine the FINAL, deduplicated, financially accurate state of
            every claim. The raw table is a transaction log — it contains
            originals, adjustments, reversals, voids, pended claims, header-only
            rows, and mixed line statuses. These queries resolve all of that.

  DATA FINDINGS FROM SAMPLE ANALYSIS:
  ------------------------------------
  1. ClaimStatus has 10 values:  PAY, PAID, DENY, DENIED, PEND, VOID, REV, OPEN, WAITPAY, WAITDENY
  2. PAY vs PAID:  PAY = adjudicated but no PaidDate yet.  PAID = adjudicated AND PaidDate populated.
     DENY vs DENIED:  Same pattern. DENY = no PaidDate.  DENIED = PaidDate populated (even though denied).
     Both pairs represent the same outcome; the suffix difference tracks payment processing state.
  3. PEND claims can have lines with OKAY status and even positive amountpaid — these are
     partially adjudicated multi-line claims where some lines are decided but the header is still pending.
  4. REV = Reversal. Negative billed/paid amounts that offset a prior claim.
  5. VOID = Cancelled claim. Amounts zeroed out.
  6. OPEN / WAITPAY / WAITDENY = Intermediate processing states (FinalizedClaim = Y but still in workflow).
  7. FinalizedClaim = 'Y' on ALL rows in sample — not a reliable filter for "truly final."
  8. MasterClaimId_hash = claimid_hash for originals; different for adjustments.
     orgclaimid_hash points back to the original claim being adjusted.
  9. ClaimLevelOnly = 'Y' rows carry header-level aggregates. Multi-line claims
     may have BOTH header-only and detail rows — never sum them together.
  10. conteligamt = claimamt_or_Charges (billed) in most cases — it's the contract-eligible submitted amount.
  11. paydiscount is almost always 0 — the contractual write-off is implicit (billed - allowed).
  12. costshareamt is almost always 0 — member cost-sharing is tracked in copay, coinsuranceamt, Deductible separately.
  13. The gap between AllowedAmt and (amountpaid + memamt) on Medicare Advantage claims is exactly 2%
      of allowed — this is the Medicare Sequestration reduction.
  14. Financial equation:  AllowedAmt ≈ amountpaid + copay + coinsuranceamt + Deductible + COB + sequestration

  CLAIM STATUS STATE MACHINE:
  ---------------------------
     OPEN ──> PEND ──> PAY ──> PAID       (happy path)
                   ──> DENY ──> DENIED    (denial path)
                   ──> VOID               (cancellation)
                   ──> REV                (reversal of prior payment)
              WAITPAY ──> PAID            (pending payment release)
              WAITDENY ──> DENIED         (pending denial finalization)
================================================================================
*/


-- ============================================================================
-- STEP 0: STATUS NORMALIZATION
-- ============================================================================
-- PAY/PAID and DENY/DENIED are the same adjudication outcome.
-- Normalize them for consistent processing.

-- This CTE is reused throughout all downstream queries.

/*
    Normalized Status Mapping:
    PAY, PAID         --> 'PAID'       (claim approved for payment)
    DENY, DENIED      --> 'DENIED'     (claim denied)
    PEND              --> 'PEND'       (still in adjudication)
    VOID              --> 'VOID'       (cancelled)
    REV               --> 'REVERSED'   (payment reversal)
    OPEN              --> 'OPEN'       (received, not yet adjudicated)
    WAITPAY           --> 'WAITPAY'    (approved, waiting for payment release)
    WAITDENY          --> 'WAITDENY'   (denied, waiting for finalization)

    Normalized Line Status Mapping:
    OKAY, WARN        --> 'APPROVED'   (line approved / approved with warning)
    DENY              --> 'DENIED'     (line denied)
    PEND              --> 'PEND'       (line pending)
    VOID              --> 'VOID'       (line voided)
    '' / NULL         --> 'UNKNOWN'    (no line status — typically header-only rows)
*/


-- ============================================================================
-- STEP 1: BASE PROCESSING VIEW
-- ============================================================================
-- This is your foundation. Every downstream query should use this view
-- instead of the raw table.

CREATE VIEW vw_ClaimDetails_Normalized AS
SELECT
    *,

    -- Normalized Claim Status
    CASE
        WHEN ClaimStatus IN ('PAY', 'PAID')   THEN 'PAID'
        WHEN ClaimStatus IN ('DENY', 'DENIED') THEN 'DENIED'
        WHEN ClaimStatus = 'REV'               THEN 'REVERSED'
        WHEN ClaimStatus = 'VOID'              THEN 'VOID'
        WHEN ClaimStatus = 'PEND'              THEN 'PEND'
        WHEN ClaimStatus = 'OPEN'              THEN 'OPEN'
        WHEN ClaimStatus = 'WAITPAY'           THEN 'WAITPAY'
        WHEN ClaimStatus = 'WAITDENY'          THEN 'WAITDENY'
        ELSE ClaimStatus
    END AS NormalizedClaimStatus,

    -- Normalized Line Status
    CASE
        WHEN ClaimLineStatus IN ('OKAY', 'WARN') THEN 'APPROVED'
        WHEN ClaimLineStatus = 'DENY'             THEN 'DENIED'
        WHEN ClaimLineStatus = 'PEND'             THEN 'PEND'
        WHEN ClaimLineStatus = 'VOID'             THEN 'VOID'
        WHEN ClaimLineStatus IS NULL
             OR ClaimLineStatus = ''               THEN 'UNKNOWN'
        ELSE ClaimLineStatus
    END AS NormalizedLineStatus,

    -- Is this the original claim or an adjustment/replacement?
    CASE
        WHEN MasterClaimId = claimid THEN 'ORIGINAL'
        ELSE 'ADJUSTMENT'
    END AS ClaimRole,

    -- Is the claim in a terminal state (no more changes expected)?
    CASE
        WHEN ClaimStatus IN ('PAY', 'PAID', 'DENY', 'DENIED', 'VOID', 'REV') THEN 1
        ELSE 0
    END AS IsTerminalStatus,

    -- Has this claim been superseded by an adjustment?
    -- (If another claim references this one as its orgclaimid, this one is superseded)
    CASE
        WHEN EXISTS (
            SELECT 1 FROM [Prominence].[dbo].[ClaimDetails] adj
            WHERE adj.orgclaimid = cd.claimid
              AND adj.claimid <> cd.claimid
        ) THEN 1
        ELSE 0
    END AS IsSuperseded,

    -- Calculated: implicit contractual write-off (billed - allowed)
    ISNULL(claimamt_or_Charges, 0) - ISNULL(AllowedAmt_or_ContractPaid, 0) AS ImpliedContractualDiscount,

    -- Calculated: Medicare sequestration amount (2% of allowed for MA claims)
    CASE
        WHEN Company = 'MEDICARE ADVANTAGE'
         AND ISNULL(AllowedAmt_or_ContractPaid, 0) > 0
         AND ISNULL(amountpaid, 0) > 0
        THEN ROUND(AllowedAmt_or_ContractPaid * 0.02, 2)
        ELSE 0
    END AS EstimatedSequestration

FROM [Prominence].[dbo].[ClaimDetails] cd;
GO


-- ============================================================================
-- STEP 2: FINAL CLAIM STATE — One Row Per Claim-Line (Deduplicated)
-- ============================================================================
-- Two types of duplication exist and must be handled in order:
--
--   TYPE 1 — SNAPSHOT DUPLICATES: The same claim+line loaded in multiple
--            Dataset batches as its status evolves (PEND→PAY→PAID).
--            These have the SAME claimid+claimline but different Dataset values.
--            Resolution: keep the row from the latest Dataset.
--
--   TYPE 2 — ADJUSTMENT CHAINS: A corrected claim replaces the original.
--            These have DIFFERENT claimid values sharing the same MasterClaimId.
--            Resolution: keep the adjustment, discard the original.
--
-- Both are handled in a single ROW_NUMBER. The PARTITION is by
-- (MasterClaimId, claimline) which captures both cases.
--
-- WHY Dataset IS a tiebreaker in ORDER BY (and NOT in PARTITION BY):
--   - Dataset in PARTITION BY would prevent deduplication (each batch becomes
--     its own group). NEVER do this.
--   - Dataset in ORDER BY (last position) safely resolves ties when timestamps
--     are identical. The later batch (higher Dataset value) has the more
--     current status.
--   - Related claims (original + adjustment) have DIFFERENT claimid/claimline
--     values, so they're in SEPARATE partitions. The ROW_NUMBER can never
--     accidentally filter out a related claim from an earlier Dataset.
--
-- IMPORTANT: The adjustment row REPLACES the original. Do NOT sum them.

CREATE VIEW vw_FinalClaimState AS
WITH RankedClaims AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY MasterClaimId, claimline
            ORDER BY
                -- Primary: prefer the most recent version by timestamps
                ClaimDetailLastUpdate DESC,
                ClaimLastUpdate DESC,
                createdate DESC,
                -- Secondary: prefer adjustments over originals
                CASE WHEN MasterClaimId = claimid THEN 1 ELSE 0 END ASC,
                -- Final tiebreaker: later Dataset batch wins when timestamps match.
                -- Dataset format is DYYMMDD so lexicographic sort = chronological.
                -- DO NOT move this to PARTITION BY — that would break deduplication.
                Dataset DESC
        ) AS rn
    FROM [Prominence].[dbo].[ClaimDetails]
    WHERE ClaimStatus NOT IN ('VOID', 'REV')  -- exclude cancelled/reversed entirely
      AND (ClaimLevelOnly IS NULL OR ClaimLevelOnly = '' OR ClaimLevelOnly = '0')
        -- exclude header-only aggregates to avoid double-counting
)
SELECT
    MasterClaimId,
    claimid,
    orgclaimid,
    claimline,
    CASE WHEN MasterClaimId = claimid THEN 'ORIGINAL' ELSE 'ADJUSTMENT' END AS ClaimRole,

    -- Normalized statuses
    CASE
        WHEN ClaimStatus IN ('PAY', 'PAID')    THEN 'PAID'
        WHEN ClaimStatus IN ('DENY', 'DENIED') THEN 'DENIED'
        WHEN ClaimStatus = 'PEND'              THEN 'PEND'
        WHEN ClaimStatus = 'OPEN'              THEN 'OPEN'
        WHEN ClaimStatus = 'WAITPAY'           THEN 'WAITPAY'
        WHEN ClaimStatus = 'WAITDENY'          THEN 'WAITDENY'
        ELSE ClaimStatus
    END AS FinalClaimStatus,

    CASE
        WHEN ClaimLineStatus IN ('OKAY', 'WARN') THEN 'APPROVED'
        WHEN ClaimLineStatus = 'DENY'             THEN 'DENIED'
        WHEN ClaimLineStatus = 'PEND'             THEN 'PEND'
        WHEN ClaimLineStatus = 'VOID'             THEN 'VOID'
        ELSE 'UNKNOWN'
    END AS FinalLineStatus,

    ClaimStatus        AS RawClaimStatus,
    ClaimLineStatus    AS RawLineStatus,

    -- Key identifiers
    memid,
    RenderingProviderNPI,
    RenderingProvider,
    ProviderParStatus,

    -- Service info
    ClaimType,
    servcode,
    modcode,
    PosCode,
    revcode,
    drg,
    PrinDiag,
    TypeOfBill,

    -- Dates
    StartServiceDate,
    EndServiceDate,
    DOSFrom_ClaimLine,
    DOSTo_ClaimLine,
    admitdate,
    dischargedate,
    PaidDate,
    adjuddate,
    createdate,
    logdate,

    -- Financials (these are the FINAL amounts for this claim-line)
    ISNULL(claimamt_or_Charges, 0)        AS FinalBilledAmount,
    ISNULL(AllowedAmt_or_ContractPaid, 0) AS FinalAllowedAmount,
    ISNULL(amountpaid, 0)                 AS FinalPaidAmount,
    ISNULL(copay, 0)                      AS FinalCopay,
    ISNULL(coinsuranceamt, 0)             AS FinalCoinsurance,
    ISNULL(Deductible, 0)                 AS FinalDeductible,
    ISNULL(memamt, 0)                     AS FinalMemberAmount,
    ISNULL(COB_or_extpaidAmt, 0)          AS FinalCOBAmount,
    ISNULL(costshareamt, 0)               AS FinalCostShare,

    -- Calculated
    ISNULL(claimamt_or_Charges, 0) - ISNULL(AllowedAmt_or_ContractPaid, 0) AS ContractualDiscount,
    ISNULL(copay, 0) + ISNULL(coinsuranceamt, 0) + ISNULL(Deductible, 0)  AS CalcMemberResponsibility,
    ISNULL(amountpaid, 0) + ISNULL(copay, 0) + ISNULL(coinsuranceamt, 0)
        + ISNULL(Deductible, 0) + ISNULL(COB_or_extpaidAmt, 0)            AS CalcTotalAccountedFor,

    -- Plan & benefit
    Company,
    ProgramName,
    LOB,
    benefitplan,
    benefitName,
    CapitatedClaim,
    contractid,

    -- Pend info
    HeaderLevelPendRuleId,
    HeaderLevelPendRuleDescription,
    LineLevelPendRuleId,
    LineLevelPendRuleDescription,

    -- Metadata
    SourceSystem,
    Dataset,
    ServicePeriod,
    PaidPeriod

FROM RankedClaims
WHERE rn = 1;
GO


-- ============================================================================
-- STEP 3: HANDLING VOIDS AND REVERSALS — Net Effect View
-- ============================================================================
-- Voids and Reversals don't disappear — they zero out a prior claim.
-- This view shows the net financial effect per MasterClaimId.
-- Use this when you need to see the FULL history including cancellations.

CREATE VIEW vw_ClaimNetEffect AS
SELECT
    MasterClaimId,
    claimline,
    memid,
    RenderingProviderNPI,
    servcode,
    StartServiceDate,
    EndServiceDate,

    COUNT(*)                                      AS VersionCount,
    MAX(ClaimStatus)                              AS LatestRawStatus,
    MAX(CASE WHEN ClaimStatus IN ('VOID','REV') THEN 1 ELSE 0 END) AS WasVoidedOrReversed,

    SUM(ISNULL(claimamt_or_Charges, 0))           AS NetBilledAmount,
    SUM(ISNULL(AllowedAmt_or_ContractPaid, 0))    AS NetAllowedAmount,
    SUM(ISNULL(amountpaid, 0))                    AS NetPaidAmount,
    SUM(ISNULL(copay, 0))                         AS NetCopay,
    SUM(ISNULL(coinsuranceamt, 0))                AS NetCoinsurance,
    SUM(ISNULL(Deductible, 0))                    AS NetDeductible,
    SUM(ISNULL(COB_or_extpaidAmt, 0))             AS NetCOBAmount

FROM [Prominence].[dbo].[ClaimDetails]
WHERE ClaimLevelOnly IS NULL OR ClaimLevelOnly = '' OR ClaimLevelOnly = '0'
GROUP BY
    MasterClaimId, claimline, memid,
    RenderingProviderNPI, servcode,
    StartServiceDate, EndServiceDate;
GO


-- ============================================================================
-- STEP 4: FINANCIAL RECONCILIATION CHECK
-- ============================================================================
-- Validates that the financial equation balances for paid claims.
-- Identifies rows where the math doesn't add up so you can investigate.

-- EQUATION:
--   AllowedAmt = PlanPaid + Copay + Coinsurance + Deductible + COB + Sequestration
--
-- Note: For Medicare Advantage claims, a 2% sequestration gap is expected.
--       For non-MA claims, the equation should balance within $0.50.

SELECT
    claimid,
    claimline,
    ClaimStatus,
    ClaimLineStatus,
    Company,

    claimamt_or_Charges                        AS Billed,
    AllowedAmt_or_ContractPaid                 AS Allowed,
    amountpaid                                 AS PlanPaid,
    copay                                      AS Copay,
    coinsuranceamt                             AS Coinsurance,
    Deductible                                 AS Deductible,
    COB_or_extpaidAmt                          AS COB,

    -- What we can account for
    ISNULL(amountpaid, 0)
        + ISNULL(copay, 0)
        + ISNULL(coinsuranceamt, 0)
        + ISNULL(Deductible, 0)
        + ISNULL(COB_or_extpaidAmt, 0)         AS TotalAccountedFor,

    -- The gap (unaccounted)
    ISNULL(AllowedAmt_or_ContractPaid, 0)
        - ISNULL(amountpaid, 0)
        - ISNULL(copay, 0)
        - ISNULL(coinsuranceamt, 0)
        - ISNULL(Deductible, 0)
        - ISNULL(COB_or_extpaidAmt, 0)         AS UnaccountedGap,

    -- Expected sequestration (2% of allowed for MA)
    CASE
        WHEN Company = 'MEDICARE ADVANTAGE'
        THEN ROUND(AllowedAmt_or_ContractPaid * 0.02, 2)
        ELSE 0
    END                                         AS ExpectedSequestration,

    -- Gap after removing sequestration
    ISNULL(AllowedAmt_or_ContractPaid, 0)
        - ISNULL(amountpaid, 0)
        - ISNULL(copay, 0)
        - ISNULL(coinsuranceamt, 0)
        - ISNULL(Deductible, 0)
        - ISNULL(COB_or_extpaidAmt, 0)
        - CASE WHEN Company = 'MEDICARE ADVANTAGE'
               THEN ROUND(AllowedAmt_or_ContractPaid * 0.02, 2)
               ELSE 0
          END                                   AS GapAfterSequestration,

    -- Verdict
    CASE
        WHEN ISNULL(AllowedAmt_or_ContractPaid, 0) = 0 THEN 'NO_ALLOWED'
        WHEN ABS(
            ISNULL(AllowedAmt_or_ContractPaid, 0)
            - ISNULL(amountpaid, 0) - ISNULL(copay, 0)
            - ISNULL(coinsuranceamt, 0) - ISNULL(Deductible, 0)
            - ISNULL(COB_or_extpaidAmt, 0)
        ) < 0.50 THEN 'BALANCED'
        WHEN Company = 'MEDICARE ADVANTAGE'
         AND ABS(
            ISNULL(AllowedAmt_or_ContractPaid, 0)
            - ISNULL(amountpaid, 0) - ISNULL(copay, 0)
            - ISNULL(coinsuranceamt, 0) - ISNULL(Deductible, 0)
            - ISNULL(COB_or_extpaidAmt, 0)
            - ROUND(AllowedAmt_or_ContractPaid * 0.02, 2)
        ) < 0.50 THEN 'BALANCED_WITH_SEQUESTRATION'
        WHEN ISNULL(amountpaid, 0) = 0
         AND ISNULL(AllowedAmt_or_ContractPaid, 0) > 0
        THEN 'ALLOWED_BUT_ZERO_PAID'
        ELSE 'UNBALANCED'
    END AS ReconciliationVerdict

FROM [Prominence].[dbo].[ClaimDetails]
WHERE ClaimStatus IN ('PAY', 'PAID')
  AND ClaimLineStatus IN ('OKAY', 'WARN')
  AND (ClaimLevelOnly IS NULL OR ClaimLevelOnly = '' OR ClaimLevelOnly = '0')
ORDER BY
    CASE
        WHEN ABS(ISNULL(AllowedAmt_or_ContractPaid,0) - ISNULL(amountpaid,0)
             - ISNULL(copay,0) - ISNULL(coinsuranceamt,0) - ISNULL(Deductible,0)
             - ISNULL(COB_or_extpaidAmt,0)) > 0.50 THEN 0 ELSE 1
    END,
    ABS(ISNULL(AllowedAmt_or_ContractPaid,0) - ISNULL(amountpaid,0)) DESC;


-- ============================================================================
-- STEP 5: CLAIM-LEVEL FINANCIAL SUMMARY (Aggregated from lines)
-- ============================================================================
-- Rolls up line-level amounts to get ONE row per claim with total financials.
-- Uses vw_FinalClaimState so it's already deduplicated.

SELECT
    MasterClaimId,
    claimid,
    FinalClaimStatus,
    memid,
    RenderingProviderNPI,
    RenderingProvider,
    Company,
    LOB,
    ClaimType,
    PrinDiag,
    StartServiceDate,
    EndServiceDate,
    PaidDate,

    COUNT(*)                            AS LineCount,
    SUM(CASE WHEN FinalLineStatus = 'APPROVED' THEN 1 ELSE 0 END) AS ApprovedLines,
    SUM(CASE WHEN FinalLineStatus = 'DENIED'   THEN 1 ELSE 0 END) AS DeniedLines,
    SUM(CASE WHEN FinalLineStatus = 'PEND'     THEN 1 ELSE 0 END) AS PendingLines,

    SUM(FinalBilledAmount)              AS TotalBilled,
    SUM(FinalAllowedAmount)             AS TotalAllowed,
    SUM(FinalPaidAmount)                AS TotalPaid,
    SUM(FinalCopay)                     AS TotalCopay,
    SUM(FinalCoinsurance)               AS TotalCoinsurance,
    SUM(FinalDeductible)                AS TotalDeductible,
    SUM(FinalMemberAmount)              AS TotalMemberAmount,
    SUM(FinalCOBAmount)                 AS TotalCOB,
    SUM(ContractualDiscount)            AS TotalContractualDiscount,

    -- What percentage of billed was allowed?
    CASE WHEN SUM(FinalBilledAmount) > 0
         THEN ROUND(SUM(FinalAllowedAmount) / SUM(FinalBilledAmount) * 100, 1)
         ELSE 0
    END AS AllowedPctOfBilled,

    -- What percentage of allowed was paid by plan?
    CASE WHEN SUM(FinalAllowedAmount) > 0
         THEN ROUND(SUM(FinalPaidAmount) / SUM(FinalAllowedAmount) * 100, 1)
         ELSE 0
    END AS PaidPctOfAllowed

FROM vw_FinalClaimState
GROUP BY
    MasterClaimId, claimid, FinalClaimStatus,
    memid, RenderingProviderNPI, RenderingProvider,
    Company, LOB, ClaimType, PrinDiag,
    StartServiceDate, EndServiceDate, PaidDate;


-- ============================================================================
-- STEP 6: DETERMINE FINAL CHARGE — THE ANSWER TO YOUR QUESTION
-- ============================================================================
-- "What is the final, settled amount for each claim, regardless of status?"
--
-- This is the definitive financial summary per unique claim occurrence.
-- It handles every scenario: paid, denied, voided, reversed, pending, partial.

SELECT
    MasterClaimId,
    memid,
    RenderingProviderNPI,
    StartServiceDate,
    EndServiceDate,

    -- Overall claim disposition
    CASE
        -- If the latest version is VOID or REV, the entire claim is cancelled
        WHEN MAX(CASE WHEN rn = 1 AND ClaimStatus IN ('VOID', 'REV') THEN 1 ELSE 0 END) = 1
            THEN 'CANCELLED'

        -- If all non-void/rev lines are denied
        WHEN SUM(CASE WHEN ClaimStatus NOT IN ('VOID', 'REV')
                       AND ClaimLineStatus IN ('OKAY', 'WARN') THEN 1 ELSE 0 END) = 0
         AND SUM(CASE WHEN ClaimStatus NOT IN ('VOID', 'REV')
                       AND ClaimLineStatus = 'DENY' THEN 1 ELSE 0 END) > 0
            THEN 'FULLY_DENIED'

        -- If some lines approved, some denied
        WHEN SUM(CASE WHEN ClaimStatus NOT IN ('VOID', 'REV')
                       AND ClaimLineStatus IN ('OKAY', 'WARN') THEN 1 ELSE 0 END) > 0
         AND SUM(CASE WHEN ClaimStatus NOT IN ('VOID', 'REV')
                       AND ClaimLineStatus = 'DENY' THEN 1 ELSE 0 END) > 0
            THEN 'PARTIALLY_DENIED'

        -- Still pending
        WHEN MAX(CASE WHEN ClaimStatus IN ('PEND', 'OPEN', 'WAITPAY', 'WAITDENY')
                      THEN 1 ELSE 0 END) = 1
            THEN 'PENDING'

        -- All approved
        ELSE 'FULLY_APPROVED'
    END AS FinalDisposition,

    -- Is this claim fully settled (no pending lines)?
    CASE
        WHEN MAX(CASE WHEN ClaimStatus IN ('PEND', 'OPEN', 'WAITPAY', 'WAITDENY')
                       AND ClaimLineStatus IN ('PEND', 'OKAY', 'WARN')
                      THEN 1 ELSE 0 END) = 1
        THEN 'NO'
        ELSE 'YES'
    END AS IsFullySettled,

    -- FINAL FINANCIAL AMOUNTS (these are your definitive numbers)
    SUM(ISNULL(claimamt_or_Charges, 0))                       AS FinalBilledAmount,
    SUM(ISNULL(AllowedAmt_or_ContractPaid, 0))                AS FinalAllowedAmount,
    SUM(ISNULL(amountpaid, 0))                                AS FinalPlanPaidAmount,
    SUM(ISNULL(copay, 0) + ISNULL(coinsuranceamt, 0)
        + ISNULL(Deductible, 0))                              AS FinalMemberResponsibility,
    SUM(ISNULL(copay, 0))                                     AS FinalCopay,
    SUM(ISNULL(coinsuranceamt, 0))                            AS FinalCoinsurance,
    SUM(ISNULL(Deductible, 0))                                AS FinalDeductible,
    SUM(ISNULL(COB_or_extpaidAmt, 0))                         AS FinalCOB,
    SUM(ISNULL(claimamt_or_Charges, 0))
        - SUM(ISNULL(AllowedAmt_or_ContractPaid, 0))          AS FinalContractualWriteOff,

    -- Total dollars accounted for (should ≈ AllowedAmt for balanced claims)
    SUM(ISNULL(amountpaid, 0) + ISNULL(copay, 0)
        + ISNULL(coinsuranceamt, 0) + ISNULL(Deductible, 0)
        + ISNULL(COB_or_extpaidAmt, 0))                      AS TotalAccountedFor,

    -- Unaccounted gap (sequestration, rounding, or data issues)
    SUM(ISNULL(AllowedAmt_or_ContractPaid, 0))
        - SUM(ISNULL(amountpaid, 0) + ISNULL(copay, 0)
              + ISNULL(coinsuranceamt, 0) + ISNULL(Deductible, 0)
              + ISNULL(COB_or_extpaidAmt, 0))                AS UnaccountedGap,

    COUNT(*)                                                  AS TotalLines,
    SUM(CASE WHEN ClaimLineStatus IN ('OKAY','WARN') THEN 1 ELSE 0 END) AS ApprovedLines,
    SUM(CASE WHEN ClaimLineStatus = 'DENY' THEN 1 ELSE 0 END)           AS DeniedLines,
    SUM(CASE WHEN ClaimLineStatus = 'PEND' THEN 1 ELSE 0 END)           AS PendingLines

FROM (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY MasterClaimId, claimline
            ORDER BY ClaimDetailLastUpdate DESC, ClaimLastUpdate DESC, createdate DESC,
                     CASE WHEN MasterClaimId = claimid THEN 1 ELSE 0 END ASC,
                     Dataset DESC
        ) AS rn
    FROM [Prominence].[dbo].[ClaimDetails]
    WHERE (ClaimLevelOnly IS NULL OR ClaimLevelOnly = '' OR ClaimLevelOnly = '0')
) ranked
WHERE rn = 1
GROUP BY
    MasterClaimId, memid, RenderingProviderNPI,
    StartServiceDate, EndServiceDate;


-- ============================================================================
-- STEP 7: PEND INVENTORY — Claims Requiring Action
-- ============================================================================

SELECT
    claimid,
    claimline,
    ClaimStatus,
    ClaimLineStatus,
    memid,
    RenderingProvider,
    RenderingProviderNPI,
    servcode,
    PrinDiag,
    StartServiceDate,
    claimamt_or_Charges                     AS BilledAmount,
    AllowedAmt_or_ContractPaid              AS AllowedAmount,
    amountpaid                              AS PaidSoFar,

    HeaderLevelPendRuleId,
    HeaderLevelPendRuleDescription,
    LineLevelPendRuleId,
    LineLevelPendRuleDescription,

    logdate,
    DATEDIFF(DAY, CAST(logdate AS DATE), GETDATE()) AS DaysSinceReceived,

    CASE
        WHEN DATEDIFF(DAY, CAST(logdate AS DATE), GETDATE()) > 30
        THEN 'OVERDUE'
        ELSE 'WITHIN_SLA'
    END AS TimelinessSLA

FROM [Prominence].[dbo].[ClaimDetails]
WHERE ClaimStatus = 'PEND'
  AND (ClaimLevelOnly IS NULL OR ClaimLevelOnly = '' OR ClaimLevelOnly = '0')
ORDER BY
    DATEDIFF(DAY, CAST(logdate AS DATE), GETDATE()) DESC;


-- ============================================================================
-- STEP 8: EXECUTIVE SUMMARY DASHBOARD QUERY
-- ============================================================================

WITH FinalClaims AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY MasterClaimId, claimline
            ORDER BY ClaimDetailLastUpdate DESC, ClaimLastUpdate DESC, createdate DESC,
                     CASE WHEN MasterClaimId = claimid THEN 1 ELSE 0 END ASC,
                     Dataset DESC
        ) AS rn
    FROM [Prominence].[dbo].[ClaimDetails]
    WHERE (ClaimLevelOnly IS NULL OR ClaimLevelOnly = '' OR ClaimLevelOnly = '0')
)
SELECT
    -- Status category
    CASE
        WHEN ClaimStatus IN ('PAY','PAID')    THEN 'PAID'
        WHEN ClaimStatus IN ('DENY','DENIED') THEN 'DENIED'
        WHEN ClaimStatus = 'PEND'             THEN 'PENDING'
        WHEN ClaimStatus IN ('VOID','REV')    THEN 'CANCELLED'
        ELSE 'OTHER'
    END AS StatusCategory,

    Company,
    LOB,
    ClaimType,
    ServicePeriod,

    -- Counts
    COUNT(DISTINCT MasterClaimId)                               AS UniqueClaims,
    COUNT(*)                                                    AS TotalLines,

    -- Financials
    SUM(ISNULL(claimamt_or_Charges, 0))                         AS TotalBilled,
    SUM(ISNULL(AllowedAmt_or_ContractPaid, 0))                  AS TotalAllowed,
    SUM(ISNULL(amountpaid, 0))                                  AS TotalPlanPaid,
    SUM(ISNULL(copay, 0) + ISNULL(coinsuranceamt, 0)
        + ISNULL(Deductible, 0))                                AS TotalMemberResp,
    SUM(ISNULL(COB_or_extpaidAmt, 0))                           AS TotalCOB,
    SUM(ISNULL(claimamt_or_Charges, 0))
        - SUM(ISNULL(AllowedAmt_or_ContractPaid, 0))            AS TotalContractualDiscount,

    -- Ratios
    CASE WHEN SUM(ISNULL(claimamt_or_Charges, 0)) > 0
         THEN ROUND(SUM(ISNULL(AllowedAmt_or_ContractPaid, 0))
              / SUM(ISNULL(claimamt_or_Charges, 0)) * 100, 1)
    END AS AllowedToBilledPct,

    CASE WHEN SUM(ISNULL(AllowedAmt_or_ContractPaid, 0)) > 0
         THEN ROUND(SUM(ISNULL(amountpaid, 0))
              / SUM(ISNULL(AllowedAmt_or_ContractPaid, 0)) * 100, 1)
    END AS PaidToAllowedPct,

    -- Denial rate (by line count)
    ROUND(
        SUM(CASE WHEN ClaimLineStatus = 'DENY' THEN 1.0 ELSE 0 END)
        / NULLIF(COUNT(*), 0) * 100, 1
    ) AS DenialRatePct

FROM FinalClaims
WHERE rn = 1
GROUP BY
    CASE
        WHEN ClaimStatus IN ('PAY','PAID')    THEN 'PAID'
        WHEN ClaimStatus IN ('DENY','DENIED') THEN 'DENIED'
        WHEN ClaimStatus = 'PEND'             THEN 'PENDING'
        WHEN ClaimStatus IN ('VOID','REV')    THEN 'CANCELLED'
        ELSE 'OTHER'
    END,
    Company, LOB, ClaimType, ServicePeriod
ORDER BY StatusCategory, Company, ServicePeriod;


-- ============================================================================
-- STEP 9: QUICK REFERENCE — STATUS DECISION TREE
-- ============================================================================
/*
    Use this logic to determine how to treat each row:

    IF ClaimStatus IN ('VOID', 'REV'):
        --> IGNORE for financial reporting (net effect is $0)
        --> Keep for audit trail / history
        --> REV rows have NEGATIVE amounts that offset the original

    IF ClaimStatus = 'PEND':
        --> NOT finalized. Do NOT include in paid/denied totals.
        --> Some lines may have partial payments (ClaimLineStatus = 'OKAY' with amountpaid > 0)
        --> These partial amounts are real but the claim is not settled.
        --> Monitor in pend inventory (Step 7).

    IF ClaimStatus IN ('PAY', 'PAID'):
        --> Claim is approved. Use amountpaid as the plan payment.
        --> Lines with ClaimLineStatus = 'DENY' within a PAY/PAID claim are
            individual denied lines (partial denial). Their amountpaid = 0.
        --> Lines with ClaimLineStatus = 'OKAY' or 'WARN' are the approved lines.
        --> WARN lines are approved but flagged for review — still paid.
        --> PAY = approved but check not yet cut.  PAID = check cut and PaidDate populated.

    IF ClaimStatus IN ('DENY', 'DENIED'):
        --> Claim is denied. amountpaid = 0.
        --> DENY = denied but not yet finalized.  DENIED = denial finalized with PaidDate.

    IF ClaimStatus IN ('OPEN', 'WAITPAY', 'WAITDENY'):
        --> Intermediate states. Treat like PEND for reporting.
        --> OPEN = received, not yet in adjudication queue.
        --> WAITPAY = approved, waiting for payment processing.
        --> WAITDENY = denied, waiting for denial letter/finalization.

    DEDUPLICATION:
        --> Always use the LATEST version per (MasterClaimId, claimline).
        --> If MasterClaimId = claimid, it's the original.
        --> If MasterClaimId != claimid, it's an adjustment — USE THIS ONE, not the original.
        --> Never sum original + adjustment — the adjustment REPLACES the original.
        --> The same claim+line may appear in multiple Dataset batches (snapshot duplicates).
            The later Dataset has the more current status. Use Dataset as a final
            tiebreaker in ROW_NUMBER ORDER BY, NEVER in PARTITION BY.
        --> Related claims (original + adjustment) have DIFFERENT claimid and claimline
            values, so they sit in separate ROW_NUMBER partitions. The deduplication
            CANNOT accidentally filter out a related claim from an earlier Dataset.

    HEADER-ONLY ROWS (ClaimLevelOnly = 'Y'):
        --> Carry aggregated header amounts. Do NOT combine with detail rows.
        --> For multi-line claims: use either header-only rows OR detail rows, never both.
        --> Prefer detail rows (ClaimLevelOnly IS NULL or '') for granular analysis.
        --> Use header-only rows only when detail rows are missing.

    CAPITATED CLAIMS (CapitatedClaim = '1' or 'Y'):
        --> amountpaid will be $0 — this is NOT a denial.
        --> Provider is paid via monthly capitation, not fee-for-service.
        --> Exclude from denial rate calculations.
        --> Track CapitatedAmount separately for cost analysis.

    FINANCIAL EQUATION:
        Billed (claimamt_or_Charges)
          - Contractual Discount (billed - allowed; not in paydiscount)
          = Allowed (AllowedAmt_or_ContractPaid)
          = PlanPaid (amountpaid)
            + Copay (copay)
            + Coinsurance (coinsuranceamt)
            + Deductible (Deductible)
            + COB (COB_or_extpaidAmt)
            + Sequestration (2% of allowed, Medicare Advantage only)

        NOTE: paydiscount is NOT populated in this data. The write-off is
              implicit in the difference between billed and allowed.
        NOTE: costshareamt is NOT populated. Use copay + coinsuranceamt + Deductible instead.
        NOTE: conteligamt = billed amount (not useful for netting).
        NOTE: memamt tracks member responsibility but may differ from copay+coins+deduct sum.
*/


-- ============================================================================
-- STEP 10: COMPLETE FINAL CHARGES TABLE (MATERIALIZED)
-- ============================================================================
-- Use this to create a clean, final table for reporting.
-- Run this as a scheduled job to keep it current.

-- DROP TABLE IF EXISTS [Prominence].[dbo].[ClaimDetails_Final];

SELECT *
INTO [Prominence].[dbo].[ClaimDetails_Final]
FROM (
    SELECT
        fc.MasterClaimId,
        fc.claimid,
        fc.orgclaimid,
        fc.claimline,
        fc.ClaimRole,
        fc.FinalClaimStatus,
        fc.FinalLineStatus,
        fc.RawClaimStatus,
        fc.RawLineStatus,

        fc.memid,
        fc.RenderingProviderNPI,
        fc.RenderingProvider,
        fc.ProviderParStatus,
        fc.ClaimType,
        fc.servcode,
        fc.modcode,
        fc.PosCode,
        fc.revcode,
        fc.drg,
        fc.PrinDiag,
        fc.TypeOfBill,

        fc.StartServiceDate,
        fc.EndServiceDate,
        fc.DOSFrom_ClaimLine,
        fc.DOSTo_ClaimLine,
        fc.admitdate,
        fc.dischargedate,
        fc.PaidDate,
        fc.adjuddate,
        fc.createdate,
        fc.logdate,

        fc.FinalBilledAmount,
        fc.FinalAllowedAmount,
        fc.FinalPaidAmount,
        fc.FinalCopay,
        fc.FinalCoinsurance,
        fc.FinalDeductible,
        fc.FinalMemberAmount,
        fc.FinalCOBAmount,
        fc.ContractualDiscount,
        fc.CalcMemberResponsibility,
        fc.CalcTotalAccountedFor,

        -- Final settled amount (what the provider actually receives / is owed)
        CASE
            WHEN fc.FinalClaimStatus IN ('VOID', 'REVERSED', 'CANCELLED')
                THEN 0
            WHEN fc.FinalLineStatus = 'DENIED'
                THEN 0
            ELSE fc.FinalPaidAmount
        END AS SettledPlanPayment,

        -- Final member owes
        CASE
            WHEN fc.FinalClaimStatus IN ('VOID', 'REVERSED', 'CANCELLED')
                THEN 0
            WHEN fc.FinalLineStatus = 'DENIED'
                THEN 0
            ELSE fc.FinalCopay + fc.FinalCoinsurance + fc.FinalDeductible
        END AS SettledMemberOwes,

        -- Final total settled (plan + member)
        CASE
            WHEN fc.FinalClaimStatus IN ('VOID', 'REVERSED', 'CANCELLED')
                THEN 0
            WHEN fc.FinalLineStatus = 'DENIED'
                THEN 0
            ELSE fc.FinalPaidAmount + fc.FinalCopay + fc.FinalCoinsurance + fc.FinalDeductible
        END AS SettledTotalAmount,

        -- Is this row usable for financial reporting?
        CASE
            WHEN fc.FinalClaimStatus IN ('PAID', 'DENIED') THEN 'YES'
            WHEN fc.FinalClaimStatus = 'PEND'              THEN 'PARTIAL'
            ELSE 'NO'
        END AS IsReportable,

        fc.Company,
        fc.ProgramName,
        fc.LOB,
        fc.benefitplan,
        fc.benefitName,
        fc.CapitatedClaim,
        fc.contractid,
        fc.SourceSystem,
        fc.Dataset,
        fc.ServicePeriod,
        fc.PaidPeriod,

        fc.HeaderLevelPendRuleDescription,
        fc.LineLevelPendRuleDescription,

        GETDATE() AS ProcessedDate

    FROM vw_FinalClaimState fc
) final_data;

-- Add indexes for common query patterns
CREATE INDEX IX_Final_MasterClaim   ON [Prominence].[dbo].[ClaimDetails_Final] (MasterClaimId);
CREATE INDEX IX_Final_Status        ON [Prominence].[dbo].[ClaimDetails_Final] (FinalClaimStatus, FinalLineStatus);
CREATE INDEX IX_Final_Member        ON [Prominence].[dbo].[ClaimDetails_Final] (memid);
CREATE INDEX IX_Final_ServiceDate   ON [Prominence].[dbo].[ClaimDetails_Final] (StartServiceDate);
CREATE INDEX IX_Final_Provider      ON [Prominence].[dbo].[ClaimDetails_Final] (RenderingProviderNPI);
CREATE INDEX IX_Final_Reportable    ON [Prominence].[dbo].[ClaimDetails_Final] (IsReportable, FinalClaimStatus);
