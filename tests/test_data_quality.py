# Databricks notebook source
# MAGIC %md
# MAGIC # Part 6: Data Quality & Testing
# MAGIC
# MAGIC Spark-based **pytest** unit tests validating data quality across the medallion architecture.
# MAGIC
# MAGIC | Rule | Tables | Assertion |
# MAGIC |---|---|---|
# MAGIC | Required fields NOT NULL | bronze\_shows, silver\_shows, silver\_episodes, silver\_cast | `show_id`, `episode_id`, `person_id` must never be null |
# MAGIC | Runtime positive | silver\_episodes | `runtime > 0` for all rows |
# MAGIC | Unique show name per ID | silver\_shows | One `show_name` per `show_id` (excluding genre explosion) |
# MAGIC | Delta constraints present | Bronze, Silver, Gold | NOT NULL and CHECK constraints registered in table properties |
# MAGIC | Gold metrics valid | All Gold tables | Aggregated counts and ranks are positive |

# COMMAND ----------

# DBTITLE 1,Install pytest
# MAGIC %pip install pytest --quiet

# COMMAND ----------

 dbutils.library.restartPython()

# COMMAND ----------

# DBTITLE 1,Configuration and imports
import pytest
import sys
import os

dbutils.widgets.text("catalog", "de_assessment_dev")
CATALOG = dbutils.widgets.get("catalog")

print(f"Testing catalog: {CATALOG}")
print(f"Pytest version: {pytest.__version__}")

# COMMAND ----------

# DBTITLE 1,Pytest test suite
from pyspark.sql import functions as F


class TestBronzeDataQuality:
    """Bronze layer: raw data integrity checks."""

    def test_bronze_shows_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.bronze.bronze_shows").filter("id IS NULL").count()
        assert nulls == 0, f"bronze_shows has {nulls} rows with null id"

    def test_bronze_episodes_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.bronze.bronze_episodes").filter("id IS NULL").count()
        assert nulls == 0, f"bronze_episodes has {nulls} rows with null id"

    def test_bronze_episodes_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.bronze.bronze_episodes").filter("show_id IS NULL").count()
        assert nulls == 0, f"bronze_episodes has {nulls} rows with null show_id"

    def test_bronze_cast_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.bronze.bronze_cast").filter("show_id IS NULL").count()
        assert nulls == 0, f"bronze_cast has {nulls} rows with null show_id"


class TestSilverDataQuality:
    """Silver layer: transformed data quality rules."""

    # --- NOT NULL checks ---
    def test_silver_shows_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.silver_shows").filter("show_id IS NULL").count()
        assert nulls == 0, f"silver_shows has {nulls} rows with null show_id"

    def test_silver_episodes_episode_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.silver_episodes").filter("episode_id IS NULL").count()
        assert nulls == 0, f"silver_episodes has {nulls} rows with null episode_id"

    def test_silver_episodes_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.silver_episodes").filter("show_id IS NULL").count()
        assert nulls == 0, f"silver_episodes has {nulls} rows with null show_id"

    def test_silver_cast_person_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.silver_cast").filter("person_id IS NULL").count()
        assert nulls == 0, f"silver_cast has {nulls} rows with null person_id"

    def test_silver_cast_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.silver_cast").filter("show_id IS NULL").count()
        assert nulls == 0, f"silver_cast has {nulls} rows with null show_id"

    # --- Runtime positive ---
    def test_silver_episodes_runtime_positive(self):
        bad = spark.table(f"{CATALOG}.silver.silver_episodes").filter("runtime <= 0").count()
        assert bad == 0, f"silver_episodes has {bad} rows with runtime <= 0"

    # --- Unique show name per ID ---
    def test_silver_shows_unique_name_per_id(self):
        """Each show_id should map to exactly one show_name.
        Genre explosion creates multiple rows per show_id, but show_name must be consistent."""
        df = spark.table(f"{CATALOG}.silver.silver_shows")
        multi_name = (
            df.groupBy("show_id")
            .agg(F.countDistinct("show_name").alias("name_count"))
            .filter("name_count > 1")
            .count()
        )
        assert multi_name == 0, f"{multi_name} show_ids have multiple show_names"

    # --- Fact table referential integrity ---
    def test_fact_show_data_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.fact_show_data").filter("show_id IS NULL").count()
        assert nulls == 0, f"fact_show_data has {nulls} rows with null show_id"


