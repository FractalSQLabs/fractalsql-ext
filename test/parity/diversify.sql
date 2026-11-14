-- Parity cases for diversify / feedback (fsql_sovereign.c). They act on the calling connection's core context.

SELECT fractal_diversify_enable();

SELECT fractal_diversify_disable();

SELECT fractal_diversify_enable();
SELECT fractal_explain_result();

-- expect: ""diversify_enabled"":false
SELECT fractal_diversify_enable();
SELECT fractal_diversify_disable();
SELECT fractal_explain_result();

-- no search has run on this context yet, so D_q is NULL/NaN
SELECT fractal_detect_collapse();

-- (spec, from the current C++ source: a fresh connection starts disabled; the stale reference binary says true)
-- expect: ""diversify_enabled"":false
SELECT fractal_explain_result();

SELECT fractal_diversify_set_params();

SELECT fractal_diversify_set_params(20);

SELECT fractal_diversify_set_params(20, 0.2);

SELECT fractal_diversify_set_params(20, 0.2, 1.5);

SELECT fractal_diversify_set_params(20, 0.2, 1.5, 0.3);

SELECT fractal_diversify_set_params(20, 0.2, 1.5, 0.3, 8);

SELECT fractal_diversify_set_params(20, 0.2, 1.5, 0.3, 8, 128);

-- NULL leaves a field alone
SELECT fractal_diversify_set_params(NULL, 0.2, NULL, 0.3, NULL, NULL);

-- the core validates ranges
SELECT fractal_diversify_set_params(0);

SELECT fractal_diversify_set_params(-5);

SELECT fractal_diversify_set_params(20, -1.0);

SELECT fractal_diversify_set_params(20, 0.2, 'nan'::DOUBLE);

SELECT fractal_diversify_set_params(2000000000, 0.2, 1.0, 1.0, 2000000000, 2000000000);

-- feedback
SELECT fractal_feedback_report(1, 'positive');

SELECT fractal_feedback_report(1, 'negative');

SELECT fractal_feedback_report(1, 'dwell', 250);

SELECT fractal_feedback_report(1, 'dwell');

SELECT fractal_feedback_report(0, 'positive'), fractal_feedback_report(9999999999, 'negative');

SELECT fractal_feedback_report(-1, 'positive');

SELECT fractal_feedback_report(1, 'maybe');

SELECT fractal_feedback_report(1, '');

SELECT fractal_feedback_report(NULL, 'positive'), fractal_feedback_report(1, NULL), fractal_feedback_report(NULL, NULL, NULL);

SELECT fractal_feedback_report(1, 'dwell', NULL);

SELECT fractal_isolate_background(5);

SELECT fractal_isolate_background(0), fractal_isolate_background(9999999999);

SELECT fractal_isolate_background(-1);

SELECT fractal_isolate_background(NULL);

-- many rows
SELECT count(fractal_feedback_report(i, 'positive')) FROM range(3000) t(i);

SELECT count(fractal_isolate_background(i)) FROM range(3000) t(i);

-- typing
SELECT typeof(fractal_diversify_enable()), typeof(fractal_detect_collapse()), typeof(fractal_explain_result()), typeof(fractal_feedback_report(1, 'dwell'));
