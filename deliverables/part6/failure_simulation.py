# Databricks notebook source
# MAGIC %md
# MAGIC # Part 6: Failure Simulation
# MAGIC
# MAGIC Deliberately writes invalid data to trigger Delta constraint violations.
# MAGIC Each cell demonstrates a specific constraint type being enforced at the storage level.
# MAGIC
# MAGIC **Purpose:** Prove that the Delta constraints added in Bronze/Silver/Gold notebooks actively reject bad data.

# COMMAND ----------

# DBTITLE 1,Configuration
dbutils.widgets.text("catalog", "de_assessment_dev")
CATALOG = dbutils.widgets.get("catalog")

from pyspark.sql import functions as F
from pyspark.sql.types import StructType, StructField, IntegerType, LongType, StringType, DoubleType

print(f"Testing constraints on catalog: {CATALOG}")

# COMMAND ----------

# MAGIC %md
# MAGIC ### Test 1: NOT NULL constraint violation
# MAGIC Attempt to insert a row with `id = NULL` into `bronze_shows`.

# COMMAND ----------

# DBTITLE 1,Simulate NOT NULL violation on bronze_shows
# Create a DataFrame with a null show id — matches table's BIGINT type
bad_data = spark.createDataFrame(
    [(None, "Fake Show")],
    StructType([
        StructField("id", LongType(), True),
        StructField("name", StringType(), True),
    ])
)

try:
    bad_data.write.format("delta").mode("append").saveAsTable(f"{CATALOG}.bronze.bronze_shows")
    print("ERROR: Write should have been rejected but succeeded!")
except Exception as e:
    print("NOT NULL constraint enforced successfully!")
    print(f"Error type: {type(e).__name__}")
    print(f"Message: {e}")

# COMMAND ----------

# MAGIC %md
# MAGIC ### Test 2: CHECK constraint violation (negative ID)
# MAGIC Attempt to insert a row with `id = -1` into `bronze_shows`, violating the `valid_show_id CHECK (id > 0)` constraint.

# COMMAND ----------

# DBTITLE 1,Simulate CHECK constraint violation on bronze_shows
# Create a DataFrame with a negative show id — violates CHECK (id > 0)
bad_data = spark.createDataFrame(
    [(-1, "Invalid Show")],
    StructType([
        StructField("id", LongType(), True),
        StructField("name", StringType(), True),
    ])
)

try:
    bad_data.write.format("delta").mode("append").saveAsTable(f"{CATALOG}.bronze.bronze_shows")
    print("ERROR: Write should have been rejected but succeeded!")
except Exception as e:
    print("CHECK constraint (id > 0) enforced successfully!")
    print(f"Error type: {type(e).__name__}")
    print(f"Message: {e}")

# COMMAND ----------

# MAGIC %md
# MAGIC ### Test 3: CHECK constraint violation (negative runtime)
# MAGIC Attempt to insert an episode with `runtime = -1` into `silver_episodes`, violating `valid_runtime CHECK (runtime > 0)`.

# COMMAND ----------

# DBTITLE 1,Simulate CHECK constraint violation on silver_episodes
# Create a DataFrame with negative runtime
bad_episode = spark.createDataFrame(
    [(99999, 1, "Bad Episode", 1, 1, "2024-01-01", -1)],
    StructType([
        StructField("episode_id", IntegerType(), True),
        StructField("show_id", IntegerType(), True),
        StructField("episode_name", StringType(), True),
        StructField("season", IntegerType(), True),
        StructField("episode_number", IntegerType(), True),
        StructField("airdate", StringType(), True),
        StructField("runtime", IntegerType(), True),
    ])
)

try:
    bad_episode.write.format("delta").mode("append").saveAsTable(f"{CATALOG}.silver.silver_episodes")
    print("ERROR: Write should have been rejected but succeeded!")
except Exception as e:
    print("CHECK constraint (runtime > 0) enforced successfully!")
    print(f"Error type: {type(e).__name__}")
    print(f"Message: {e}")

# COMMAND ----------

# MAGIC %md
# MAGIC ### Test 4: CHECK constraint violation on Gold (zero episode count)
# MAGIC Attempt to insert a row with `episode_count = 0` into `gold.episodes_per_season`, violating `valid_episode_count CHECK (episode_count > 0)`.

# COMMAND ----------

# DBTITLE 1,Simulate CHECK constraint violation on gold.episodes_per_season
# Create a DataFrame with zero episode count — violates CHECK (episode_count > 0)
# Match exact table types: show_id (INT), season (INT), episode_count (LONG), avg_runtime_mins (DOUBLE), rank_in_show (INT)
bad_gold = spark.createDataFrame(
    [(999, 1, 0, 30.0, 1)],
    StructType([
        StructField("show_id", IntegerType(), True),
        StructField("season", IntegerType(), True),
        StructField("episode_count", LongType(), True),
        StructField("avg_runtime_mins", DoubleType(), True),
        StructField("rank_in_show", IntegerType(), True),
    ])
)

