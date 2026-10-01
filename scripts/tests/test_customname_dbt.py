import importlib.util
import pathlib
import unittest

# Load the CLI module by path; translate() must import without dbt installed
# (dbtRunner is imported lazily inside main()).
_MOD_PATH = pathlib.Path(__file__).resolve().parents[2] / "services" / "finance" / "customname_dbt.py"
_spec = importlib.util.spec_from_file_location("customname_dbt", _MOD_PATH)
customname_dbt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(customname_dbt)


class TranslateTest(unittest.TestCase):
    def test_run_model(self):
        self.assertEqual(
            customname_dbt.translate(["run-model", "fx_transactions_eur"]),
            ["run", "--select", "fx_transactions_eur", "--profiles-dir", "/project"],
        )

    def test_load_seed(self):
        self.assertEqual(
            customname_dbt.translate(["load-seed", "seed_fx_rates_eur"]),
            ["seed", "--select", "seed_fx_rates_eur", "--profiles-dir", "/project"],
        )

    def test_capture_snapshot(self):
        self.assertEqual(
            customname_dbt.translate(["capture-snapshot", "fx_snapshot"]),
            ["snapshot", "--select", "fx_snapshot", "--profiles-dir", "/project"],
        )

    def test_test_model(self):
        self.assertEqual(
            customname_dbt.translate(["test-model", "fx_transactions_eur"]),
            ["test", "--select", "fx_transactions_eur", "--profiles-dir", "/project"],
        )

    def test_build_model(self):
        self.assertEqual(
            customname_dbt.translate(["build-model", "fx_transactions_eur"]),
            ["build", "--select", "fx_transactions_eur", "--profiles-dir", "/project"],
        )

    def test_compile_project(self):
        self.assertEqual(
            customname_dbt.translate(["compile-project"]),
            ["compile", "--profiles-dir", "/project"],
        )

    def test_parse_project(self):
        self.assertEqual(
            customname_dbt.translate(["parse-project"]),
            ["parse", "--profiles-dir", "/project"],
        )

    def test_unknown_verb_is_none(self):
        self.assertIsNone(customname_dbt.translate(["nope"]))

    def test_missing_arg_is_none(self):
        self.assertIsNone(customname_dbt.translate(["run-model"]))
        self.assertIsNone(customname_dbt.translate(["capture-snapshot"]))
        self.assertIsNone(customname_dbt.translate(["test-model"]))
        self.assertIsNone(customname_dbt.translate(["build-model"]))

    def test_extra_arg_is_none(self):
        self.assertIsNone(customname_dbt.translate(["compile-project", "extra"]))
        self.assertIsNone(customname_dbt.translate(["parse-project", "extra"]))
        self.assertIsNone(customname_dbt.translate(["run-model", "a", "b"]))

    def test_empty_is_none(self):
        self.assertIsNone(customname_dbt.translate([]))

    def test_rebuild_model(self):
        self.assertEqual(
            customname_dbt.translate(["rebuild-model", "fx_transactions_eur"]),
            ["run", "--full-refresh", "--select", "fx_transactions_eur", "--profiles-dir", "/project"],
        )

    def test_reload_seed(self):
        self.assertEqual(
            customname_dbt.translate(["reload-seed", "seed_fx_rates_eur"]),
            ["seed", "--full-refresh", "--select", "seed_fx_rates_eur", "--profiles-dir", "/project"],
        )

    def test_full_refresh_verbs_need_exactly_one_node(self):
        self.assertIsNone(customname_dbt.translate(["rebuild-model"]))
        self.assertIsNone(customname_dbt.translate(["reload-seed", "a", "b"]))


if __name__ == "__main__":
    unittest.main()