class TestGoldDataQuality:
    """Gold layer: aggregated metrics validation."""

    def test_episodes_per_season_positive_counts(self):
        bad = spark.table(f"{CATALOG}.gold.episodes_per_season").filter("episode_count <= 0").count()
        assert bad == 0, f"episodes_per_season has {bad} rows with episode_count <= 0"

    def test_avg_runtime_positive(self):
        bad = spark.table(f"{CATALOG}.gold.avg_runtime_per_show").filter("avg_runtime_mins <= 0").count()
        assert bad == 0, f"avg_runtime_per_show has {bad} rows with avg_runtime_mins <= 0"

    def test_top_cast_positive_appearances(self):
        bad = spark.table(f"{CATALOG}.gold.top_cast").filter("shows_appeared_in <= 0").count()
        assert bad == 0, f"top_cast has {bad} rows with shows_appeared_in <= 0"

    def test_genre_popularity_positive_counts(self):
        bad = spark.table(f"{CATALOG}.gold.genre_popularity").filter("show_count <= 0").count()
        assert bad == 0, f"genre_popularity has {bad} rows with show_count <= 0"

    def test_gold_tables_not_empty(self):
        for tbl in ["episodes_per_season", "avg_runtime_per_show", "top_cast", "genre_popularity"]:
            count = spark.table(f"{CATALOG}.gold.{tbl}").count()
            assert count > 0, f"gold.{tbl} is empty"


class TestDeltaConstraints:
    """Verify Delta CHECK constraints are registered on tables."""

    def _get_constraint_keys(self, table_fqn):
        """Extract CHECK constraint keys from table properties."""
        props = spark.sql(f"SHOW TBLPROPERTIES {table_fqn}").collect()
        return [row["key"] for row in props if row["key"].startswith("delta.constraints")]

    def test_bronze_shows_constraints(self):
        keys = self._get_constraint_keys(f"{CATALOG}.bronze.bronze_shows")
        assert any("valid_show_id" in k for k in keys), "Missing CHECK valid_show_id on bronze_shows"

    def test_bronze_episodes_constraints(self):
        keys = self._get_constraint_keys(f"{CATALOG}.bronze.bronze_episodes")
        assert any("valid_episode_id" in k for k in keys), "Missing CHECK valid_episode_id on bronze_episodes"
        assert any("valid_show_ref" in k for k in keys), "Missing CHECK valid_show_ref on bronze_episodes"

    def test_silver_episodes_constraints(self):
        keys = self._get_constraint_keys(f"{CATALOG}.silver.silver_episodes")
        assert any("valid_runtime" in k for k in keys), "Missing CHECK valid_runtime on silver_episodes"
        assert any("valid_season" in k for k in keys), "Missing CHECK valid_season on silver_episodes"

    def test_gold_episodes_per_season_constraints(self):
        keys = self._get_constraint_keys(f"{CATALOG}.gold.episodes_per_season")
        assert any("valid_episode_count" in k for k in keys), "Missing CHECK valid_episode_count on gold.episodes_per_season"


print("Test classes defined. Run the next cell to execute.")

# COMMAND ----------

# DBTITLE 1,Execute pytest
import os

# Pytest needs a .py file to discover tests — notebooks aren't discoverable.
# Write test classes to a temp file with spark session setup.
test_file = "/tmp/test_data_quality.py"

header = f'CATALOG = "{CATALOG}"\n'

