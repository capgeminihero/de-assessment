"Which indexes help?"

Delta Lake doesn't have traditional indexes. Instead:

ZORDER BY — physically sorts data in files so queries that filter on show_id or season skip most files without reading them
Partitioning — the silver tables are split by show_id, so a query for one show only touches that folder
Column statistics — Delta automatically tracks min/max per column, so WHERE runtime > 0 skips any file where max(runtime) is 0

"Why do predicates filter early?"

Filters like WHERE genre != 'Unknown' and WHERE runtime > 0 are pushed down to the file scan level. This means Databricks checks the statistics before loading any data into memory — rows that can't match are never read at all. Less I/O = faster query.

"Why do CTEs help?"

In Query 3, the two CTEs (active_shows and episode_stats) filter the data before the join. So instead of joining two large raw tables, you're joining two already-filtered smaller sets. Less data shuffled across the cluster = faster. Also the Gold layer itself is a pre-materialised CTE — the ADF pipeline computes heavy aggregations once nightly so analysts never wait for them.

That's everything you need to say if asked. Ready to move to Part 6?