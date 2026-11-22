import unittest
from collections import Counter

import dispatch

CONFIG = {
    "pools": {
        "linux": {
            "kind": "docker",
            "labels": ["self-hosted", "linux", "ephemeral"],
            "repos": ["owner/Dotfiles", "owner/app"],
            "max_runners": 3,
        },
        "windows": {
            "kind": "windows",
            "host": "windows",
            "runner_dir": "C:\\Users\\user\\actions-runner\\",
            "labels": ["self-hosted", "windows", "X64"],
            "repos": ["owner/app", "owner/cad"],
        },
    }
}


def config(**overrides):
    data = {"pools": {name: dict(table) for name, table in CONFIG["pools"].items()}}
    for pool, table in overrides.items():
        data["pools"][pool].update(table)
    return dispatch.parse_config(data, "ARM64")


def runner(pool, repo, *, assigned=False, started_at=0.0):
    return dispatch.Runner(name="r", pool=pool, repo=repo, runner_id=1, started_at=started_at, assigned=assigned)


class RepoGuardTest(unittest.TestCase):
    def test_only_private_repositories_get_runners(self):
        self.assertTrue(dispatch.allows_self_hosted({"private": True, "visibility": "private"}))
        self.assertFalse(dispatch.allows_self_hosted({"private": False, "visibility": "public"}))
        self.assertFalse(dispatch.allows_self_hosted({"private": True, "visibility": "internal"}))
        self.assertFalse(dispatch.allows_self_hosted({}))


class ParseConfigTest(unittest.TestCase):
    def test_docker_pool_gets_host_arch_label_and_repos_are_lowercased(self):
        linux, windows = config().pools
        self.assertEqual(linux.labels, ("self-hosted", "linux", "ephemeral", "ARM64"))
        self.assertEqual(linux.repos, {"owner/dotfiles", "owner/app"})
        self.assertEqual(windows.labels, ("self-hosted", "windows", "X64"))
        self.assertEqual(windows.runner_dir, "C:\\Users\\user\\actions-runner")

    def test_rejects_unsafe_or_unsupported_settings(self):
        cases = {
            "windows pool with two runners": {"windows": {"max_runners": 2}},
            "quote in runner_dir": {"windows": {"runner_dir": 'C:\\x" & calc'}},
            "space in runner_dir": {"windows": {"runner_dir": "C:\\Users\\First Last\\actions-runner"}},
            "typo in key": {"linux": {"max_runner": 2}},
            "bad repo": {"linux": {"repos": ["not-a-repo"]}},
        }
        for label, overrides in cases.items():
            with self.subTest(label), self.assertRaises(dispatch.ConfigError):
                config(**overrides)


class MatchPoolTest(unittest.TestCase):
    def setUp(self):
        self.pools = config().pools

    def test_job_needs_every_label_and_a_listed_repo(self):
        linux, windows = self.pools
        self.assertIs(dispatch.match_pool(self.pools, "owner/cad", ["self-hosted", "Windows"]), windows)
        self.assertIsNone(dispatch.match_pool(self.pools, "owner/cad", ["self-hosted", "linux"]))
        self.assertIsNone(dispatch.match_pool(self.pools, "owner/cad", ["windows-latest"]))
        # A bare "self-hosted" job from a repo outside the windows pool never reaches the Windows machine
        self.assertIs(dispatch.match_pool(self.pools, "owner/dotfiles", ["self-hosted"]), linux)

    def test_first_pool_in_file_order_wins(self):
        linux, _ = self.pools
        self.assertIs(dispatch.match_pool(self.pools, "owner/app", ["self-hosted"]), linux)


class PlanSpawnsTest(unittest.TestCase):
    def setUp(self):
        self.pools = config().pools
        self.linux, self.windows = self.pools

    def test_windows_pool_runs_one_job_at_a_time_across_repos(self):
        demand = Counter({("windows", "owner/app"): 2, ("windows", "owner/cad"): 1})
        self.assertEqual(dispatch.plan_spawns(self.pools, demand, [], set()), [(self.windows, "owner/app")])
        busy = [runner(self.windows, "owner/app", assigned=True)]
        self.assertEqual(dispatch.plan_spawns(self.pools, demand, busy, set()), [])

    def test_waiting_runners_cover_demand_and_cap_limits_the_rest(self):
        demand = Counter({("linux", "owner/app"): 5})
        waiting = [runner(self.linux, "owner/app")]
        self.assertEqual(dispatch.plan_spawns(self.pools, demand, waiting, set()), [(self.linux, "owner/app")] * 2)

    def test_blocked_pool_is_skipped(self):
        demand = Counter({("linux", "owner/app"): 1})
        self.assertEqual(dispatch.plan_spawns(self.pools, demand, [], {"linux"}), [])


class IdleRunnersTest(unittest.TestCase):
    def test_only_runners_without_a_job_time_out(self):
        linux, _ = config().pools
        old_waiting = runner(linux, "owner/app", started_at=0)
        old_busy = runner(linux, "owner/app", assigned=True, started_at=0)
        new_waiting = runner(linux, "owner/app", started_at=500)
        idle = dispatch.idle_runners([old_waiting, old_busy, new_waiting], now=700, idle_timeout=600)
        self.assertEqual(idle, [old_waiting])


if __name__ == "__main__":
    unittest.main()
