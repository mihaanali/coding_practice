# X12 EDI Claims Mapping & Adjudication Guide

## Overview

This document maps every column in `[Prominence].[dbo].[ClaimDetails]` to its X12 EDI origin and provides a complete explanation of how healthcare claims are adjudicated.

The table is a **flattened representation** of data originating from two X12 EDI healthcare transactions:

| Transaction | Name | Direction | Purpose |
|---|---|---|---|
| **837** | Healthcare Claim | Provider → Payer | Submitted by providers to request payment for services |
| **835** | Electronic Remittance Advice (ERA) | Payer → Provider | Sent back by payers showing what was paid, denied, or adjusted |

The 837 comes in three flavors:
- **837P** — Professional claims (physician/outpatient, maps to CMS-1500 paper form)
- **837I** — Institutional claims (hospital/facility, maps to UB-04 paper form)
- **837D** — Dental claims

Your payor converted their X12 EDI files into this tabular format using an EDI converter (such as [datainsight.health/edi/viewer](https://datainsight.health/edi/viewer/)). The [X12 examples](https://x12.org/examples) site provides sample transactions for reference.

---

## Table of Contents

1. [Claim Identification & Status](#1-claim-identification--status)
2. [Organization, Program & Plan](#2-organization-program--plan)
3. [Provider Information](#3-provider-information)
4. [Member / Subscriber / Enrollment](#4-member--subscriber--enrollment)
5. [Service & Clinical Information](#5-service--clinical-information)
6. [Diagnosis Codes](#6-diagnosis-codes)
7. [ICD Procedure Codes](#7-icd-procedure-codes)
8. [Dates & Periods](#8-dates--periods)
9. [Authorization & Referral](#9-authorization--referral)
10. [Contract & Benefit](#10-contract--benefit)
11. [Financial / Payment Amounts](#11-financial--payment-amounts)
12. [Categorization & Reporting](#12-categorization--reporting)
13. [Pend Rules](#13-pend-rules)
14. [How Claim Adjudication Works](#how-claim-adjudication-works)
15. [Key Relationships](#key-relationships-to-understand)
16. [Validation Queries](#validation-queries)

---

## 1. Claim Identification & Status

| Column | Description | X12 Source |
|---|---|---|
| `ID` | Internal database surrogate key (auto-generated, not from EDI). | System-generated |
| `claimid` | Unique claim identifier. Maps to the Patient Control Number in the 837 or the Payer Claim Control Number in the 835. | **837: CLM01** / **835: CLP01** |
| `claimline` | Service line number within a claim. A single claim can have multiple service lines (e.g., line 1 = office visit, line 2 = lab work). | **837: Loop 2400 LX01** / **835: SVC loop sequence** |
| `ClaimStatus` | Header-level adjudication outcome. Values: `Pay`, `Denied`, `Pend`, `Void`, `Reversed`. | **835: CLP02** (Claim Status Code, X12 element 1029). Codes: 1=Processed as Primary, 2=Processed as Secondary, 3=Processed as Tertiary, 4=Denied, 19=Processed as Primary+Forwarded, 22=Reversal of Previous Payment. Your system translates these numeric codes into readable labels. |
| `ClaimLineStatus` | Line-level adjudication outcome per service line. Values: `Okay`, `Void`, `Pend`, etc. | Derived from **835: CAS segment** at the SVC (service line) level. A line is "Okay" if it has a payment; "Void" if reversed; "Pend" if held for review. |
| `orgclaimid` | Original claim ID — used when a claim is an adjustment, replacement, or reversal of a prior claim. Links the corrected claim back to the original. | **837: CLM05-3** (Claim Frequency Type Code) combined with **REF\*F8** (Original Reference Number) |
| `MasterClaimId` | Groups related claims together (original + adjustments/reversals). All versions of a claim share the same MasterClaimId. | System-derived from `orgclaimid` lineage |
| `FinalizedClaim` | Flag indicating whether the claim has reached a terminal state (Paid/Denied/Void) vs. still in-process. | System-derived |
| `ClaimLevelOnly` | Flag indicating this row contains claim-header-level data only (no service line detail). Some financial fields are reported only at the header level. | System-derived |
| `id2` | Secondary internal identifier (possibly a hash or alternate key). | System-generated |

---

## 2. Organization, Program & Plan

| Column | Description | X12 Source |
|---|---|---|
| `Company` | Insurance company or payer organization name. | **835: N1\*PR** (Payer Name in Loop 1000A) |
| `ProgramName` | Specific insurance program (e.g., "Medicare Advantage", "Medicaid Managed Care"). | Derived from **837: SBR09** (Claim Filing Indicator Code) or payer configuration |
| `programid` | Internal ID for the program. | System-generated |
| `PolicyProductType` | Product type of the policy (HMO, PPO, EPO, POS, Indemnity, etc.). | **837: SBR09** (Claim Filing Indicator Code). Codes: 12=PPO, 13=POS, 14=EPO, HM=HMO, etc. |
| `EXCHANGEPLAN` | Whether this is an ACA/Health Insurance Exchange (Marketplace) plan. | Derived from HIOS Plan ID or plan configuration |
| `POSPLAN` | Whether this is a Point-of-Service plan. | Derived from `PolicyProductType` |
| `PlanType` | Plan type classification. | **837: SBR05** (Insurance Type Code) |
| `HIOSPlanId` | Health Insurance Oversight System Plan ID — a CMS-assigned unique identifier for ACA Marketplace plans. Format: 5-digit issuer ID + state + product + plan variant. | **837: REF\*1L** or plan enrollment data |
| `LOB` | Line of Business — broad business segment (Commercial, Medicare, Medicaid, Individual, etc.). | Payer configuration / derived |

---

## 3. Provider Information

| Column | Description | X12 Source |
|---|---|---|
| `RenderingProvider` | Name of the provider who performed/rendered the service. | **837: NM1\*82** (Loop 2310B) — NM103=Last Name, NM104=First Name |
| `RenderingProviderNPI` | 10-digit National Provider Identifier of the rendering provider. | **837: NM1\*82, NM109** (Loop 2310B) |
| `RenderingProviderFedID` | Federal Tax ID (EIN or SSN) of the rendering provider. | **837: REF\*EI** or **REF\*SY** in Loop 2310B |
| `RenderingProvId` | Internal provider ID in your system. | System-generated |
| `RenderingProviderSpecCode` | Taxonomy/specialty code of the rendering provider (e.g., "207Q00000X" = Family Medicine). | **837: PRV\*PE\*PXC\*{code}** (Loop 2310B, PRV segment) |
| `RenderingProviderSpecDesc` | Human-readable description of the specialty code. | Lookup from NUCC Healthcare Provider Taxonomy table |
| `RenderingProviderType` | Provider type code. "1" = Person (Individual), "2" = Non-Person Entity (Organization). | **837: NM1\*82, NM102** (Entity Type Qualifier) |
| `RenderingProviderTypeDesc` | Description of provider type (e.g., "Individual", "Organization"). | Lookup from NM102 |
| `PayToFacilityName` | Name of the facility where payment should be sent (may differ from rendering provider). | **837: NM1\*77** (Loop 2310D — Service Facility) or **NM1\*87** (Pay-To Provider) |
| `PayToFedID` | Federal Tax ID of the pay-to entity. | **837: REF\*EI** in Pay-To Provider loop |
| `PayToNPI` | NPI of the pay-to facility/provider. | **837: NM1\*87, NM109** |
| `PaytoProvID` | Internal provider ID for the pay-to entity. | System-generated |
| `AttendingPhysId` | Internal ID of the attending physician (institutional claims only). | System-generated from **837I: NM1\*71** (Loop 2310A) |
| `AttendingPhysName` | Name of the attending physician. | **837I: NM1\*71** (Loop 2310A) — NM103/NM104 |
| `ProviderParStatus` | Provider participation status — In-Network (Par) or Out-of-Network (Non-Par). Influences benefit levels and cost-sharing. | Derived from contract/network data |
| `PRV` | Provider information qualifier or provider-level indicator. | **837: PRV segment** data |

---

## 4. Member / Subscriber / Enrollment

| Column | Description | X12 Source |
|---|---|---|
| `eligibleorgid` | Organization ID of the eligible entity (employer group). | Enrollment/eligibility system |
| `enrollid` | Enrollment record ID — the specific enrollment period record. | Enrollment system |
| `memid` | Member ID — unique identifier for the patient/member. | **837: NM1\*IL, NM109** (Loop 2010BA — Subscriber) or **NM1\*QC** (Patient if different from subscriber) |
| `HealthPlanId` | Health plan identifier. | **837: SBR03** (Reference Identification / Policy Number) |
| `Employer` | Employer/group name for group health plans. | Enrollment data; ties to **837: SBR04** (Group Name) |
| `SponsorId` | Sponsor (employer/group) ID. | Enrollment system |
| `OrgPolicyId` | Organization-level policy ID. | Enrollment system |
| `SponsorArea` | Geographic area or region of the sponsor/employer. | Enrollment/rating data |
| `Package` | Benefit package the member is enrolled in. | Enrollment system |
| `CovCode` | Coverage code — coverage tier (Employee Only, Employee+Spouse, Employee+Child(ren), Family, etc.). | Enrollment system |
| `CoverageCodeId` | Internal ID for the coverage code. | System-generated |
| `InternalSubscriberID` | Internal subscriber identifier (may differ from member ID for dependents). | Enrollment system |
| `Tier` | Benefit tier level (e.g., Tier 1 = preferred network, Tier 2 = broader network). | Benefit plan configuration |
| `GroupSizeAtClaimServiceDate` | Size of the employer group at the date of service. Affects rating, stop-loss, and reporting. | Enrollment/underwriting system |

---

## 5. Service & Clinical Information

| Column | Description | X12 Source |
|---|---|---|
| `ClaimType` | Type of claim: Professional (P/HCFA/CMS-1500), Institutional (I/UB-04), or Dental (D). | Derived from transaction type: **837P** vs. **837I** vs. **837D** |
| `servcode` | Service/procedure code — CPT or HCPCS code for the service rendered. | **837P: SV101-2** (Loop 2400) / **837I: SV202** |
| `billservcode` | Procedure code as originally billed by the provider (before any re-coding). | **837: SV101-2** or **SV202** (original submission) |
| `approvedservcode` | Procedure code approved/accepted after adjudication (may differ if re-coded by the payer). | Adjudication system |
| `modcode` | Primary modifier code — modifies the procedure (e.g., "25" = significant, separately identifiable E/M service; "59" = distinct procedural service). | **837: SV101-3** (Loop 2400) |
| `modcode2` | Secondary modifier code. | **837: SV101-4** |
| `Cpt41` | CPT-4 procedure code (subset of `servcode` when the code is a CPT code). | **837: SV101-2** (when CPT) |
| `Hcpcs` | HCPCS Level II code — used for supplies, DME, drugs, and non-physician services. | **837: SV101-2** (when HCPCS) |
| `revcode` | Revenue code (institutional claims only) — 4-digit code categorizing the department or type of charge (e.g., 0120=Room & Board Semi-Private, 0250=Pharmacy, 0450=Emergency Room). | **837I: SV201** (Loop 2400) |
| `servunits` | Number of service units — quantity of the service performed (days, units, visits, minutes). | **837P: SV104** / **837I: SV205** |
| `formtype` | Form type — CMS-1500 (professional) or UB-04 (institutional). | Derived from 837P vs. 837I |
| `PosCode` | Place of Service code (professional claims) — 2-digit code indicating where the service was performed. Common codes: 11=Office, 21=Inpatient Hospital, 22=On Campus Outpatient Hospital, 23=Emergency Room, 31=Skilled Nursing Facility, 81=Independent Lab. | **837P: CLM05-1** (C023-01) or **SV105** |
| `PosDesc` | Human-readable description of the Place of Service code. | Lookup table |
| `TypeOfBill` | Type of Bill (institutional claims only) — 4-character code: digit 1 = leading zero, digit 2 = facility type (1=Hospital, 2=SNF, 3=Home Health, etc.), digit 3 = bill classification (1=Inpatient, 3=Outpatient, etc.), digit 4 = frequency (1=Admit through Discharge, 7=Replacement, 8=Void). | **837I: CLM05-1** (first 2 digits) + **CLM05-3** (frequency code) |
| `location` | Location code for the facility or service site. | **837: CLM05** composite |
| `drg` | Diagnosis Related Group — classification system for inpatient hospital stays that groups clinically similar conditions with similar resource usage. Used for prospective payment (fixed payment per DRG regardless of actual charges). | **837I: HI segment** with DRG qualifier (Loop 2300) or adjudication-assigned |
| `IpDays` | Inpatient days — number of days the patient was hospitalized. | Calculated: `dischargedate - admitdate` |
| `beddays` | Bed days — count of inpatient bed days (similar to IpDays). | **837I: CLM** segment or calculated |
| `DischStatus` | Discharge status/patient status code. Common codes: 01=Discharged to Home, 02=Transferred to Short-Term Hospital, 03=Transferred to SNF, 06=Expired, 30=Still Patient. | **837I: CL103** |
| `admittype` | Admission type code. Codes: 1=Emergency, 2=Urgent, 3=Elective, 4=Newborn, 5=Trauma, 9=Unknown. | **837I: CL101** |
| `eVicoreCode` | eviCore (utilization management vendor) authorization/review code for the service. | Prior authorization system |
| `DerivedeVicorePosCode` | Place of service code derived/mapped by eviCore for their authorization logic. | Utilization management system |

---

## 6. Diagnosis Codes

| Column | Description | X12 Source |
|---|---|---|
| `IcdVersion` | ICD version indicator: 9 = ICD-9-CM, 10 = ICD-10-CM. Determines which code set is used. | **837: HI segment qualifier** — ABK/ABF = ICD-10, BK/BF = ICD-9 |
| `PrinDiag` | Principal diagnosis code — the primary reason for the encounter/admission. Required on all claims. | **837: HI\*ABK:{code}** (Loop 2300, first HI segment, position 1) |
| `AdmitDiag` | Admitting diagnosis (institutional claims) — the diagnosis at the time of admission, before workup is complete. | **837I: HI\*ABJ:{code}** (Loop 2300) |
| `DiagCode1` – `DiagCode40` | Additional/secondary diagnosis codes. These capture comorbidities, complications, and contributing conditions. Professional claims support up to 12 in the EDI; institutional claims support up to 25. The table extends to 40 for operational flexibility. | **837: HI\*ABF:{code}** (Loop 2300, subsequent HI elements) |

### HI Segment Qualifier Reference

| Qualifier | Meaning | ICD Version |
|---|---|---|
| ABK | Principal Diagnosis | ICD-10-CM |
| ABF | Additional Diagnosis | ICD-10-CM |
| ABJ | Admitting Diagnosis | ICD-10-CM |
| BK | Principal Diagnosis | ICD-9-CM |
| BF | Additional Diagnosis | ICD-9-CM |
| BBR | Principal Procedure | ICD-10-PCS |
| BBQ | Other Procedure | ICD-10-PCS |

---

## 7. ICD Procedure Codes

| Column | Description | X12 Source |
|---|---|---|
| `ICDProcCode1` – `ICDProcCode5` | ICD Procedure Codes (institutional/inpatient claims only). These are surgical/procedural codes from ICD-10-PCS (Procedure Coding System). Different from CPT/HCPCS — these describe inpatient procedures using ICD's own classification. | **837I: HI segment** with qualifier **BBR** (Principal Procedure) and **BBQ** (Other Procedures) |

---

## 8. Dates & Periods

| Column | Description | X12 Source |
|---|---|---|
| `StartServiceDate` | Claim-header-level start date of service. | **837: DTP\*472\*D8\*{date}** or **DTP\*472\*RD8\*{date range}** (Loop 2300) |
| `EndServiceDate` | Claim-header-level end date of service. | **837: DTP\*472** (Loop 2300) — end of date range |
| `DOSFrom_ClaimLine` | Line-level Date of Service FROM — each service line can have its own date. | **837: DTP\*472** (Loop 2400) — line-level start |
| `DOSTo_ClaimLine` | Line-level Date of Service TO. | **837: DTP\*472** (Loop 2400) — line-level end |
| `ServicePeriod` | Service period (typically YYYYMM format) — used for grouping and reporting. | Derived from `StartServiceDate` |
| `PaidPeriod` | Payment/accounting period (typically YYYYMM format). | Derived from `PaidDate` |
| `admitdate` | Date of admission (institutional/inpatient claims). | **837I: DTP\*435\*D8\*{date}** (Loop 2300) |
| `dischargedate` | Date of discharge. | **837I: DTP\*096\*D8\*{date}** (Loop 2300) |
| `logdate` | Date the claim was logged/received into the system. | System-generated |
| `createdate` | Date the claim record was created in the database. | System-generated |
| `ClaimLastUpdate` | Last update timestamp for the claim header. | System-generated |
| `ClaimDetailLastUpdate` | Last update timestamp for the claim detail/line. | System-generated |
| `PaidDate` | Date the claim was paid/finalized. | **835: DTM\*405** (Production Date) or **BPR16** (check/EFT date) |
| `adjuddate` | Date the claim was adjudicated (decision rendered). | **835: DTM** or adjudication system timestamp |
| `CleanDate` | Date the claim was considered "clean" — complete with all required information for processing. HIPAA requires payers to pay clean claims within 30 days (electronic) or 45 days (paper). | Adjudication system |
| `ClaimAge` | Age of the claim in days (from submission to current date or finalization). | Calculated: e.g., `DATEDIFF(day, logdate, GETDATE())` |

---

## 9. Authorization & Referral

| Column | Description | X12 Source |
|---|---|---|
| `referralid` | Referral or prior authorization number associated with the claim. | **837: REF\*9F** (Referral Number) or **REF\*G1** (Prior Authorization Number) in Loop 2300 |
| `referfrom` | The referring provider or source of the referral. | **837: NM1\*DN** (Loop 2310A — Referring Provider) |
| `autofillauth` | Whether authorization was auto-filled or auto-approved by the system. | System-generated |

---

## 10. Contract & Benefit

| Column | Description | X12 Source |
|---|---|---|
| `contractid` | Provider contract ID used for pricing/reimbursement determination. | Adjudication/contract system |
| `termid` | Specific contract term ID (contracts can have multiple term periods with different rates). | Contract system |
| `fundid` | Funding arrangement ID — Fully Insured, Self-Funded (ASO), Level-Funded, etc. | Funding/financial system |
| `benefitplan` | Benefit plan code applied to the claim. | Benefit configuration |
| `benefitName` | Human-readable name of the benefit plan. | Benefit configuration |
| `BenefitID` | Internal ID of the specific benefit that was applied. | Benefit configuration |
| `ServiceAffilId` | Service affiliation ID — links to the service area or network affiliation. | Network/configuration system |

---

## 11. Financial / Payment Amounts

This is the most critical section. Here is how the money flows through adjudication:

### The Adjudication Math

```
Billed Amount (claimamt_or_Charges)
  − Contractual Discount (paydiscount)
  = Allowed Amount (AllowedAmt_or_ContractPaid)

Allowed Amount (AllowedAmt_or_ContractPaid)
  − Copay (copay)
  − Coinsurance (coinsuranceamt)
  − Deductible (Deductible)
  − COB / Other Insurance (COB_or_extpaidAmt)
  = Plan Pays (amountpaid)
```

### Column Definitions

| Column | Description | X12 Source | Role in Adjudication |
|---|---|---|---|
| `claimamt_or_Charges` | **Billed/Charged amount** — the total amount the provider originally billed for the service. | **837: CLM02** / **835: CLP03** | Starting point. What the provider says the service costs. |
| `AllowedAmt_or_ContractPaid` | **Allowed amount** — the maximum amount the payer will consider for payment based on the provider's contract or fee schedule. | **835: AMT\*B6** (Allowed - Actual) or derived from contract terms | The "agreed-upon" price. The difference between Charged and Allowed is the contractual write-off. |
| `amountpaid` | **Amount paid** by the payer to the provider. | **835: CLP04** (Claim Payment Amount) | What the insurance actually pays. |
| `paydiscount` | **Contractual discount/write-off** — the amount the provider writes off per their contract (Charged minus Allowed). | **835: CAS\*CO\*45** (Charges exceed fee schedule/maximum allowable) | Provider cannot bill the patient for this amount (if in-network). |
| `conteligamt` | **Contract eligible amount** — the amount eligible under the contract terms. Usually equals the Allowed amount. | Adjudication calculation | |
| `costshareamt` | **Total member cost-sharing** — total amount the member is responsible for out-of-pocket (copay + coinsurance + deductible). | **835: CLP05** (Patient Responsibility Amount) | Sum of all member out-of-pocket costs. |
| `copay` | **Copay** — fixed dollar amount the member pays per visit or service (e.g., $30 office visit, $250 ER visit). | **835: CAS\*PR\*3** (Co-payment Amount) | Set by plan design. Flat fee per service type. |
| `coinsuranceamt` | **Coinsurance** — percentage of the allowed amount the member pays after deductible is met (e.g., member pays 20%, plan pays 80%). | **835: CAS\*PR\*2** (Coinsurance Amount) | Percentage-based cost-sharing. |
| `Deductible` | **Deductible** — the amount the member must pay out-of-pocket before insurance begins paying. Resets each plan year. | **835: CAS\*PR\*1** (Deductible Amount) | Annual threshold. Individual and family deductibles may apply. |
| `memamt` | **Total member amount** — total member financial responsibility. May equal `costshareamt` or include additional amounts. | **835: CLP05** or calculated | |
| `addlmemamt` | **Additional member amount** — extra amount the member owes beyond standard cost-sharing (e.g., balance billing for out-of-network, non-covered amounts). | Adjudication calculation | |
| `CostShareSavings` | **Cost-share savings** — savings achieved through cost-sharing arrangements (e.g., tiered network or reference-based pricing savings). | Adjudication calculation | |
| `COB_or_extpaidAmt` | **Coordination of Benefits amount** — amount paid or expected from another payer when the member has dual coverage. | **835: AMT\*D** (COB Payer Paid Amount) or **CAS\*OA\*23** | Primary payer pays first; secondary payer covers remaining eligible amounts. |
| `cobamt` | **COB amount** — another representation of coordination of benefits payment. | **835: AMT segment** with COB qualifier | |
| `benededuct` | **Benefit-level deductible** — deductible applied at the benefit level (as opposed to overall plan deductible). Some plans have separate deductibles for specific benefits (e.g., pharmacy). | Adjudication/benefit calculation | |
| `CapitatedClaim` | **Capitated flag** — whether this claim falls under a capitation arrangement. Under capitation, the provider receives a fixed per-member-per-month (PMPM) amount regardless of services rendered. | Adjudication/contract system | If capitated, `amountpaid` may be $0. |
| `CapitatedAmount` | **Capitation amount** — the PMPM amount under the capitation arrangement. | Contract system | |
| `FirstHealthRepriced` | Whether the claim was repriced by First Health (a PPO rental network/repricing company). Common for out-of-network claims. | Repricing system | |
| `RepricingMessage` | Message or notes from the repricing process. | Repricing system | |
| `interestdays` | Number of days used to calculate interest for prompt-payment penalties. Many states require payers to pay interest on claims not paid within statutory timeframes. | Adjudication system | |
| `refundAmt` | Amount refunded (for overpayments or payment reversals). | Adjudication system | |

### CAS Segment Group Codes (835)

The 835 uses CAS (Claims Adjustment) segments to explain every dollar. Each adjustment has a **Group Code** and a **Reason Code**:

| Group Code | Meaning | Who Is Responsible |
|---|---|---|
| **CO** | Contractual Obligation | Provider write-off (cannot bill patient) |
| **PR** | Patient Responsibility | Member pays |
| **OA** | Other Adjustment | Informational / other |
| **PI** | Payer Initiated | Payer-initiated reduction |
| **CR** | Correction/Reversal | Correction to prior adjudication |

Common CAS Reason Codes:

| Reason Code | Description | Maps To |
|---|---|---|
| 1 | Deductible Amount | `Deductible` |
| 2 | Coinsurance Amount | `coinsuranceamt` |
| 3 | Co-payment Amount | `copay` |
| 4 | Procedure code inconsistent with modifier | Denial reason |
| 23 | Impact of prior payer(s) adjudication | `COB_or_extpaidAmt` |
| 45 | Charges exceed fee schedule/maximum allowable | `paydiscount` |
| 50 | Non-covered service (not a benefit) | Denial reason |
| 96 | Non-covered charge(s) | Denial reason |
| 97 | Payment adjusted — benefit for this service included in another service/procedure | Bundling |

---

## 12. Categorization & Reporting

| Column | Description | X12 Source |
|---|---|---|
| `CatExp_Prefix` | Category of expense prefix — high-level expense classification (e.g., Medical, Pharmacy, Behavioral Health). | Adjudication/reporting system |
| `CatExp_Finance` | Financial category of expense — used for financial reporting and reserving. | Reporting system |
| `CatExpAtDatabase` | Category of expense as recorded in the database. | Reporting system |
| `SubCOE` | Sub-category of expense — more granular classification (e.g., Inpatient Medical, Outpatient Surgery, Professional Office Visit, ER). | Reporting system |
| `SourceSystem` | The source system the claim originated from. | System tracking |
| `Dataset` | Which dataset or data feed this record belongs to. | System tracking |

---

## 13. Pend Rules

| Column | Description | X12 Source |
|---|---|---|
| `HeaderLevelPendRuleId` | ID of the pend rule that caused the claim header to pend (be held for manual review). | Adjudication rules engine |
| `HeaderLevelPendRuleDescription` | Description of why the claim header was pended. Examples: "Requires prior authorization", "Exceeds benefit maximum", "Provider not credentialed", "COB information needed". | Adjudication rules engine |
| `LineLevelPendRuleId` | ID of the pend rule that caused a specific claim line to pend. | Adjudication rules engine |
| `LineLevelPendRuleDescription` | Description of why the specific line was pended. Examples: "Procedure code requires modifier", "Duplicate service on same date", "Units exceed allowed maximum". | Adjudication rules engine |

---

## How Claim Adjudication Works

Here is the end-to-end lifecycle of a claim as it relates to your data:

### Step 1: Claim Submission (837)

The provider submits an 837 transaction (Professional or Institutional) containing:
- Patient/member demographics and insurance information
- Diagnosis codes (ICD-10-CM)
- Procedure/service codes (CPT/HCPCS) with modifiers
- Dates of service
- Billed charges
- Provider identifiers (NPI, taxonomy)

### Step 2: Claim Receipt & Front-End Validation

The payer receives the 837 and performs front-end edits:

| Check | What It Does | Key Columns |
|---|---|---|
| **Eligibility** | Is the member active on the date of service? | `memid`, `enrollid`, `HealthPlanId`, `StartServiceDate` |
| **Provider Validation** | Is the provider credentialed and contracted? | `RenderingProviderNPI`, `ProviderParStatus` |
| **Duplicate Check** | Has this claim already been submitted? | `claimid`, `orgclaimid`, `MasterClaimId` |
| **Data Completeness** | Are all required fields present and valid? | Various |

If the claim fails these checks, it is either:
- **Rejected** — returned to the provider, never enters the system
- **Pended** — `ClaimStatus = 'Pend'`, pend rule columns populated

### Step 3: Benefit Determination

The system determines which benefits apply:
- Looks up the member's `benefitplan`, `Package`, `CovCode`, `Tier`
- Matches the service code (`servcode`) to a benefit category (`BenefitID`, `benefitName`)
- Checks for prior authorization requirements (`referralid`, `eVicoreCode`)
- Applies place-of-service logic (`PosCode`, `location`)
- Determines in-network vs. out-of-network benefit levels (`ProviderParStatus`)

### Step 4: Pricing / Repricing

The system determines how much to pay:

| Scenario | How It Works | Key Columns |
|---|---|---|
| **In-Network (Par)** | Uses the provider's contracted fee schedule | `contractid`, `termid`, `AllowedAmt_or_ContractPaid` |
| **Out-of-Network (Non-Par)** | Uses UCR (Usual, Customary, Reasonable) rates or repricing | `FirstHealthRepriced`, `RepricingMessage` |
| **Capitated** | No fee-for-service payment — provider already paid PMPM | `CapitatedClaim`, `CapitatedAmount` |
| **DRG-Based (Inpatient)** | Fixed payment per DRG for the entire stay | `drg`, `IpDays` |

### Step 5: Cost-Sharing Application

The system applies the member's cost-sharing based on their plan design:

```
Billed Amount .................. claimamt_or_Charges
  − Contractual Discount ....... paydiscount
  ─────────────────────────────────────────────
  = Allowed Amount ............. AllowedAmt_or_ContractPaid
  − Deductible ................. Deductible
  − Copay ...................... copay
  − Coinsurance ................ coinsuranceamt
  − Other Insurance (COB) ...... COB_or_extpaidAmt
  ─────────────────────────────────────────────
  = Plan Pays .................. amountpaid
```

The member's total responsibility: `costshareamt ≈ copay + coinsuranceamt + Deductible`

### Step 6: Adjudication Decision

The claim receives a final status:

| Status | Meaning | Financial Impact |
|---|---|---|
| **Pay** | Claim approved and finalized for payment | `amountpaid` > 0 (usually). `PaidDate` and `adjuddate` are set. |
| **Denied** | Claim rejected for clinical, administrative, or benefit reasons | `amountpaid` = 0. Denial reason captured in CAS codes. |
| **Pend** | Claim needs manual review before a decision can be made | No payment yet. Pend rule descriptions explain why. |
| **Void** | Claim cancelled/nullified (often the last digit of Type of Bill = 8) | Original payment reversed to $0. |
| **Reversed** | A previous payment was reversed (taken back) due to error | Negative `amountpaid` to offset original. `orgclaimid` links to original. |

### Step 7: Payment & Remittance (835)

The payer sends an 835 (ERA) to the provider with:
- What was paid (`amountpaid`)
- All adjustments and reasons (CAS segments → `paydiscount`, `Deductible`, `copay`, etc.)
- Patient responsibility (`costshareamt`)
- Check/EFT details (`PaidDate`)

---

## Key Relationships to Understand

### Claim vs. Claim Line

- One **claim** (`claimid`) can have multiple **claim lines** (`claimline`).
- Think of the claim as the "visit" or "encounter" and each line as a separate service during that visit.
- `ClaimStatus` applies to the whole claim; `ClaimLineStatus` applies to individual lines.
- A claim can have lines with mixed statuses (e.g., line 1 paid, line 2 denied).

### Original vs. Adjusted Claims

- `orgclaimid` links adjusted/corrected claims back to their original.
- `MasterClaimId` groups all versions together.
- When a claim is **reversed**, a mirror claim is created with negative amounts to zero out the original payment, then a new corrected claim may be submitted.

### Claim Type Determines Which Fields Apply

| Field | Professional (837P) | Institutional (837I) |
|---|---|---|
| `PosCode` / `PosDesc` | ✅ Used | ❌ Not used |
| `TypeOfBill` | ❌ Not used | ✅ Used |
| `revcode` | ❌ Not used | ✅ Used |
| `drg` | ❌ Not used | ✅ Used (inpatient) |
| `admittype` | ❌ Not used | ✅ Used |
| `DischStatus` | ❌ Not used | ✅ Used |
| `admitdate` / `dischargedate` | ❌ Not used | ✅ Used |
| `AttendingPhysName` | ❌ Not used | ✅ Used |
| `ICDProcCode1-5` | ❌ Not used | ✅ Used |
| `IpDays` / `beddays` | ❌ Not used | ✅ Used |

---

## Validation Queries

Use these queries to explore and validate your data:

### Check the Financial Balance

```sql
SELECT
    claimid,
    claimline,
    claimamt_or_Charges AS Billed,
    paydiscount AS Discount,
    AllowedAmt_or_ContractPaid AS Allowed,
    amountpaid AS PlanPaid,
    copay,
    coinsuranceamt,
    Deductible,
    costshareamt AS MemberResp,
    COB_or_extpaidAmt AS OtherInsurance,
    -- These two calculated columns should roughly equal AllowedAmt_or_ContractPaid
    claimamt_or_Charges - ISNULL(paydiscount, 0) AS CalcAllowed,
    amountpaid + ISNULL(costshareamt, 0) + ISNULL(COB_or_extpaidAmt, 0) AS CalcAllowed2
FROM [Prominence].[dbo].[ClaimDetails]
WHERE ClaimStatus = 'Pay';
```

### Claim Status Distribution

```sql
SELECT
    ClaimStatus,
    COUNT(*) AS ClaimCount,
    SUM(claimamt_or_Charges) AS TotalBilled,
    SUM(amountpaid) AS TotalPaid
FROM [Prominence].[dbo].[ClaimDetails]
GROUP BY ClaimStatus
ORDER BY ClaimCount DESC;
```

### Find Reversed & Adjusted Claims

```sql
SELECT
    MasterClaimId,
    claimid,
    orgclaimid,
    ClaimStatus,
    claimamt_or_Charges,
    amountpaid,
    createdate
FROM [Prominence].[dbo].[ClaimDetails]
WHERE orgclaimid IS NOT NULL
ORDER BY MasterClaimId, createdate;
```

### Claims Stuck in Pend

```sql
SELECT
    claimid,
    ClaimAge,
    logdate,
    HeaderLevelPendRuleId,
    HeaderLevelPendRuleDescription,
    LineLevelPendRuleId,
    LineLevelPendRuleDescription
FROM [Prominence].[dbo].[ClaimDetails]
WHERE ClaimStatus = 'Pend'
ORDER BY ClaimAge DESC;
```

### Capitated vs. Fee-for-Service Breakdown

```sql
SELECT
    CapitatedClaim,
    COUNT(*) AS ClaimCount,
    SUM(claimamt_or_Charges) AS TotalBilled,
    SUM(amountpaid) AS TotalPaid,
    SUM(CapitatedAmount) AS TotalCapitated
FROM [Prominence].[dbo].[ClaimDetails]
GROUP BY CapitatedClaim;
```

### Top Denial / Pend Reasons

```sql
-- Header-level pend reasons
SELECT
    HeaderLevelPendRuleDescription,
    COUNT(*) AS PendCount
FROM [Prominence].[dbo].[ClaimDetails]
WHERE ClaimStatus = 'Pend'
  AND HeaderLevelPendRuleDescription IS NOT NULL
GROUP BY HeaderLevelPendRuleDescription
ORDER BY PendCount DESC;

-- Line-level pend reasons
SELECT
    LineLevelPendRuleDescription,
    COUNT(*) AS PendCount
FROM [Prominence].[dbo].[ClaimDetails]
WHERE LineLevelPendRuleDescription IS NOT NULL
GROUP BY LineLevelPendRuleDescription
ORDER BY PendCount DESC;
```

### Claims by Provider Network Status

```sql
SELECT
    ProviderParStatus,
    ClaimType,
    COUNT(*) AS ClaimCount,
    SUM(claimamt_or_Charges) AS TotalBilled,
    SUM(AllowedAmt_or_ContractPaid) AS TotalAllowed,
    SUM(amountpaid) AS TotalPaid,
    SUM(paydiscount) AS TotalDiscount
FROM [Prominence].[dbo].[ClaimDetails]
WHERE ClaimStatus = 'Pay'
GROUP BY ProviderParStatus, ClaimType
ORDER BY ProviderParStatus, ClaimType;
```

---

## X12 EDI Reference Resources

| Resource | URL | Description |
|---|---|---|
| Data Insight EDI Viewer | https://datainsight.health/edi/viewer/ | Free online viewer for 837/835 EDI files |
| Data Insight Data Dictionary | https://datainsight.health/docs/datadict/ | CSV data dictionaries mapping EDI fields |
| X12 Examples | https://x12.org/examples | Official X12 EDI examples for all transaction types |
| Stedi X12 Reference | https://www.stedi.com/edi/x12 | Interactive X12 segment/element reference |
| X12 Code Lists | https://x12.org/codes | External code lists (claim status, adjustment reasons, etc.) |
| NUCC Taxonomy Codes | https://taxonomy.nucc.org/ | Provider taxonomy/specialty code lookup |
| WPC Code Lists | https://www.wpc-edi.com/reference/ | CARC/RARC adjustment reason code lookup |

---

## Glossary

| Term | Definition |
|---|---|
| **Adjudication** | The process of evaluating a claim and determining what to pay |
| **Allowed Amount** | The maximum amount a payer will pay for a covered service, based on the provider's contract |
| **Capitation** | A payment model where the provider receives a fixed PMPM amount regardless of services rendered |
| **CAS** | Claims Adjustment Segment — explains every dollar adjustment on the 835 |
| **CARC** | Claim Adjustment Reason Code — specific reason for a payment adjustment |
| **CLM** | Claim segment in the 837 transaction |
| **CLP** | Claim Payment segment in the 835 transaction |
| **COB** | Coordination of Benefits — process when a patient has coverage from multiple payers |
| **CPT** | Current Procedural Terminology — procedure codes maintained by the AMA |
| **DRG** | Diagnosis Related Group — inpatient classification system for prospective payment |
| **EDI** | Electronic Data Interchange — standardized electronic communication format |
| **ERA** | Electronic Remittance Advice — the 835 transaction |
| **HCPCS** | Healthcare Common Procedure Coding System — Level II codes for supplies, drugs, DME |
| **HIPAA** | Health Insurance Portability and Accountability Act — mandates X12 EDI standards |
| **ICD-10-CM** | International Classification of Diseases, 10th Revision, Clinical Modification — diagnosis codes |
| **ICD-10-PCS** | International Classification of Diseases, 10th Revision, Procedure Coding System — inpatient procedure codes |
| **NPI** | National Provider Identifier — 10-digit unique provider ID |
| **Par / Non-Par** | Participating (in-network) / Non-Participating (out-of-network) provider status |
| **PMPM** | Per Member Per Month — capitation payment unit |
| **UCR** | Usual, Customary, and Reasonable — benchmark for out-of-network pricing |
