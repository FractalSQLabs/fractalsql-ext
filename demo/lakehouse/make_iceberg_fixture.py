# Writes the support-ticket Iceberg table used by demo-lakehouse-iceberg.sql.
#
# 240 tickets in four topic clusters, each with an 8-dimensional embedding
# stored as list<double> (the common shape from embedding pipelines).
# Deterministic: the same seed writes the same table every run.
#
# The table lands at $LAKE_DIR/wh/support/tickets. $LAKE_DIR/tickets.metadata.json
# is a copy of its current metadata file, which is the path the demo reads.
# Run in the lake-fixture compose service, or on a host with pyiceberg,
# pyarrow and sqlalchemy installed.
import os
import random
import shutil

import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import DoubleType, ListType, LongType, NestedField, StringType

LAKE = os.environ.get("LAKE_DIR", "/lake")
WAREHOUSE = os.path.join(LAKE, "wh")
DIM = 8
PER_CLUSTER = 60
CLUSTERS = {
    "billing": ([1.0, 0.2, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0],
                ["Charged twice for my renewal", "Invoice total does not match my plan",
                 "Refund still not applied to my card"]),
    "login": ([0.0, 1.0, 0.3, 0.0, 0.0, 0.1, 0.0, 0.0],
              ["Locked out after password reset", "Two-factor code never arrives",
               "Cannot sign in from the mobile app"]),
    "shipping": ([0.0, 0.0, 0.0, 1.0, 0.2, 0.0, 0.3, 0.0],
                 ["Parcel marked delivered but not received", "Tracking stuck in transit",
                  "Wrong address on the shipping label"]),
    "outage": ([0.1, 0.0, 0.0, 0.0, 0.0, 1.0, 0.2, 0.6],
               ["Dashboard returns 503 for all users", "API requests timing out since this morning",
                "Status page shows degraded service"]),
}

rng = random.Random(7)
ids, segments, bodies, vectors = [], [], [], []
next_id = 1
for segment, (center, templates) in CLUSTERS.items():
    for _ in range(PER_CLUSTER):
        vec = [c + rng.gauss(0.0, 0.08) for c in center]
        ids.append(next_id)
        segments.append(segment)
        bodies.append(rng.choice(templates))
        vectors.append(vec)
        next_id += 1

catalog = SqlCatalog("lake", uri="sqlite:///" + os.path.join(LAKE, "catalog.db"),
                     warehouse="file://" + WAREHOUSE)
catalog.create_namespace_if_not_exists("support")
try:
    catalog.drop_table("support.tickets")
except Exception:
    pass

schema = Schema(
    NestedField(1, "ticket_id", LongType(), required=False),
    NestedField(2, "segment", StringType(), required=False),
    NestedField(3, "body", StringType(), required=False),
    NestedField(4, "emb", ListType(5, DoubleType(), element_required=False), required=False),
)
table = catalog.create_table("support.tickets", schema=schema)
table.append(pa.table({
    "ticket_id": pa.array(ids, pa.int64()),
    "segment": segments,
    "body": bodies,
    "emb": pa.array(vectors, pa.list_(pa.float64())),
}))

metadata_dir = os.path.join(WAREHOUSE, "support", "tickets", "metadata")
latest = sorted(f for f in os.listdir(metadata_dir) if f.endswith(".metadata.json"))[-1]
shutil.copyfile(os.path.join(metadata_dir, latest), os.path.join(LAKE, "tickets.metadata.json"))
print("iceberg table ready:", os.path.join(LAKE, "tickets.metadata.json"), "rows:", len(ids))
