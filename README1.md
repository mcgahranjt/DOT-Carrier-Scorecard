# Carrier Risk Scorecard: Do Carrier Characteristics Predict Out-of-Service Risk?

## What this is

If you're a shipper picking a motor carrier, you want to know whether the carrier is likely to get pulled off the road. I used public FMCSA data (carrier census records, roadside inspections, and crash reports) to look at carriers operating in the NJ/NY/PA/DE/CT corridor and ask a simple question: **do the things you can see about a carrier, like fleet size, mileage, operation type, and safety rating, actually predict out-of-service (OOS) and crash risk?**

Short version of the answer: mostly no. I built the scorecard anyway, but the more useful result turned out to be how weak those signals are, and how easy it was to fool myself along the way. The sections below walk through what I did, what I found, and what I had to walk back.

**Tools:** MySQL (cleaning, joins, aggregation), Tableau (dashboard), Excel Analysis ToolPak (regression).

**Data:** [data.transportation.gov](https://data.transportation.gov), FMCSA Motor Carrier Census, Inspection, and Crash files.

---

## The data

Three files, linked by `DOT_NUMBER` (the federal carrier ID):

| File | What it is |
|---|---|
| `COMPANY_CENSUS` | One row per carrier filing: fleet size, mileage, cargo type, operation type, safety rating |
| `INSPECTION_FILE` | One row per roadside inspection: violations and OOS counts, split by Driver/Vehicle/Hazmat |
| `CRASH_FILE` | One row per crash: fatalities, injuries, tow-away, location |

---

## Getting the data clean was most of the work

I'm keeping this section detailed because diagnosing what was wrong with this dataset took longer than the analysis itself.

**1. Excel had silently truncated the census file.** My first `COMPANY_CENSUS` extract had exactly 1,048,576 rows, which is Excel's hard row limit. A multi-million-row national file had been cut down to one sheet. I only noticed because my join was matching about 2% of carriers, which made no sense. I reloaded the raw CSV straight into MySQL with `LOAD DATA INFILE` and got the full ~4.5M carriers back.

**2. I checked the join key before blaming anything else.** I confirmed `DOT_NUMBER` formats and ranges matched across all three tables. That ruled out a format mismatch and pointed me back at the truncation.

**3. Duplicate carriers in the census.** About 36,600 `DOT_NUMBER`s had more than one row, since carriers file updates over time. I kept the most recent filing by `MCS150_DATE`, falling back to `ADD_DATE` for roughly 587,000 carriers with no valid filing date.

**4. My local MySQL server kept crashing.** An `ALTER TABLE` and a `ROW_NUMBER()` window function both killed the connection. The InnoDB error log showed the buffer pool was still at the 128MB default, far too small for a table this size. I raised it to 2GB in `my.cnf` and the crashes stopped.

**5. Filtering by home state gave me too few carriers.** I first narrowed to the corridor by carrier home state (`PHY_STATE`) and ended up with only about 80 matched carriers. Most inspections and crashes involve carriers passing *through* a region, not just ones based there. Switching to `REPORT_STATE` (where the event happened) fixed the sample size and fits a regional shipper's actual exposure better.

**6. Integer overflow in the mileage field.** `MCS150_MILEAGE` had values up to 2,147,483,647, which is exactly 2^31 - 1, the largest signed 32-bit integer. That's a storage artifact, not a real mileage figure. I excluded anything above 10,000,000 miles/year.

**7. Near-zero mileage, caught by checking in a second tool.** After getting SQL results, I rebuilt the same comparison in Tableau and the numbers didn't match. Some carriers reported 1, 3, or 150 miles a year, and since my crash-rate metric divides by mileage, those tiny denominators produced rates over a million crashes per million miles. I added a lower bound of 1,000 miles.

**8. The label was mixing two different things, caught by the regression.** This one mattered most and is covered in the next section.

---

## How I defined "high risk", and where that went wrong

`INSPECTION_FILE` is thin: even at a loose bar of 5+ inspections only 5 carriers qualified, and carriers in the final sample average about 1.09 inspections and 1.09 crashes each. A percentile-based OOS rate wasn't possible, so I used a binary flag: `high_risk = 1` if a carrier had ever had an OOS violation, a fatal crash, or an injury crash.

That flag has a flaw I didn't catch until I ran the regression. Carriers enter the dataset through the crash file, the inspection file, or both, and the two doors have very different base rates:

| How the carrier entered the data | Carriers | % flagged high-risk |
|---|---|---|
| Crash file only | 652 | 57.4% |
| Inspection file only | 420 | 21.2% |
| Both | 9 | 88.9% |

A crash-only carrier is flagged by an injury or fatal crash, and an inspection-only carrier needs an OOS violation. Those aren't comparable events, so part of the label measures *which file a carrier appeared in* rather than anything about the carrier. It also explains something that confused me earlier: the 735 carriers I excluded for bad mileage were flagged more often (54.6% vs. 43.6%), but that's because the excluded group is almost entirely crash-only carriers, not because bad mileage data signals risk.

**The fix** was to stop pooling and model each outcome on its own population: any OOS violation among inspected carriers, and any injury or fatal crash among crashed carriers.

---

## What I found

I ran linear probability models in Excel (a 0/1 outcome regressed on fleet size, mileage, operation type, and safety rating). P-values from this approach are approximate, so I treat them as supporting evidence rather than hard cutoffs.

**With the pooled label, safety rating looked like the strongest predictor.** Rated carriers were about 21 points more likely to be flagged, and that was the biggest effect in the model. Once I controlled for how the carrier entered the data, the rating effect shrank to a few points and stopped being significant. Rated carriers are mostly crash-only carriers (70% of crash-only carriers are rated vs. 19% of inspection-only), and within each group, rated and unrated carriers look alike. Adding the source control also took the model's R² from about 4% to about 14%, which shows how much of the pooled result was the label itself.

**Split by outcome:**

| Model | Sample | Outcome (base rate) | What predicts it |
|---|---|---|---|
| OOS risk | 429 inspected carriers | Any OOS violation (20.7%) | Nothing. Fleet size, mileage, operation type, and rating are all insignificant (R² about 1%) |
| Crash severity | 661 crashed carriers | Any injury or fatal crash (57.8%) | Intrastate non-hazmat carriers: +19.5 points. Having a safety rating: +8.5 points, borderline (R² about 1%) |

**What I'd tell a shipper:** in this corridor, fleet size, mileage, and safety rating don't reliably separate carriers that get OOS orders from carriers that don't. The one signal that held up is that, among carriers that had a crash, intrastate non-hazmat carriers were more likely to have a severe one. I wouldn't read much into it beyond "worth a closer look," since the models explain only about 1% of the variation.

### A finding I walked back

An earlier version of this project reported that high-risk carriers had a ~92% higher crash rate per million miles. I no longer stand behind that. Crash rate only exists for carriers with at least one crash, and `high_risk` requires an injury or fatal crash, so carriers with more crashes had more chances to qualify. Part of that gap is mechanical. I also originally wrote that high-risk carriers have double the fleet size of low-risk carriers, which came from the larger sample before the mileage filter and was driven by a few very large carriers. Among carriers with valid mileage, average fleet size is 49 trucks vs. 43 (medians 14 vs. 12).

---

## Limitations

- The regression sample is the 1,081 carriers with valid mileage, about 60% of the 1,816 carriers in the regional population. The excluded 735 are mostly crash-only carriers with missing census data, so the results don't speak for them.
- Each carrier averages roughly one inspection and one crash, so per-carrier rates are really single observations. Small carriers in particular swing wildly on one event.
- Carriers that show up in only one file are treated as having no event in the other, but that may just mean the other file didn't capture them. "Not flagged" can't be told apart from "not observed."
- All the models explain very little (R² of 1% to 14%). A weak result is still a result, but I can't claim to have found strong drivers of risk.
- Findings are specific to the NJ/NY/PA/DE/CT corridor.
- `SAFETY_RATING` is missing for about half of carriers, and the 4 carriers rated Unsatisfactory in the regression sample are too few to say anything about.
- Linear probability models are an approximation for a 0/1 outcome.

---

## Dashboard

I built an interactive Tableau dashboard with five linked, cross-filtered views: crash rate by risk group, fleet size vs. crash rate (log scale), risk rate by safety rating, risk rate by carrier operation, and a carrier lookup table. Click a bar in any summary chart and the table filters to match.

**Heads up:** the dashboard was built before I found the label problem described above. The risk-rate-by-rating and risk-rate-by-operation charts use the pooled `high_risk` flag, so they carry the same source-mix effect, and the crash-rate chart is the one I walked back. I'd read the dashboard as an exploration of the data rather than as evidence of what drives risk.

**Live dashboard:** https://public.tableau.com/app/profile/jt.mcgahran/viz/DOTCarrierRiskScorecard/ScorecardDashboard

---

## What's left

- [x] Build the Tableau dashboard
- [x] Run regressions and check them for confounding
- [ ] Rebuild the dashboard views around the split outcomes (OOS among inspected carriers, severe crashes among crashed carriers)
- [ ] Look at cargo type (`CRGO_*` fields) as another possible predictor
- [ ] Try a logistic regression, since the linear probability model is only an approximation

---

## Repo layout

```
/sql/          SQL scripts, in the order I ran them
               01 load + dedup census, 02 regional scope, 03 aggregate metrics,
               04 scorecard + labels, 05 mileage cleanup + exploratory comparisons,
               06 split outcomes (the datasets behind the regressions)
/excel/        regression workbook (Analysis ToolPak output)
/tableau/      the Tableau workbook
README.md      this file
```
