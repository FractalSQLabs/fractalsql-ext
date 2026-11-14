-- Parity cases for the enterprise-gated multimodal portfolio table functions, through the mock enterprise core.

-- dormant without the library
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2);

SELECT * FROM fractal_optimize_portfolio_multimodal_pareto([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, n_restarts := 2);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 1, n_restarts := 5, overlap_threshold := 0.3, quality_frac := 0.8, seed := 7);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, use_obl := true, diffusion_mode := 'levy');

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT count(*), round(sum(sharpe), 6), sum(len(weights)) FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, n_restarts := 64);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, n_restarts := 0);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, n_restarts := 65);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, diffusion_mode := 'brownian');

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([]::DOUBLE[], []::DOUBLE[], 1);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2]::DOUBLE[], [0.04,0,0]::DOUBLE[], 1);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2]::DOUBLE[], [0.04,0,0,0.09]::DOUBLE[], 3);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal(NULL::DOUBLE[], [0.04]::DOUBLE[], 1);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1]::DOUBLE[], [0.04]::DOUBLE[], NULL);

-- an enterprise core without the extended entry point: plain calls work, OBL/Levy knobs are refused
-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise_noex}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise_noex}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, use_obl := true);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise_noex}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, diffusion_mode := 'levy');

-- a core with only the extended entry point, and one with neither
-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise_nomm}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise_none}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2);

-- pareto
-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal_pareto([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal_pareto([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, n_restarts := 5, max_front := 2, seed := 3, use_obl := true, diffusion_mode := 'levy');

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal_pareto([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, n_restarts := 2, max_front := 3);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal_pareto([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, max_front := 0);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal_pareto([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, n_restarts := 0);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal_pareto([0.1, 0.2]::DOUBLE[], [0.04,0,0]::DOUBLE[], 1);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT * FROM fractal_optimize_portfolio_multimodal_pareto([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, diffusion_mode := 'x');

-- joined with a table of problems
-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT count(*) FROM fractal_optimize_portfolio_multimodal([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2) m, range(4) r;
