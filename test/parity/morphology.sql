-- Parity cases for the morphology part of fsql_sovereign.c.

-- vascular network: a small branching tree (nodes as x,y,z; edges as node-index pairs)
SELECT fractal_vascular_network([0,0,0, 1,0,0, 2,1,0, 2,-1,0, 3,1,1]::DOUBLE[], [0,1, 1,2, 1,3, 2,4]::BIGINT[], [1.0, 1.5, 1.4, 1.8]::DOUBLE[]);

SELECT v.mean_tortuosity, v.branch_density, v.fractal_dimension FROM (SELECT fractal_vascular_network([0,0,0, 1,0,0, 2,1,0, 2,-1,0, 3,1,1]::DOUBLE[], [0,1, 1,2, 1,3, 2,4]::BIGINT[], [1.0, 1.5, 1.4, 1.8]::DOUBLE[]) AS v);

SELECT fractal_vascular_network([0,0,0, 1,0,0]::DOUBLE[], [0,1]::BIGINT[], [1.0]::DOUBLE[]);

SELECT fractal_vascular_network([0,0]::DOUBLE[], [0,1]::BIGINT[], [1.0]::DOUBLE[]);

SELECT fractal_vascular_network([0,0,0, 1,0,0]::DOUBLE[], [0,1,0]::BIGINT[], [1.0]::DOUBLE[]);

SELECT fractal_vascular_network([0,0,0, 1,0,0]::DOUBLE[], [0,1]::BIGINT[], [1.0, 2.0]::DOUBLE[]);

SELECT fractal_vascular_network([0,0,0, 1,0,0]::DOUBLE[], [0,5]::BIGINT[], [1.0]::DOUBLE[]);

SELECT fractal_vascular_network([0,0,0, 1,0,0]::DOUBLE[], [-1,1]::BIGINT[], [1.0]::DOUBLE[]);

SELECT fractal_vascular_network(NULL::DOUBLE[], [0,1]::BIGINT[], [1.0]::DOUBLE[]), fractal_vascular_network([0,0,0, 1,0,0]::DOUBLE[], NULL::BIGINT[], [1.0]::DOUBLE[]), fractal_vascular_network([0,0,0, 1,0,0]::DOUBLE[], [0,1]::BIGINT[], NULL::DOUBLE[]);

SELECT fractal_vascular_network([0,0,0, 1,NULL,0]::DOUBLE[], [0,1]::BIGINT[], [1.0]::DOUBLE[]);

SELECT fractal_vascular_network([0,0,0, 1,0,0]::DOUBLE[], [0,NULL]::BIGINT[], [1.0]::DOUBLE[]);

-- cortical folding: a tetrahedron
SELECT fractal_cortical_folding([0,0,0, 1,0,0, 0,1,0, 0,0,1]::DOUBLE[], [0,1,2, 0,1,3, 0,2,3, 1,2,3]::BIGINT[]);

SELECT c.gyrification_index FROM (SELECT fractal_cortical_folding([0,0,0, 1,0,0, 0,1,0, 0,0,1]::DOUBLE[], [0,1,2, 0,1,3, 0,2,3, 1,2,3]::BIGINT[]) AS c);

SELECT fractal_cortical_folding([0,0,0, 1,0,0, 0,1,0]::DOUBLE[], [0,1,2]::BIGINT[]);

SELECT fractal_cortical_folding([0,0,0, 1,0,0]::DOUBLE[], [0,1,2]::BIGINT[]);

SELECT fractal_cortical_folding([0,0,0, 1,0,0, 0,1,0, 0,0,1]::DOUBLE[], [0,1]::BIGINT[]);

SELECT fractal_cortical_folding([0,0,0, 1,0,0, 0,1,0, 0,0,1]::DOUBLE[], [0,1,9]::BIGINT[]);

