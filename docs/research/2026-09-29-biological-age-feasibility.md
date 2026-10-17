# Biological age from Fitbit Air: feasibility audit

Date: 2026-09-29. Research findings, not a validated scoring implementation.

**Historical audit, superseded for model selection:** the subsequent [MoveIt! Age review](2026-09-29-age-model-selection.md) resolved the missing equation and selected the first-release model. The [native engine](../engine-api.md) is implemented and tested. Statements below about unresolved coefficients or a proposed 28-day age window describe the earlier investigation; the implemented age window is seven closed days. Device and clinical validity remain separate unresolved research questions.

## Binding product requirements

- Amal wants their own subscription-free native iPhone app.
- Biological age is required in the first release, alongside recovery, strain, sleep, trends, and widgets. Do not defer or replace it with an unrelated feature.
- No LLM, chat service, required blood tests, health-record import, or paid third-party age-scoring service.
- Bevel is a reference, not a proposed alternative product.

## Conclusion

A wearable-derived biological-age estimate is technically plausible from the types of data Fitbit Air exposes. Published research has estimated age acceleration from minute-level steps and includes Fitbit recordings. However, this research does not validate a new Fitbit Air implementation automatically. This audit did not establish a freely downloadable, pretrained, validated model that can directly consume the available Fitbit Air API data. This distinction remains an implementation requirement, not a reason to drop biological age from scope.

## Accessible inputs

Google's Air compatibility list includes steps, heart rate, resting heart rate, HRV, sleep, exercise, active zone minutes, respiratory rate, temperature, oxygen saturation, and VO2 max. The API describes one-minute storage resolution for steps. Actual completeness and historical coverage must be checked against Amal's account. A supported VO2 max type does not guarantee that a usable estimate has been generated.

Sleep duration and sleep/wake timing can support duration/regularity features; steps and heart-rate data can support activity-volume and intensity features. Demographics required by the chosen model must be supplied explicitly. Workout labels may support strength-session frequency but cannot measure muscle mass. Body fat and lean mass are not measurements made by the Air itself.

The documented public data types do not provide raw optical PPG waveforms or the raw accelerometer/ENMO signal required by some research clocks. Do not substitute heart-rate samples for PPG, or step counts for acceleration magnitude.

## Candidate approaches audited

| Approach | Evidence and inputs | Suitability for our app |
| --- | --- | --- |
| Bevel-style physiological estimate | Bevel describes four-week summaries of sleep, movement, cardio intensity, fitness, resting heart rate, and lean body mass, linked to mortality hazard ratios with adjustment for correlated factors. | Air supplies several relevant inputs. The page does not disclose a complete reproducible model, coefficients, or covariance adjustment. We can develop an independent estimate, but must label its unvalidated status and cannot claim equivalence. |
| GeroSense step-based age acceleration | Peer-reviewed 2021 paper uses steps per minute over seven-day windows, demographics, domain adaptation, and learned model parameters; longitudinal analyses include Fitbit users. | Strong evidence that the data category is feasible. No downloadable trained weights were established in this audit. Architecture descriptions alone are insufficient for faithful reproduction; published evidence is not a license to invent missing parameters. |
| CosinorAge | Open implementation and model parameters use circadian features of minute-level ENMO accelerometry. | The necessary acceleration signal is not documented in Air's API. Feeding steps into the existing coefficients would be an unvalidated change of measurement. |
| PpgAge | 2025 Apple study uses wrist PPG waveforms. Its code availability statement provides untrained models and training scripts. | Air API heart-rate summaries are not interchangeable with raw waveforms. No direct reusable pretrained path was established. |
| PhenoAge | Blood-based formula needs age and laboratory biomarkers. | Does not meet the wearable-only requirement. Do not impute blood tests from Fitbit summaries. |

GeroSense's own discussion also distinguishes reversible stress-related age acceleration from the underlying aging process. A displayed age estimate should not be described as literal tissue age, remaining lifespan, or evidence that a short-term lifestyle change caused years of rejuvenation.

## Proposed first-release feature contract

Include a prominent Biological Age card with an explicit wearable-estimate label, chronological-age comparison, historical trend, and a detail view of contributing measurements. Use multi-week aggregation rather than implying meaningful minute-to-minute changes. A 28-day window with weekly updates is a candidate product choice, not a validated requirement of every model.

Choose and document the algorithm before a numeric score is shipped. Prefer a fully specified statistical model with compatible measurements, lawful local use, and known evaluation results. If a custom deterministic physiological estimate is used, describe it as experimental and document references, cohort limitations, coefficients, missing-data rules, and model version. Related activity/fitness factors cannot simply have independent hazard ratios multiplied together or arbitrary years added/subtracted.

Show observed input coverage and freshness separately from statistical uncertainty. A completeness percentage is not a calibrated confidence interval. Do not fabricate age precision, confidence bands, or per-factor year contributions. Validate calculations against reference cases and assess the model separately on appropriate held-out data before making accuracy claims.

No subscription or inference service is inherently required to run a formula or a suitably licensed small model locally. This audit did not verify Google Health API pricing; do not confuse it with the separate Google Cloud Healthcare API pricing pages.

## Installation consideration

Apple supports personal-device testing with a free Personal Team, but its documentation says provisioning expires after seven days, requiring rebuild/reinstall. A no-subscription app does not remove Apple's signing requirements. Widget/app-group capability availability must be verified for the chosen signing route. No paid membership, service, or purchase has been authorized.

## Next implementation decisions

1. Keep biological age in the first-release design and success criteria.
2. Audit real Air data coverage after OAuth setup and user authorization.
3. Select/specify an age model that matches the exposed measurements and the local/no-subscription constraints. The precise numeric algorithm remains unresolved; this is the main scientific work item.
4. Implement the native app, scoring engine, biological-age detail screen, and tests only after the design stage is satisfied.

## Primary sources

- [Google Health: device compatibility](https://developers.google.com/health/data-types/device-compatibility)
- [Google Health: data types and sampling resolution](https://developers.google.com/health/data-types)
- [Bevel: physiological age factors](https://www.bevel.health/blog/physiological-age-factors)
- [Bevel: biological age and confidence](https://help.bevel.health/en/articles/11586369)
- [Pyrkov et al. (2021), Deep longitudinal phenotyping of wearable sensor data reveals independent markers of longevity, stress, and resilience](https://www.aging-us.com/article/202816/text)
- [CosinorAge author repository](https://github.com/ADAMMA-CDHI-ETH-Zurich/CosinorAge)
- [CosinorAge methods and input specification](https://cosinorage.readthedocs.io/en/latest/theoretical_background.html)
- [Miller et al. (2025), A wearable-based aging clock associates with disease and behavior](https://www.nature.com/articles/s41467-025-64275-4)
- [Apple: personal-team installation and provisioning](https://developer.apple.com/help/account/basics/about-your-developer-account)