test_body = '''
import pytest
from pyspark.sql import SparkSession, functions as F

spark = SparkSession.getActiveSession()


class TestBronzeDataQuality:
    """Bronze layer: raw data integrity checks."""

    def test_bronze_shows_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.bronze.bronze_shows").filter("id IS NULL").count()
        assert nulls == 0, f"bronze_shows has {nulls} rows with null id"

    def test_bronze_episodes_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.bronze.bronze_episodes").filter("id IS NULL").count()
        assert nulls == 0, f"bronze_episodes has {nulls} rows with null id"

    def test_bronze_episodes_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.bronze.bronze_episodes").filter("show_id IS NULL").count()
        assert nulls == 0, f"bronze_episodes has {nulls} rows with null show_id"

    def test_bronze_cast_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.bronze.bronze_cast").filter("show_id IS NULL").count()
        assert nulls == 0, f"bronze_cast has {nulls} rows with null show_id"


class TestSilverDataQuality:
    """Silver layer: transformed data quality rules."""

    def test_silver_shows_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.silver_shows").filter("show_id IS NULL").count()
        assert nulls == 0, f"silver_shows has {nulls} rows with null show_id"

    def test_silver_episodes_episode_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.silver_episodes").filter("episode_id IS NULL").count()
        assert nulls == 0, f"silver_episodes has {nulls} rows with null episode_id"

    def test_silver_episodes_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.silver_episodes").filter("show_id IS NULL").count()
        assert nulls == 0, f"silver_episodes has {nulls} rows with null show_id"

    def test_silver_cast_person_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.silver_cast").filter("person_id IS NULL").count()
        assert nulls == 0, f"silver_cast has {nulls} rows with null person_id"

    def test_silver_cast_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.silver_cast").filter("show_id IS NULL").count()
        assert nulls == 0, f"silver_cast has {nulls} rows with null show_id"

    def test_silver_episodes_runtime_positive(self):
        bad = spark.table(f"{CATALOG}.silver.silver_episodes").filter("runtime <= 0").count()
        assert bad == 0, f"silver_episodes has {bad} rows with runtime <= 0"

    def test_silver_shows_unique_name_per_id(self):
        """Each show_id should map to exactly one show_name."""
        df = spark.table(f"{CATALOG}.silver.silver_shows")
        multi_name = (
            df.groupBy("show_id")
            .agg(F.countDistinct("show_name").alias("name_count"))
            .filter("name_count > 1")
            .count()
        )
        assert multi_name == 0, f"{multi_name} show_ids have multiple show_names"

    def test_fact_show_data_show_id_not_null(self):
        nulls = spark.table(f"{CATALOG}.silver.fact_show_data").filter("show_id IS NULL").count()
        assert nulls == 0, f"fact_show_data has {nulls} rows with null show_id"


class TestGoldDataQuality:
    """Gold layer: aggregated metrics validation."""

    def test_episodes_per_season_positive_counts(self):
        bad = spark.table(f"{CATALOG}.gold.episodes_per_season").filter("episode_count <= 0").count()
        assert bad == 0, f"episodes_per_season has {bad} rows with episode_count <= 0"

    def test_avg_runtime_positive(self):
        bad = spark.table(f"{CATALOG}.gold.avg_runtime_per_show").filter("avg_runtime_mins <= 0").count()
        assert bad == 0, f"avg_runtime_per_show has {bad} rows with avg_runtime_mins <= 0"

    def test_top_cast_positive_appearances(self):
        bad = spark.table(f"{CATALOG}.gold.top_cast").filter("shows_appeared_in <= 0").count()
        assert bad == 0, f"top_cast has {bad} rows with shows_appeared_in <= 0"

    def test_genre_popularity_positive_counts(self):
        bad = spark.table(f"{CATALOG}.gold.genre_popularity").filter("show_count <= 0").count()
        assert bad == 0, f"genre_popularity has {bad} rows with show_count <= 0"

    def test_gold_tables_not_empty(self):
        for tbl in ["episodes_per_season", "avg_runtime_per_show", "top_cast", "genre_popularity"]:
            count = spark.table(f"{CATALOG}.gold.{tbl}").count()
            assert count > 0, f"gold.{tbl} is empty"


class TestDeltaConstraints:
    """Verify Delta CHECK constraints are registered on tables."""

    def _get_constraint_keys(self, table_fqn):
        props = spark.sql(f"SHOW TBLPROPERTIES {table_fqn}").collect()
        return [row["key"] for row in props if row["key"].startswith("delta.constraints")]

    def test_bronze_shows_constraints(self):
        keys = self._get_constraint_keys(f"{CATALOG}.bronze.bronze_shows")
        assert any("valid_show_id" in k for k in keys), "Missing CHECK valid_show_id on bronze_shows"

    def test_bronze_episodes_constraints(self):
        keys = self._get_constraint_keys(f"{CATALOG}.bronze.bronze_episodes")
        assert any("valid_episode_id" in k for k in keys), "Missing CHECK valid_episode_id on bronze_episodes"
        assert any("valid_show_ref" in k for k in keys), "Missing CHECK valid_show_ref on bronze_episodes"

    def test_silver_episodes_constraints(self):
        keys = self._get_constraint_keys(f"{CATALOG}.silver.silver_episodes")
        assert any("valid_runtime" in k for k in keys), "Missing CHECK valid_runtime on silver_episodes"
        assert any("valid_season" in k for k in keys), "Missing CHECK valid_season on silver_episodes"

    def test_gold_episodes_per_season_constraints(self):
        keys = self._get_constraint_keys(f"{CATALOG}.gold.episodes_per_season")
        assert any("valid_episode_count" in k for k in keys), "Missing CHECK valid_episode_count"
'''

# Write to temp file
with open(test_file, "w") as f:
    f.write(header)
    f.write(test_body)

print(f"Test file written to {test_file}")

# Run pytest
retcode = pytest.main(["-v", "--tb=short", "-p", "no:cacheprovider", test_file])

if retcode == 0:
    print("\nAll tests PASSED")
else:
    print(f"\nSome tests FAILED (exit code: {retcode})")