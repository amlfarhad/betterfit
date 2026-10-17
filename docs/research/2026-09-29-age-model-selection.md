# Biological-age model selection

Research date: 2026-09-29. This research review used public sources. The selected equation is now implemented in the [native engine](../engine-api.md); private account replay is documented separately.

## Recommendation

Implement the published **MoveIt! Age** equation locally for the first-release Biological Age feature, and describe the result as a **movement-based biological-age estimate**. Its variables are compatible with daily totals derived from Fitbit Air steps. This is an implementable research-derived estimate, not a clinically validated Fitbit Air measurement. The implementation can be numerically verified now; clinical validity for this device and individual cannot be established by unit tests.

Use the exact coefficients below. Do not blend in HRV, sleep, RHR, oxygen saturation, temperature, or invented mortality adjustments. Those signals remain useful elsewhere in the app, but this model assigns them no coefficients. Chronological age is a required input; sex and VO2 max are not.

## Published model and evidence

[Lu et al., GeroScience, DOI 10.1007/s11357-025-01999-7](https://pmc.ncbi.nlm.nih.gov/articles/PMC12972362/) reports:

- Training target: PhenoAge; NHANES 2005–2006 training/test sizes 6,064/1,516.
- Inputs: chronological age, maximum daily steps, and SD of daily steps across seven days.
- Final equation, after delta normalization:

```text
estimatedAge = 4.2390852
             + 1.0824163 * chronologicalAgeYears
             - 0.0012294 * maximumDailySteps
             + 0.0015739 * standardDeviationDailySteps
```

The reported 3.296652 normalization is already incorporated; do not apply it again. Define delta as estimated age minus chronological age; some figure captions reverse this subtraction, unlike the methods.

External evidence includes 55 MitoHealth participants (young group 20–30; older groups 65–80) and 145 geriatric rehabilitation patients. NHANES test RMSE 5.44 years is against chronological age, not biological-age ground truth. Training used hip ActiGraph; external measurements used thigh ActivPAL. Longitudinal intervention sensitivity remains unestablished.

The algorithm declaration specifies Apache 2.0 plus Commons Clause 1.0, with separate permission for commercial use. The article itself is copyright-restricted. Code and an explicit SD denominator were not located. The broad NHANES age description does not establish the exact complete-case derivation age range.

## Exact calculator contract for this app

The following are our transparent engineering decisions. They should be recorded in model metadata rather than presented as author-validated preprocessing.

1. Implemented model identifier: `moveit-age-2025-sample-sd-1.0.0`.
2. Supply age in years and exactly seven daily total step counts, each finite and nonnegative. Calculate from the most recent seven **consecutive, finished local-calendar days**, ending yesterday. Exclude the current partial day. Record the timezone and dates with the result.
3. For this adult app, require chronological age of at least 20. This conservative lower bound avoids treating the general NHANES age description as pediatric validation. Do not invent a sharp upper scientific-validity bound; document that representativeness and individual applicability remain uncertain, particularly outside studied adult populations.
4. Let `mean = sum(steps) / 7`, `maximumDailySteps = max(steps)`, and `standardDeviationDailySteps = sqrt(sum((steps[i] - mean)^2) / 6)`.
5. Apply the equation once, then `deltaYears = estimatedAge - chronologicalAgeYears`. Preserve full precision internally and round only for display.
6. Do not clamp the equation to chronological age or an arbitrary age range. A nonfinite prediction is unavailable. The implementation returns null/outOfDomain for predictions outside its product display range of 0–120, with an explicit reason; this is a display guard, not a scientific validation boundary. Unusually large or inconsistent activity records should fail source-quality checks rather than be winsorized without documentation.
7. If age, a complete daily total, or coverage evidence is missing, return a typed insufficient-data result with the missing dates/reason. Do not insert zero, extrapolate four days into a week, or borrow a nearby seven-day window without telling the user.

**SD qualification:** using the sample SD is a documented convention, not proof of an exact replication of the authors' preprocessing. The paper reports analysis in R; [R's `sd` documentation](https://stat.ethz.ch/R-manual/R-devel/library/stats/html/sd.html) specifies denominator `n - 1`. The review did not locate an author script or supplement resolving that remaining ambiguity. Changing to population SD later must change the model version and regenerate historical scores.

**Age input:** prefer age calculated for the window end date from a user-supplied date of birth; if only a whole-year age is supplied, retain that precision and provenance. Do not pretend a whole-year age is an exact decimal age. This is also an implementation decision.

## Sparse positive-step intervals and coverage

No minute-level zero filling is needed to calculate the daily total from a complete list of positive step-count intervals. Sum the counts after source selection, deduplication, and local-date grouping. However, an empty API response cannot by itself distinguish zero movement from missing data. A date without a complete successful query and credible wear/coverage evidence is missing, not a zero-step day.

Required adapter behavior:

- Fetch every page successfully; distinguish an explicit complete empty result from an API error or unfinished pagination.
- Use a single selected device/source or the API's documented deduplicated total. Never add both a daily aggregate and its intraday components or mix overlapping devices.
- Deduplicate repeated records by stable record identity. Reject conflicting overlapping intervals rather than double-counting them.
- Use the user's local calendar boundaries, including 23/25-hour daylight-saving days. Do not split days using UTC timestamps alone. Do not prorate an interval spanning midnight as if steps were uniformly distributed unless the API provides finer resolution or explicitly supports that interpretation.
- Cross-check the interval total against a trustworthy daily aggregate when available. A discrepancy should be visible in adapter diagnostics.
- The implemented conservative guard is at least **90% integrated heart-rate time coverage on each closed local day**, plus complete step-query coverage. Integrate only consecutive valid samples at most 60 seconds apart, without trailing extrapolation, and divide by the actual local-day duration including DST. This replaces the initial 1,200-minute-bin proposal, which could overstate coverage when isolated samples touched many minutes. This is our coverage heuristic, not a validated Fitbit wear-time algorithm or a published MoveIt! rule; it cannot prove that all movement was recorded. Store observed HR seconds, day duration, query completeness, canonical source policy and rejection reasons separately.

Requiring a whole week is a quality gate inside the first-release feature, not deferring the feature. Show the Biological Age card and collection progress while the week accumulates; release the numeric estimate only when inputs meet the declared contract.

## Reference arithmetic and tests

These are synthetic verification cases, not user data or author-provided validation subjects. Expected values were independently calculated with Python `decimal` at 40 digits of precision on 2026-09-29.

| Age | Seven daily totals | Sample SD | Expected age | Expected delta |
| --- | --- | --- | --- | --- |
| 40 | 8000, 8000, 8000, 8000, 8000, 8000, 8000 | 0 | 37.7005372 | -2.2994628 |
| 40 | 2000, 4000, 6000, 8000, 10000, 12000, 14000 | 4320.4937989385734873 | 37.1241623901494208 | -2.8758376098505792 |
| 30 | 0, 0, 0, 0, 0, 0, 0 | 0 | 36.7115742 | 6.7115742 |

The zero-step case tests arithmetic only: the app must not infer those zeros from missing records. Absolute tolerance `1e-9` years is sufficient for these double-precision cases. Check invalid age, nonfinite/negative counts, wrong count length, missing dates, duplicate local dates, partial current day, API pagination failure, timezone boundaries, and repeated/overlapping step intervals. Confirm the adapter refuses an insufficient week rather than producing a number. Tests should separately verify sample SD and catch accidental second normalization.

The equation's local sensitivities are algebraic consequences, not causal effects: +1,000 maximum steps holding SD fixed changes output by -1.2294 years; +1,000 SD holding maximum fixed changes it by +1.5739 years. Since changing a real day often changes both features, do not turn these into independent year-contribution tiles or promise that a particular extra walk reverses aging.

## Honest interpretation and display

Suggested card title: **Biological Age**. Required adjacent qualifier: **Movement estimate**. Suggested detail copy: “Calculated from your age and a week of daily step patterns using the published MoveIt! Age equation. This Fitbit adaptation has not been clinically validated.”

Show the age estimate, chronological comparison, model version, contributing weekly measurements, dates, and coverage. Show HRV/sleep/RHR trends separately; do not imply that they affect this age number. No calibrated personal confidence interval is available. Coverage is not statistical confidence. Do not show RMSE as an individual's ± error bar.

Our appraisal: a model that includes chronological age can correlate strongly with chronological age by construction, so the correlation alone is weak evidence of independent biological information. A biomarker association is not proof of individual diagnostic accuracy. A step-driven estimate cannot distinguish improved health from many non-health changes in walking behavior, travel, weather, job demands, measurement error, or temporary limitation. Weekly changes are changes in the model's estimate, not measured years of rejuvenation. This limitation should remain understandable in the feature rather than hidden in a generic disclaimer.

## Licensing and implementation provenance

For a local personal, noncommercial app, an independently written calculator with paper attribution is a reasonable implementation route. Keep the published licensing statement visible in research/attribution records; do not describe the model as unrestricted open source or claim commercial clearance. Do not copy the article's prose, graphics, or unavailable author source code.

[Commons Clause's own text and FAQ](https://commonsclause.com/) restrict selling the licensed software as defined there and require preservation of its notice; they expressly distinguish source availability from open source. The paper's statement is broader about commercial use, so any later distribution/commercialization should resolve the applicable terms rather than rely on an assumption. [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0) contains notice, attribution, and distribution conditions if licensed material is redistributed.

An original implementation of a factual equation is distinct from copying protected software or article expression. The [U.S. Copyright Office](https://www.copyright.gov/circs/circ33.pdf) distinguishes underlying methods/systems from copyrightable explanations; its [computer-program guidance](https://www.copyright.gov/register/tx-programs.html) excludes algorithms and logic from copyright protection. These general sources do not establish patent clearance, settle every jurisdiction, or authorize reuse of protected source code. No commercial release is assumed here.

## Why other routes were not selected

- **GeroSense:** well matched input categories, but no public downloadable inference weights were located. The [2021 paper](https://www.aging-us.com/article/202816/text) says data/code are available from the authors on reasonable request. Current [architecture documentation](https://developer.gerosense.ai/getting-started/architecture-overview) requires credentials and server-to-server API inference; its Docker image is a proxy, not an offline released model. A [free research app](https://www.gerosense.ai/studies) does not establish a free local SDK. Do not reconstruct weights from the architecture description or send private measurements to the service without separate authorization.
- **Original MoveAge:** the [2021 predecessor](https://www.frontiersin.org/journals/aging/articles/10.3389/fragi.2021.708680/full) uses hourly accelerometer intensity features and random forests. It is not the same model as MoveIt! Age. Do not feed step totals into intensity features.
- **CosinorAge / PPG clocks:** retain the incompatibility findings in the earlier feasibility memo: Air's available steps and HR samples do not supply the required raw acceleration or optical waveform. Published raw-waveform models do not solve that input mismatch.
- **Reverse HRV norms or fitness age:** an age norm is not automatically a biological-aging predictor; inversion of a noisy age regression is not a validated clock. Avoid substituting an HRV age or predicted fitness age under this label.
- **New public-data training:** feasible as a research project, but unnecessary for implementing the selected published equation and unable to establish Fitbit Air validity immediately. The [CDC PAXRAW_D codebook](https://wwwn.cdc.gov/Nchs/Data/Nhanes/Public/2005/DataFiles/PAXRAW_D.htm) confirms minute-level `PAXSTEP` and a different `PAXINTEN` field, hip placement, waking wear, and reliability/calibration flags. Rebuilding a model would require public-data cleaning, a preregistered target, subject-level holdout, age-stratified evaluation, survey design handling, and separate device-transfer validation. Do not claim a newly trained model inherits another paper's validation.

## Remaining limits, not missing coefficients

The numeric equation is fully available. Remaining uncertainties are SD convention, precise original preprocessing and complete-case age bounds, step-measurement transfer to Fitbit Air, longitudinal responsiveness, and individual calibration. A first release can implement and verify this research-derived calculation while being explicit about these limits. It cannot truthfully promise a clinically validated biological age for the particular user or device merely because the engine passes arithmetic tests.