try:
    bad_gold.write.format("delta").mode("append").saveAsTable(f"{CATALOG}.gold.episodes_per_season")
    print("ERROR: Write should have been rejected but succeeded!")
except Exception as e:
    print("CHECK constraint (episode_count > 0) enforced successfully!")
    print(f"Error type: {type(e).__name__}")
    print(f"Message: {e}")

# COMMAND ----------

# MAGIC %md
# MAGIC ### Test 5: Schema enforcement (mergeSchema rejects type conflicts)
# MAGIC Attempt to write a DataFrame with incompatible column types.

# COMMAND ----------

# DBTITLE 1,Simulate schema type conflict
# Create a DataFrame where 'id' is a string instead of integer
bad_schema = spark.createDataFrame(
    [("not_a_number", "Schema Conflict Show")],
    StructType([
        StructField("id", StringType(), True),
        StructField("name", StringType(), True),
    ])
)

try:
    bad_schema.write.format("delta").mode("append") \
        .option("mergeSchema", "false") \
        .saveAsTable(f"{CATALOG}.bronze.bronze_shows")
    print("ERROR: Write should have been rejected but succeeded!")
except Exception as e:
    print("Schema enforcement rejected incompatible types!")
    print(f"Error type: {type(e).__name__}")
    print(f"Message: {e}")

# COMMAND ----------

# MAGIC %md
# MAGIC ### Test 6: Uniqueness violation (duplicate show_name per show_id)
# MAGIC Attempt to append a row with an existing `show_id` but different `show_name`, then verify the duplicate is detected.

# COMMAND ----------

# DBTITLE 1,Simulate uniqueness violation on silver_shows
from pyspark.sql import functions as F

# Pick an existing show_id from silver_shows
existing = spark.table(f"{CATALOG}.silver.silver_shows").select("show_id", "show_name").first()
existing_id = existing["show_id"]
existing_name = existing["show_name"]
print(f"Existing show: id={existing_id}, name='{existing_name}'")

# Create a row with the SAME show_id but a DIFFERENT show_name
bad_row = spark.createDataFrame(
    [(existing_id, "FAKE DUPLICATE NAME", "Unknown", "Unknown", None, None, None, None, None, None, None, "Unknown")],
    spark.table(f"{CATALOG}.silver.silver_shows").schema
)

# Append it (Delta has no built-in unique constraint, so the write succeeds)
bad_row.write.format("delta").mode("append").saveAsTable(f"{CATALOG}.silver.silver_shows")

# Now detect the violation: same show_id with multiple show_names
duplicates = (
    spark.table(f"{CATALOG}.silver.silver_shows")
    .groupBy("show_id")
    .agg(F.countDistinct("show_name").alias("name_count"))
    .filter("name_count > 1")
)

dup_count = duplicates.count()
print(f"\nUniqueness violation detected: {dup_count} show_id(s) have multiple show_names")
duplicates.show(truncate=False)

# Clean up: remove the bad row we just inserted
print("Cleaning up duplicate...")
spark.sql(f"""
    DELETE FROM {CATALOG}.silver.silver_shows
    WHERE show_id = {existing_id} AND show_name = 'FAKE DUPLICATE NAME'
""")

# Verify cleanup
remaining = (
    spark.table(f"{CATALOG}.silver.silver_shows")
    .groupBy("show_id")
    .agg(F.countDistinct("show_name").alias("name_count"))
    .filter("name_count > 1")
    .count()
)
print(f"After cleanup: {remaining} violations remaining (expected 0)")

# COMMAND ----------

# MAGIC %md
# MAGIC ### Summary
# MAGIC
# MAGIC All six constraint and quality rule types are enforced:
# MAGIC
# MAGIC | Test | Rule | Table | Result |
# MAGIC |---|---|---|---|
# MAGIC | 1 | NOT NULL | bronze\_shows.id | Rejected by Delta |
# MAGIC | 2 | CHECK (id > 0) | bronze\_shows | Rejected by Delta |
# MAGIC | 3 | CHECK (runtime > 0) | silver\_episodes | Rejected by Delta |
# MAGIC | 4 | CHECK (episode\_count > 0) | gold.episodes\_per\_season | Rejected by Delta |
# MAGIC | 5 | Schema type mismatch | bronze\_shows.id | Rejected by Delta |
# MAGIC | 6 | Unique show\_name per show\_id | silver\_shows | Detected by query, cleaned up |
# MAGIC
# MAGIC Tests 1–5 are enforced at the Delta storage level (writes are rejected). Test 6 demonstrates that uniqueness violations must be caught by data quality checks since Delta does not enforce unique constraints natively.