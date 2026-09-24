# Carrier Risk Scorecard: Predicting Out-of-Service Risk for Shippers

## What this is

If you're a shipper picking a motor carrier, reliability is of the utmost importance and you want to know one thing up front: is this carrier likely to get pulled off the road? This project digs into that question using public FMCSA data — carrier census records, roadside inspections, and crash reports — and builds a risk scorecard for carriers operating in the NJ/NY/PA/DE/CT corridor.

Question I set out to answer:** which observable carrier characteristics actually predict out-of-service (OOS) and safety risk, and what would a usable scorecard look like for someone making a hiring decision?

Tools:MySQL for cleaning and joining the data, Tableau for the analysis and dashboard, a bit of Excel for reviews.

Data: pulled from [data.transportation.gov](https://data.transportation.gov) — FMCSA's Motor Carrier Census, Inspection, and Crash files.


## The data

Three files, linked by `DOT_NUMBER` (the federal carrier ID):

COMPANY_CENSUS - One row per carrier filing — fleet size, mileage, cargo type, operation type, safety rating
INSPECTION_FILE - One row per roadside inspection — violations and OOS counts, split out by Driver/Vehicle/Hazmat
CRASH_FILE - One row per crash — fatalities, injuries, tow-away, location 


## Getting the data clean was most of the work

I'm including this section because diagnosing what went wrong with this dataset took longer than the actual analysis, and I think it's worth showing that process.

1. The census file was silently truncated by Excel. My first COMPANY_CENSUS extract had exactly 1,048,576 rows which is Excel's hard row limit. Somewhere along the way I had opened it in Excel, which quietly chopped a multi-million-row national file down to a single sheet. I only caught this because my join against the inspection/crash files was only matching about 2% of carriers, which made no sense for a national dataset. I re-loaded the raw CSV straight into MySQL with `LOAD DATA INFILE', no Excel in between, and got the full ~4.5M carrier population back.

2. I double-checked the join key before assuming anything else was wrong. Before chasing other theories, I verified `DOT_NUMBER` formats and ranges matched across all three tables — ruled out a format mismatch as the cause and helped me isolate the actual problem above.

3. Duplicate carriers in the census. About 36,600 `DOT_NUMBER`s had more than one row (carriers file updates over time). I deduplicated to the most recent filing using `MCS150_DATE`, falling back to `ADD_DATE` for roughly 587,000 carriers that had no valid filing date at all.

4. My local MySQL server kept crashing. Several dedup/join steps — an `ALTER TABLE`, a `ROW_NUMBER()` window function both killed the connection outright. Buffer pool increase resolved this issue.

5. Scoping to a region wasnot as simple as filtering by home state. I wanted to narrow this to the NJ/NY/PA/DE/CT corridor to keep it manageable. My first attempt filtered carriers by their home state (`PHY_STATE`), which left me with only about 80 matched carriers. The problem seemed to be most roadside inspections and crashes involve carriers passing through a region, not just ones headquartered there. I switched to filtering by `REPORT_STATE` (where the inspection/crash actually happened) instead, which both fixed the sample size and better reflects what a regional shipper actually cares about.

6. An integer overflow in the mileage field. `MCS150_MILEAGE` had values as high as 2,147,483,647 — which is exactly 2^31 - 1, not a real reported number, just a storage overflow, and it was wrecking every mileage-normalized metric. Excluded anything above a 10,000,000 mile/year ceiling before computing rates.

7. A second mileage problem I only caught by cross-checking in Tableau. fter I had my SQL-based findings, I rebuilt the same comparison in Tableau to confirm and the numbers didn't match. It turned out some carriers had reported implausible near-zero mileage (1 mile, 3 miles, 150 miles a year). Since my crash-rate metric divides by mileage, these tiny denominators blew up into meaningless rates — some over a million crashes per million miles. I added a lower bound (mileage > 1,000) alongside the existing upper bound. This changed the size of my headline finding but not the direction of it, and I only found it because I checked the same number two different ways.


## How I defined "high risk"

My original plan was a percentile-based cutoff on OOS inspection rate. That fell apart once I saw how thin the inspection data actually is. Even at a loose bar of 5+ inspections, only 5 carriers in my whole regional dataset qualified. 

So I switched to something simpler and more usable: `high_risk` = 1 if a carrier has ever had an OOS violation, a fatal crash, or an injury crash on record, 0 otherwise. It's less statistically precise — one bad incident years ago counts the same as a repeated pattern but it lets me use every carrier's full history instead of throwing out most of the data. I ended up with a pretty well-balanced split: 872 high-risk, 944 low-risk (after I fixed a duplicate-carrier bug that had inflated both counts by 39).


## What I found

High-risk carriers run roughly double the fleet size and double the annual mileage of low-risk carriers. Which was to be expected - bigger fleets running more miles naturally rack up more incidents over time just from being on the road more.

I normalized for that: crashes per million miles, and crashes per power unit. The gap held up even after normalizing, and after fixing both mileage data issues above. High-risk carriers averaged about 25 crashes per million miles vs. about 13 for low-risk carriers, roughly 92% higher. (My first pass at this, before I caught the low-end mileage bug, showed a smaller ~58% gap. The direction didn't change, but the corrected number is the one I trust.)

That tells me fleet size isn't purely an exposure artifact here, bigger carriers in this sample are also getting into more crashes per mile driven, not just more crashes in total from driving more.

A couple other things worth calling out:

Safety rating: carriers with an Unsatisfactory rating show a 70% high-risk rate, clearly above Conditional (59.6%), unrated (58.9%), and Satisfactory (57.1%), which are all fairly close to each other.
Carrier operation type: intrastate non-hazmat carriers (`CARRIER_OPERATION = C`) show a 66.2% high-risk rate vs. 57.2% for interstate carriers (`A`)


## Where this analysis is limited

It's scoped to one corridor (NJ/NY/PA/DE/CT)
`SAFETY_RATING` is missing for about 43% of carriers, since FMCSA only formally rates carriers pulled in for a compliance review. Some of what looks like a "rating effect" could really be a "this carrier already drew scrutiny" effect
The normalized crash-rate numbers only cover carriers with usable mileage data (excluding both the overflow values and the near-zero junk values). Carriers left out of that subset could behave differently
Even after the 1,000-mile floor, a small carrier with very few miles can still swing to an extreme rate off a single crash. Treat small-fleet numbers as noisier than large-fleet ones
`high_risk` is a lifetime flag, so it doesn't distinguish a carrier with one old incident from one with a recent pattern
Conclusions specifically about OOS/inspection behavior rest on a smaller sample than the crash-based findings, since `INSPECTION_FILE` itself is a small file


## Dashboard

Built out an interactive Tableau dashboard with five linked views: crash rate by risk group, fleet size vs. crash rate (log scale, since the data's heavily skewed), risk rate by safety rating, risk rate by carrier operation, and a full carrier lookup table. The views are cross-filtered — click a bar in any of the summary charts and the carrier table filters down to match.

Live dashboard: https://public.tableau.com/app/profile/jt.mcgahran/viz/DOTCarrierRiskScorecard/ScorecardDashboard?publish=yes


## What's left

[x] Build the Tableau dashboard
[x] Compare high_risk across carrier operation type and safety rating (queries in `/sql/05_outlier_cleanup_and_analysis.sql`)
[ ] Maybe run a linear probability model in Excel for a more quantified "which factors matter" answer
[ ] Look at cargo type (`CRGO_*` fields) as another possible predictor



## Repo layout

/sql/          all five SQL scripts, in the order I actually ran them
/tableau/      the Tableau workbook
README.md      this file
```