SELECT fractal_cortical_folding(NULL::DOUBLE[], [0,1,2]::BIGINT[]), fractal_cortical_folding([0,0,0]::DOUBLE[], NULL::BIGINT[]);

-- nerve plexus metric
SELECT fractal_nerve_plexus_metric([0,0, 1,0, 1,1, 0,1]::DOUBLE[], 2, [0,1, 1,2, 2,3, 3,0]::BIGINT[]);

SELECT fractal_nerve_plexus_metric([0,0,0, 1,0,0, 1,1,0]::DOUBLE[], 3, [0,1, 1,2]::BIGINT[]);

SELECT fractal_nerve_plexus_metric([0, 1, 2, 3]::DOUBLE[], 1, [0,1, 1,2, 2,3]::BIGINT[]);

SELECT fractal_nerve_plexus_metric([0,0, 1,0]::DOUBLE[], 0, [0,1]::BIGINT[]);

SELECT fractal_nerve_plexus_metric([0,0, 1,0]::DOUBLE[], 4, [0,1]::BIGINT[]);

SELECT fractal_nerve_plexus_metric([0,0, 1]::DOUBLE[], 2, [0,1]::BIGINT[]);

SELECT fractal_nerve_plexus_metric([]::DOUBLE[], 2, [0,1]::BIGINT[]);

SELECT fractal_nerve_plexus_metric([0,0, 1,0]::DOUBLE[], 2, [0,1,0]::BIGINT[]);

SELECT fractal_nerve_plexus_metric([0,0, 1,0]::DOUBLE[], 2, [0,7]::BIGINT[]);

SELECT fractal_nerve_plexus_metric(NULL::DOUBLE[], 2, [0,1]::BIGINT[]), fractal_nerve_plexus_metric([0,0, 1,0]::DOUBLE[], NULL, [0,1]::BIGINT[]), fractal_nerve_plexus_metric([0,0, 1,0]::DOUBLE[], 2, NULL::BIGINT[]);

-- morphological complexity
SELECT fractal_morphological_complexity(flatten(list_transform(range(10), lambda x: list_transform(range(10), lambda y: [x * 0.1, y * 0.1])))::DOUBLE[], 2);

SELECT m.dimension, m.lacunarity FROM (SELECT fractal_morphological_complexity(flatten(list_transform(range(12), lambda x: list_transform(range(12), lambda y: [x * 0.07 + (y % 2) * 0.01, y * 0.05])))::DOUBLE[], 2) AS m);

SELECT fractal_morphological_complexity(list_transform(range(50), lambda i: i * 0.02)::DOUBLE[], 1);

SELECT fractal_morphological_complexity([1.0, 2.0, 3.0]::DOUBLE[], 2);

SELECT fractal_morphological_complexity([]::DOUBLE[], 2);

SELECT fractal_morphological_complexity([1.0, 2.0]::DOUBLE[], 0);

SELECT fractal_morphological_complexity([1.0, 2.0]::DOUBLE[], 4);

SELECT fractal_morphological_complexity([1.0, 2.0, 3.0, 4.0]::DOUBLE[], 2);

SELECT fractal_morphological_complexity(NULL::DOUBLE[], 2), fractal_morphological_complexity([1.0, 2.0]::DOUBLE[], NULL);

-- many rows
CREATE TABLE g AS SELECT i, flatten(list_transform(range(10), lambda x: list_transform(range(10), lambda y: [x * 0.1 + i * 0.001, y * 0.1])))::DOUBLE[] AS pts FROM range(1, 300) t(i);
SELECT count(*), round(sum(fractal_morphological_complexity(pts, 2).dimension), 6), round(sum(fractal_morphological_complexity(pts, 2).lacunarity), 6) FROM g;

-- typing
SELECT typeof(fractal_vascular_network([0,0,0, 1,0,0]::DOUBLE[], [0,1]::BIGINT[], [1.0]::DOUBLE[])), typeof(fractal_morphological_complexity([1.0]::DOUBLE[], 1));
