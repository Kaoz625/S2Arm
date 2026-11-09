"""Offline regressions for wait's task selection (no App, game or network)."""
import contextlib
import importlib.util
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "s2armctl", Path(__file__).resolve().parents[1] / "s2armctl.py")
ctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctl)


def task(identifier, state, started, game="game", operation="build"):
    return {"id": identifier, "state": state, "started": started,
            "gameId": game, "operation": operation}


def state(*tasks, queue=(), error=None):
    # Same task/queue fields serialized by ControlServer.state().
    return {"tasks": list(tasks), "queue": list(queue), "error": error}


class StartFailureTests(unittest.TestCase):
    def run_start(self, why, stale=False):
        now = [0]
        with tempfile.TemporaryDirectory() as root:
            error = Path(root) / "control.error"
            def launch(*_args, **_kwargs):
                error.write_text(why, encoding="utf-8")
                if not stale:
                    os.utime(error, (2000, 2000))
            if stale:
                error.write_text("上一次的错", encoding="utf-8")
                os.utime(error, (1000, 1000))
            def sleep(seconds):
                now[0] += seconds
            with mock.patch.object(ctl, "ROOT", root), mock.patch.object(ctl, "WINDOWS", False), \
                 mock.patch.object(ctl, "info", side_effect=SystemExit("no control")), \
                 mock.patch.object(ctl.subprocess, "run", side_effect=None if stale else launch), \
                 mock.patch.object(ctl.time, "time", side_effect=lambda: now[0]), \
                 mock.patch.object(ctl.time, "sleep", side_effect=sleep), \
                 self.assertRaises(SystemExit) as caught:
                ctl.start("/Applications/S2Arm.app")
        return str(caught.exception.code), now[0]

    def test_reason_is_reported_without_waiting(self):
        message, waited = self.run_start("Private job root inherits permissions.")
        self.assertIn("Private job root inherits permissions.", message)
        self.assertIn("还不存在的路径", message)
        self.assertEqual(waited, 0)

    def test_other_reason_gets_no_data_root_advice(self):
        message, _ = self.run_start("地址已被占用")
        self.assertEqual(message, "控制口没起来：地址已被占用")

    def test_failure_from_an_earlier_start_is_ignored(self):
        message, waited = self.run_start("", stale=True)
        self.assertIn("60 秒内控制口没就绪", message)
        self.assertNotIn("上一次的错", message)
        self.assertGreaterEqual(waited, 60)


class TaskLogTests(unittest.TestCase):
    def test_build_logs_command_reads_the_nested_stage_log(self):
        with tempfile.TemporaryDirectory() as root:
            stage = Path(root) / "logs" / "build-task" / "refresh.log"
            stage.parent.mkdir(parents=True)
            stage.write_text("第一行\n第二行\n第三行\n", encoding="utf-8")
            record = task("build-task", "running", 1)
            output = io.StringIO()
            with mock.patch.object(ctl, "ROOT", root), \
                    mock.patch.object(ctl, "call", return_value=state(record)), \
                    mock.patch.object(ctl.sys, "argv", ["s2armctl", "logs", "build-task", "--lines", "2"]), \
                    contextlib.redirect_stdout(output):
                ctl.main()
            self.assertIn(str(stage), output.getvalue())
            self.assertIn("第二行\n第三行", output.getvalue())
            self.assertNotIn("第一行", output.getvalue())

    def test_game_reference_reads_the_latest_tasks_nested_log(self):
        with tempfile.TemporaryDirectory() as root:
            logs = Path(root) / "logs"
            logs.mkdir()
            (logs / "old-game.log").write_text("old run", encoding="utf-8")
            stage = logs / "new" / "extract.log"
            stage.parent.mkdir()
            stage.write_text("new build", encoding="utf-8")
            output = io.StringIO()
            with mock.patch.object(ctl, "ROOT", root), \
                    mock.patch.object(ctl, "call", return_value=state(
                        task("old", "completed", 1, operation="launch"),
                        task("new", "running", 2))), \
                    contextlib.redirect_stdout(output):
                ctl.logs("game", 40)
            self.assertIn("new build", output.getvalue())
            self.assertNotIn("old run", output.getvalue())

    def test_newest_log_is_selected_across_flat_and_nested_layouts(self):
        with tempfile.TemporaryDirectory() as root:
            logs = Path(root) / "logs"
            nested = logs / "job" / "refresh.log"
            nested.parent.mkdir(parents=True)
            flat = logs / "job-failure.log"
            nested.write_text("stage", encoding="utf-8")
            flat.write_text("failure", encoding="utf-8")
            with mock.patch.object(ctl, "ROOT", root):
                os.utime(nested, (200, 200))
                os.utime(flat, (100, 100))
                self.assertEqual(ctl.task_log("job"), str(nested))
                os.utime(flat, (300, 300))
                self.assertEqual(ctl.task_log("job"), str(flat))

    def test_flat_game_log_still_works_and_other_tasks_are_ignored(self):
        with tempfile.TemporaryDirectory() as root:
            logs = Path(root) / "logs"
            logs.mkdir()
            game = logs / "launch-game.log"
            game.write_text("game", encoding="utf-8")
            unrelated = logs / "other" / "refresh.log"
            unrelated.parent.mkdir()
            unrelated.write_text("other task", encoding="utf-8")
            with mock.patch.object(ctl, "ROOT", root):
                self.assertEqual(ctl.task_log("launch"), str(game))
                self.assertIsNone(ctl.task_log("missing"))

    def test_log_named_directories_are_not_returned_as_files(self):
        with tempfile.TemporaryDirectory() as root:
            (Path(root) / "logs" / "job-empty.log").mkdir(parents=True)
            with mock.patch.object(ctl, "ROOT", root):
                self.assertIsNone(ctl.task_log("job"))


class WaitTests(unittest.TestCase):
    def run_wait(self, states, operation="build", limit=10):
        now = [0]

        def sleep(seconds):
            now[0] += seconds

        output = io.StringIO()
        with mock.patch.object(ctl, "call", side_effect=states) as call, \
                mock.patch.object(ctl.time, "time", side_effect=lambda: now[0]), \
                mock.patch.object(ctl.time, "sleep", side_effect=sleep), \
                contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as result:
            ctl.wait("game", operation, limit)
        return result.exception.code, call.call_count, output.getvalue()

    def test_space_override_flag_reaches_the_app(self):
        for argv, path, body in [
                (["build", "G", "mac", "--space-override"], "/build", {"gameId": "G", "target": "mac", "spaceOverride": True}),
                (["build", "G", "--space-override"], "/build", {"gameId": "G", "target": "ios", "spaceOverride": True}),
                (["build", "G", "ios"], "/build", {"gameId": "G", "target": "ios"}),
                (["ipa", "G", "--space-override"], "/ipa", {"gameId": "G", "spaceOverride": True}),
                (["ipa", "G"], "/ipa", {"gameId": "G"})]:
            with mock.patch.object(ctl, "call", return_value={"ok": True}) as call, mock.patch.object(ctl.sys, "argv", ["s2armctl", *argv]), \
                    mock.patch("builtins.print"):
                ctl.main()
            call.assert_called_once_with("POST", path, body)

    def test_install_passes_team_and_device_only_when_given(self):
        for argv, body in [(["install", "G"], {"gameId": "G"}),
                           (["install", "G", "--team", "ABCDE12345"], {"gameId": "G", "teamId": "ABCDE12345"}),
                           (["install", "G", "--device", "测试 iPhone", "--team", "ABCDE12345"],
                            {"gameId": "G", "teamId": "ABCDE12345", "device": "测试 iPhone"})]:
            with mock.patch.object(ctl, "call", return_value={"ok": True}) as call, mock.patch.object(ctl.sys, "argv", ["s2armctl", *argv]), mock.patch("builtins.print"):
                ctl.main()
            call.assert_called_once_with("POST", "/install", body)

    def test_customize_sends_only_what_was_given(self):
        for argv, body in [(["customize", "G", "--name", "新名"], {"gameId": "G", "name": "新名"}),
                           (["customize", "G", "--reset-cover"], {"gameId": "G", "coverPath": ""}),
                           (["customize", "G", "--reset-name"], {"gameId": "G", "name": ""})]:
            with mock.patch.object(ctl, "call", return_value={"ok": True}) as call, mock.patch.object(ctl.sys, "argv", ["s2armctl", *argv]), mock.patch("builtins.print"):
                ctl.main()
            call.assert_called_once_with("POST", "/customize", body)
        with mock.patch.object(ctl, "call") as call, mock.patch.object(ctl.sys, "argv", ["s2armctl", "customize", "G"]):
            with self.assertRaises(SystemExit):
                ctl.main()
        call.assert_not_called()

    def test_queued_then_running_then_completed(self):
        old = task("old", "completed", 1)
        states = [state(old, task("queued-game", "queued", 2), queue=["game"]),
                  state(old, task("new", "running", 3)),
                  state(old, task("new", "completed", 3))]
        code, calls, output = self.run_wait(states)
        self.assertEqual((code, calls), (0, 3))
        self.assertIn("queued", output)
        self.assertIn("running", output)

    def test_new_failure_overrides_old_success(self):
        old = task("old", "completed", 1)
        states = [state(old, task("queued-game", "queued", 2), queue=["game"]),
                  state(old, task("new", "failed", 3))]
        self.assertEqual(self.run_wait(states)[:2], (1, 2))

    def test_queue_before_task_refresh_does_not_report_history_or_stale_error(self):
        old = task("old", "completed", 1)
        states = [state(old, queue=["game"], error="another task failed"),
                  state(old, task("new", "running", 3)),
                  state(old, task("new", "failed", 3))]
        self.assertEqual(self.run_wait(states)[:2], (1, 3))

    def test_cancelled_queue_is_failure(self):
        old = task("old", "completed", 1)
        states = [state(old, task("queued-game", "queued", 2), queue=["game"]),
                  state(old)]
        code, calls, output = self.run_wait(states)
        self.assertEqual((code, calls), (1, 2))
        self.assertIn("排队已取消", output)

    def test_cancelled_queue_before_task_refresh_is_failure(self):
        old = task("old", "completed", 1)
        self.assertEqual(self.run_wait([state(old, queue=["game"]), state(old)])[:2], (1, 2))

    def test_late_history_before_queue_does_not_count_as_new_work(self):
        states = [state(task("queued-game", "queued", 2), queue=["game"]),
                  state(task("old", "completed", 1))]
        self.assertEqual(self.run_wait(states)[:2], (1, 2))

    def test_cancelled_queue_record_after_refresh_is_failure(self):
        old = task("old", "completed", 1)
        states = [state(old, task("queued-game", "queued", 2), queue=["game"]),
                  state(old, task("queued-game", "cancelled", 2))]
        self.assertEqual(self.run_wait(states)[:2], (1, 2))

    def test_other_game_does_not_block_or_override_result(self):
        states = [state(task("old", "completed", 1),
                        task("queued-other", "queued", 4, game="other"), queue=["other"])]
        self.assertEqual(self.run_wait(states)[:2], (0, 1))

    def test_build_queue_does_not_block_ipa_wait(self):
        states = [state(task("ipa", "completed", 1, operation="ipa"),
                        task("queued-game", "queued", 4), queue=["game"])]
        self.assertEqual(self.run_wait(states, operation="ipa")[:2], (0, 1))

    def test_history_without_queue_keeps_failure(self):
        self.assertEqual(self.run_wait([state(task("old", "failed", 1))])[:2], (1, 1))

    def test_queue_without_task_times_out(self):
        states = [state(task("old", "completed", 1), queue=["game"])] * 2
        code, calls, _ = self.run_wait(states, limit=3)
        self.assertEqual(calls, 2)
        self.assertIsInstance(code, str)
        self.assertIn("3 秒内没结束", code)





def full_state(**over):
    # ControlServer.state() 里 next_step 读到的字段：环境、密钥、游戏（含 baseBytes）、任务、目标设备、系统授权
    s = {"waitingForAccess": None, "checkingEnvironment": False, "environmentReady": True, "checks": [],
         "hasImportedKeys": True, "games": [], "tasks": [], "iphoneTarget": {"productType": "iPhone18,2", "os": 27}}
    s.update(over)
    return s


def game(identifier, name, base_bytes, buildable=True, ready=False, missing=()):
    return {"id": identifier, "name": name, "baseBytes": base_bytes, "buildable": buildable, "ready": ready, "missing": list(missing)}


class NextStepTests(unittest.TestCase):
    """AI 代操作入口 next（10-26）：期望按规则手写——每种状态推出的 step / who / 命令"""

    def test_no_check_result_yet_means_checking(self):
        # 刚拉起：环境检查还没开始（没有结果、也不在查）→ 让 AI 等，不能报「玩家去处理」却列不出缺什么
        n = ctl.next_step(full_state(environmentReady=False, checks=[], checkingEnvironment=False))
        self.assertEqual((n["step"], n["who"]), ("环境检查", "ai"))
        n = ctl.next_step(full_state(environmentReady=False, checks=[{"name": "Xcode", "ok": False, "message": "没装 Xcode"}]))
        self.assertEqual((n["step"], n["who"]), ("环境", "human")); self.assertIn("没装 Xcode", n["do"])

    def test_keys_then_import_then_pack(self):
        # 空库先问游戏（解包好的游戏不要密钥），NSP / XCI 要密钥时才问
        n = ctl.next_step(full_state(hasImportedKeys=False))
        self.assertEqual((n["step"], n["who"]), ("导入", "ask"))
        n = ctl.next_step(full_state(hasImportedKeys=False, games=[game("g", "G", 1)]))
        self.assertEqual((n["step"], n["who"]), ("密钥", "ask"))
        self.assertIn("s2armctl keys", n["do"])
        n = ctl.next_step(full_state())
        self.assertEqual((n["step"], n["who"]), ("导入", "ask"))
        # 一包通用：没选目标设备也直接出包，不多问一步（11-02 beta.3 走查）
        for tgt in (None, {"model": "iPhone 17 Pro", "gpuArch": "applegpu_g18p", "os": 26}):
            n = ctl.next_step(full_state(games=[game("0100535012974000", "Hades", 6e9)], iphoneTarget=tgt))
            self.assertEqual((n["step"], n["who"], n["game"]), ("出包", "ai", "0100535012974000"))
            self.assertIn("s2armctl build 0100535012974000 ios", n["do"])

    def test_multi_base_picks_largest_and_lists_tools(self):
        # 同一文件夹里的游戏 + 同系列小工具导入后是两款：认本体大的那款，另一款列在 others
        s = full_state(games=[game("0100F9C00EB8C000", "小岛转移工具", 2e6), game("01006F8002326000", "动森", 8e9)])
        n = ctl.next_step(s)
        self.assertEqual(n["game"], "01006F8002326000")
        self.assertEqual(len(n["others"]), 1)
        self.assertIn("0100F9C00EB8C000", n["others"][0])
        self.assertEqual(ctl.next_step(s, "0100F9C00EB8C000")["game"], "0100F9C00EB8C000")

    def test_failed_pack_maps_code_to_action(self):
        failed = {"id": "t1", "gameId": "g", "operation": "ipa", "state": "failed", "started": 1,
                  "diagnostics": [{"code": "disk_full", "summary": "磁盘空间不足", "suggestion": "释放空间", "logPath": "/x.log"}]}
        n = ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[failed]))
        self.assertEqual((n["step"], n["who"], n["code"]), ("出包失败", "confirm", "disk_full"))
        self.assertIn("s2armctl retry t1", n["do"])   # 任务号代进命令
        failed["diagnostics"] = [{"code": "something_new"}]
        self.assertEqual(ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[failed]))["who"], "ai")   # 没登记的码按缺省：看日志、重试一次

    def test_running_waits_then_install_then_open(self):
        running = {"id": "t2", "gameId": "g", "operation": "ipa", "state": "running", "started": 2, "milestone": "direct"}
        n = ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[running]))
        self.assertEqual((n["step"], n["who"]), ("等待", "ai"))
        done = {"id": "t3", "gameId": "g", "operation": "ipa", "state": "completed", "started": 3, "ended": 4, "ipaPath": "/lib/iPhone/g/tg.ipa"}
        n = ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[done]))
        # 10-26 装机主路改 Xcode 直签：出完包 AI 自己 install（Xcode 没登录 / 没连设备由 install 报错码再交给玩家）
        self.assertEqual((n["step"], n["who"], n["ipa"]), ("装机", "ai", "/lib/iPhone/g/tg.ipa"))
        self.assertIn("s2armctl install g", n["do"])
        # 装机失败按错误码：Xcode 没登录 → 玩家本人登录；没连设备 → 问玩家连上
        for code, who in (("xcode_account_missing", "human"), ("device_not_connected", "ask"), ("free_app_limit", "human"), ("signing_failed", "ai")):
            inst = {"id": "t4", "gameId": "g", "operation": "install", "state": "failed", "started": 5, "diagnostics": [{"code": code, "summary": "x"}]}
            n = ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[done, inst]))
            self.assertEqual((n["step"], n["who"], n["code"]), ("装机失败", who, code))
        # 装好（在这次出包之后）→ 只剩玩家打开游戏
        ok = {"id": "t5", "gameId": "g", "operation": "install", "state": "completed", "started": 6, "ended": 7, "device": "测试设备2"}
        n = ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[done, ok]))
        self.assertEqual((n["step"], n["who"]), ("打开游戏", "human"))
        self.assertIn("测试设备2", n["do"])
        # 之后又出了新包 → 旧的装机不算，重新装
        newer = dict(done, id="t6", started=8, ended=9)
        self.assertEqual(ctl.next_step(full_state(games=[game("g", "G", 1e9)], tasks=[done, ok, newer]))["step"], "装机")

    def test_system_permission_and_environment_are_human(self):
        self.assertEqual(ctl.next_step(full_state(waitingForAccess="下载"))["who"], "human")
        n = ctl.next_step(full_state(environmentReady=False, checks=[{"name": "Xcode", "ok": False, "message": "没装"}]))
        self.assertEqual((n["step"], n["who"]), ("环境", "human"))



class NextTargetTests(unittest.TestCase):
    def run_next(self, snapshot, *args):
        out = io.StringIO()
        with mock.patch.object(ctl, "WINDOWS", False), \
             mock.patch.object(sys, "argv", ["s2armctl", "next", *args, "--json"]), \
             mock.patch.object(ctl, "call", return_value=snapshot) as call, \
             contextlib.redirect_stdout(out):
            ctl.main()
        call.assert_called_once_with("GET", "/state")
        return json.loads(out.getvalue())

    def test_ready_mac_game_launches_without_ipa(self):
        s = full_state(games=[game("g", "G", 1, ready=True)],
                       tasks=[task("mac", "completed", 1, game="g")])
        n = self.run_next(s, "g", "--target", "mac")
        self.assertEqual(n["do"], "s2armctl launch g")

    def test_ready_mac_uses_runtime_environment(self):
        s = full_state(games=[game("g", "G", 1, ready=True)],
                       environmentReady=False, runtimeReady=True, hasImportedKeys=False)
        n = self.run_next(s, "g", "--target", "mac")
        self.assertEqual(n["do"], "s2armctl launch g")

    def test_ready_mac_reports_own_running_launch(self):
        launch = task("launch-g", "running", 1, game="g", operation="launch")
        s = full_state(games=[game("g", "G", 1, ready=True)],
                       tasks=[launch], executionTask=launch["id"])
        n = self.run_next(s, "g", "--target", "mac")
        self.assertEqual((n["step"], n["who"]), ("运行中", "human"))
        self.assertEqual(n["task"], "launch-g")
        self.assertEqual(n["do"], "请玩家查看 Mac 上的游戏窗口")

    def test_ready_mac_waits_for_other_execution_tasks(self):
        own_launch = task("launch-g", "running", 1, game="g", operation="launch")
        busy_tasks = (
            task("launch-other", "running", 2, game="other", operation="launch"),
            task("ipa-g", "running", 2, game="g", operation="ipa"),
            dict(own_launch, state="cancelling"),
        )
        for busy in busy_tasks:
            with self.subTest(operation=busy["operation"], game=busy["gameId"], state=busy["state"]):
                tasks = [busy] if busy["id"] == own_launch["id"] else [own_launch, busy]
                s = full_state(games=[game("g", "G", 1, ready=True)],
                               tasks=tasks, executionTask=busy["id"])
                n = self.run_next(s, "g", "--target", "mac")
                self.assertEqual((n["step"], n["who"]), ("等待", "ai"))
                self.assertEqual(n["why"], "构建与游戏运行互斥")

    def test_ready_mac_waits_if_launcher_is_busy(self):
        for busy in ({"executionTask": "other-task"}, {"queue": ["other-game"]}):
            with self.subTest(busy=busy):
                s = full_state(games=[game("g", "G", 1, ready=True)], **busy)
                n = self.run_next(s, "g", "--target", "mac")
                self.assertEqual(n["step"], "等待")
                self.assertIn("s2armctl next g --target mac", n["do"])

    def test_mac_reprepares_stale_artifact(self):
        stale = dict(game("g", "G", 1, ready=True), needsPreparation=True)
        n = self.run_next(full_state(games=[stale]), "g", "--target", "mac")
        self.assertIn("s2armctl build g mac", n["do"])

    def test_mac_game_needs_preparation_even_with_ipa(self):
        ipa = dict(task("ipa", "completed", 1, game="g", operation="ipa"),
                   ipaPath="/lib/iPhone/g/g.ipa")
        s = full_state(games=[game("g", "G", 1)], tasks=[ipa])
        n = self.run_next(s, "--target", "mac", "g")
        self.assertIn("s2armctl build g mac", n["do"])
        self.assertIn("s2armctl wait g --op build", n["do"])

    def test_mac_waits_for_its_build_or_queue_entry(self):
        ipa = task("ipa", "running", 2, game="g", operation="ipa")
        for tasks, queue in (([task("mac", "running", 1, game="g"), ipa], []),
                             ([ipa], ["g"])):
            with self.subTest(queue=queue):
                s = full_state(games=[game("g", "G", 1)], tasks=tasks, queue=queue)
                n = self.run_next(s, "g", "--target", "mac")
                self.assertEqual(n["step"], "等待")
                self.assertIn("s2armctl wait g --op build", n["do"])
                self.assertIn("s2armctl next g --target mac", n["do"])

    def test_mac_reports_build_failure_with_diagnostics(self):
        failed = dict(task("mac", "failed", 1, game="g"),
                      diagnostics=[{"code": "disk_full", "summary": "磁盘空间不足"}])
        s = full_state(games=[game("g", "G", 1)], tasks=[failed])
        n = self.run_next(s, "g", "--target", "mac")
        self.assertEqual((n["step"], n["who"], n["code"]), ("准备失败", "confirm", "disk_full"))
        self.assertIn("s2armctl retry mac", n["do"])

    def test_explicit_ios_matches_omitted_target(self):
        s = full_state(games=[game("g", "G", 1, ready=True)])
        default = self.run_next(s, "g")
        self.assertIn("s2armctl build g ios", default["do"])
        self.assertEqual(self.run_next(s, "g", "--target", "ios"), default)

    def test_windows_rejects_mac_before_contacting_launcher(self):
        err = io.StringIO()
        with mock.patch.object(ctl, "WINDOWS", True), \
             mock.patch.object(sys, "argv", ["s2armctl", "next", "g", "--target", "mac"]), \
             mock.patch.object(ctl, "call") as call, contextlib.redirect_stderr(err), \
             self.assertRaises(SystemExit) as caught:
            ctl.main()
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("Windows", err.getvalue())
        self.assertIn("--target mac", err.getvalue())
        call.assert_not_called()

    def test_invalid_next_arguments_fail_before_contacting_launcher(self):
        for args in (["--target"], ["--target", "android"], ["g", "extra"], ["--unknown"]):
            with self.subTest(args=args), \
                 mock.patch.object(sys, "argv", ["s2armctl", "next", *args]), \
                 mock.patch.object(ctl, "call") as call, contextlib.redirect_stderr(io.StringIO()), \
                 self.assertRaises(SystemExit) as caught:
                ctl.main()
            self.assertEqual(caught.exception.code, 2)
            call.assert_not_called()


class LaunchArgsTests(unittest.TestCase):
    # 11-02 beta.3 走查：`--control --data-root <目录>` 让 <目录> 落单被 macOS 当成要打开的文件，App 不建窗口。期望：数据目录是一个整体参数，没有落单的路径
    def test_data_root_is_one_token(self):
        args = ctl.launch_args("/A/S2Arm.app", root="/d/数据 目录", custom=True)
        self.assertEqual(args, ["open", "/A/S2Arm.app", "--args", "--control", "--data-root=/d/数据 目录"])
        self.assertTrue(all(a.startswith("-") for a in args[3:]))
        self.assertEqual(ctl.launch_args("/A/S2Arm.app", root="/d", custom=False), ["open", "/A/S2Arm.app", "--args", "--control"])

    def test_uninstall_posts_to_uninstall_endpoint(self):
        """uninstall <游戏号> 走 POST /uninstall {gameId}（与 install 对称）"""
        posted = {}
        def fake_call(method, path, body=None, **kw):
            posted['method'] = method; posted['path'] = path; posted['body'] = body
            return {"ok": True}
        with mock.patch.object(ctl, "call", side_effect=fake_call), \
             mock.patch.object(sys, "argv", ["s2armctl", "uninstall", "0100535012974000"]):
            ctl.main()
        self.assertEqual(posted, {"method": "POST", "path": "/uninstall", "body": {"gameId": "0100535012974000"}})

class DiagCommandTests(unittest.TestCase):
    """#94：只敲 s2armctl diag 原先 IndexError；现在不给路径 = 导出到桌面，认不出的写法打用法退出 2"""

    def _main(self, *argv):
        posted = []
        err = io.StringIO()
        with mock.patch.object(ctl, "call", side_effect=lambda m, p, b=None, **kw: posted.append((m, p, b)) or {"ok": True}), \
             mock.patch.object(sys, "argv", ["s2armctl", "diag", *argv]), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            try:
                ctl.main(); code = 0
            except SystemExit as e:
                code = e.code
        return code, posted, err.getvalue()

    def test_bare_diag_exports_with_a_default_path(self):
        code, posted, _ = self._main()
        self.assertEqual(code, 0)
        self.assertEqual(len(posted), 1)
        method, path, body = posted[0]
        self.assertEqual((method, path, body["action"]), ("POST", "/diagnostics", "export"))
        self.assertTrue(os.path.isabs(body["path"]) and body["path"].endswith(".zip"), body["path"])

    def test_export_without_path_uses_the_same_default(self):
        self.assertEqual(ctl.diag_body(["export"], now=0), ctl.diag_body([], now=0))

    def test_explicit_forms_unchanged(self):
        self.assertEqual(ctl.diag_body(["pull"]), {"action": "pull"})
        self.assertEqual(ctl.diag_body(["export", "/tmp/x.zip"]), {"action": "export", "path": "/tmp/x.zip"})

    def test_unknown_form_prints_usage_and_exits_2(self):
        code, posted, err = self._main("bogus")
        self.assertEqual((code, posted), (2, []))
        self.assertIn("用法", err)


class ErrorsCommandTests(unittest.TestCase):
    """errors 命令输出里含 failureSummary（阶段、退出码、原文）。"""

    def _run_errors(self, state):
        out = io.StringIO()
        with mock.patch.object(ctl, "call", return_value=state), \
             contextlib.redirect_stdout(out):
            ctl.errors()
        return out.getvalue()

    def test_errors_shows_failure_summary(self):
        """诊断带 failureSummary 时，errors 命令要把它印出来。"""
        state = {"tasks": [{"id": "t1", "operation": "ipa", "state": "failed", "started": 1,
                             "message": "打包失败",
                             "diagnostics": [{"code": "build_failed", "summary": "编译出错",
                                              "suggestion": "重装 Xcode", "logPath": None,
                                              "failureSummary": "Failed stage: compile\nExit code: 1\nLast output:\n  error: foo"}]}],
                 "error": ""}
        output = self._run_errors(state)
        # 期望：failureSummary 内容出现在输出里
        self.assertIn("Failed stage: compile", output)
        self.assertIn("Exit code: 1", output)
        self.assertIn("error: foo", output)

    def test_errors_no_failure_summary_still_works(self):
        """诊断没有 failureSummary 字段时不出错、不输出多余内容。"""
        state = {"tasks": [{"id": "t2", "operation": "ipa", "state": "failed", "started": 2,
                             "message": "打包失败",
                             "diagnostics": [{"code": "disk_full", "summary": "磁盘不足",
                                              "suggestion": "释放空间", "logPath": None}]}],
                 "error": ""}
        output = self._run_errors(state)
        self.assertIn("disk_full", output)
        self.assertNotIn("Failed stage", output)

if __name__ == "__main__":
    unittest.main()


class ControlStuckTests(unittest.TestCase):
    """10-26 Spare-host：内存吃紧时启动器控制口不应答，wait 一次超时就判失败、整个出包作业跟着丢。
    控制口卡住时 wait 要按作业记录（<数据目录>/jobs/<任务>.json，pack/jobs/core.py 写）判：作业进程活着就接着等。期望按场景手写。"""
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="s2armctl-stuck-")
        os.makedirs(os.path.join(self.root, "jobs"))
        # 卡死的控制口：接连接、读请求、永远不回
        self.server = socket.socket(); self.server.bind(("127.0.0.1", 0)); self.server.listen(8)
        self.held = []
        def hold():
            while True:
                try: c, _ = self.server.accept()
                except OSError: return
                self.held.append(c)
        threading.Thread(target=hold, daemon=True).start()
        with open(os.path.join(self.root, "control.json"), "w") as f:
            json.dump({"port": self.server.getsockname()[1], "token": "t", "pid": os.getpid()}, f)
        self.patches = [mock.patch.object(ctl, "ROOT", self.root), mock.patch.dict(os.environ, {"S2ARMCTL_STATE_TIMEOUT": "0.5"})]
        for p in self.patches: p.start()

    def tearDown(self):
        for p in self.patches: p.stop()
        self.server.close()
        for c in self.held: c.close()

    def job(self, finish_after, final="completed"):
        """假作业进程：按 core.py 的格式写作业记录（running + pid / pidStart），finish_after 秒后写终态退出；final=None = 中途被杀、记录停在 running"""
        path = os.path.join(self.root, "jobs", "job1.json")
        code = f"""
import json, os, subprocess, sys, time
p = {path!r}
st = subprocess.run(['/bin/ps', '-o', 'lstart=', '-p', str(os.getpid())], capture_output=True, text=True).stdout.strip()
rec = dict(schema=1, id='job1', operation='ipa', gameId='game', state='running', started=time.time(), pid=os.getpid(), pidStart=st, stage='直连库', done=1, total=4)
def w(): open(p + '.tmp', 'w').write(json.dumps(rec)); os.replace(p + '.tmp', p)
w()
for i in range(2, 5):
    time.sleep({finish_after} / 4); rec['done'] = i; w()
final = {final!r}
if final is None: os._exit(9)
rec.update(state=final, ended=time.time()); w()
"""
        proc = subprocess.Popen([sys.executable, "-c", code])
        for _ in range(100):
            if os.path.exists(path): break
            time.sleep(0.05)
        return proc

    def run_wait(self, limit=30):
        out = io.StringIO(); t0 = time.time()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as r:
            ctl.wait("game", "ipa", limit)
        return r.exception.code, out.getvalue(), time.time() - t0

    def test_stuck_control_job_completes(self):
        proc = self.job(3)
        code, out, took = self.run_wait()
        proc.wait()
        self.assertEqual(code, 0, out)
        self.assertIn("控制口没应答", out)
        self.assertIn("completed", out)
        self.assertLess(took, 20)

    def test_stuck_control_job_process_gone_fails(self):
        proc = self.job(2, final=None)
        code, out, _ = self.run_wait()
        proc.wait()
        self.assertEqual(code, 1, out)
        self.assertIn("作业进程已不在", out)

    def test_stale_snapshot_falls_back_to_journal(self):
        # 控制口还在回，但快照是 60 秒前的（启动器主线程卡住、缓存没刷新）：同样按作业记录判
        proc = self.job(2)
        stale = {"tasks": [{"id": "job1", "state": "running", "started": 1, "gameId": "game", "operation": "ipa"}],
                 "queue": [], "error": None, "cachedAt": time.time() - 60}
        with mock.patch.object(ctl, "call", return_value=stale):
            code, out, _ = self.run_wait()
        proc.wait()
        self.assertEqual(code, 0, out)
        self.assertIn("状态停住了", out)


class JobIdentityTests(unittest.TestCase):
    """Synthetic journals and ps replies only; never inspect or signal a real PID."""
    start = "Tue Oct 27 08:00:00 2026"

    def probe(self, identity, stdout=None, returncode=0, present=True):
        record = {"pid": 12345, "pidStart": identity}
        reply = subprocess.CompletedProcess([], returncode,
            stdout if stdout is not None else "S    " + self.start + "\n", "")
        with mock.patch.object(ctl, "alive", return_value=present), \
                mock.patch.object(ctl.subprocess, "run", return_value=reply):
            return ctl.job_alive(record)

    def test_matching_identity_is_alive(self):
        self.assertIs(self.probe(self.start), True)

    def test_reused_pid_is_not_this_job(self):
        self.assertIs(self.probe("Mon Oct 26 08:00:00 2026"), False)

    def test_missing_identity_is_unknown_not_alive(self):
        for identity in (None, "", "   "):
            with self.subTest(identity=identity):
                self.assertIsNone(self.probe(identity))

    def test_exited_and_zombie_are_dead_even_without_identity(self):
        self.assertIs(self.probe(None, present=False), False)
        self.assertIs(self.probe(None, stdout="Z    " + self.start), False)

    def test_failed_or_incomplete_query_is_unknown(self):
        for stdout, code in (("", 1), ("S", 0), ("", 0)):
            with self.subTest(stdout=stdout, code=code):
                self.assertIsNone(self.probe(self.start, stdout, code))
        with mock.patch.object(ctl, "alive", return_value=True), \
                mock.patch.object(ctl.subprocess, "run", side_effect=OSError("unavailable")):
            self.assertIsNone(ctl.job_alive({"pid": 12345, "pidStart": self.start}))

    def wait_journal(self, record):
        now = [0]
        def sleep(seconds): now[0] += seconds
        output = io.StringIO()
        with mock.patch.object(ctl, "call", return_value=None), \
                mock.patch.object(ctl, "journal_task", return_value=record), \
                mock.patch.object(ctl, "alive", return_value=True), \
                mock.patch.object(ctl.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], 0, "S    " + self.start, "")), \
                mock.patch.object(ctl.time, "time", side_effect=lambda: now[0]), \
                mock.patch.object(ctl.time, "sleep", side_effect=sleep), \
                contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as result:
            ctl.wait("game", "build", 4)
        return result.exception.code, output.getvalue()

    def test_wait_reports_unknown_without_false_running_or_dead(self):
        record = dict(task("synthetic", "running", 0), pid=12345, pidStart="")
        code, output = self.wait_journal(record)
        self.assertEqual(code, 1)
        self.assertIn("无法确认作业进程身份", output)
        for misleading in ("照常在跑", "running", "作业进程已不在", "可在 S2Arm 里重试"):
            self.assertNotIn(misleading, output)
        self.assertEqual(record["state"], "running")  # reporting must not rewrite journal

    def test_wait_known_reused_pid_still_reports_dead(self):
        code, output = self.wait_journal(dict(task("synthetic", "running", 0),
            pid=12345, pidStart="Mon Oct 26 08:00:00 2026"))
        self.assertEqual(code, 1)
        self.assertIn("作业进程已不在", output)

    def test_terminal_record_does_not_require_process_identity(self):
        code, output = self.wait_journal(task("synthetic", "completed", 0))
        self.assertEqual(code, 0)
        self.assertIn("completed", output)

    def test_wait_matching_identity_keeps_waiting(self):
        code, output = self.wait_journal(dict(task("synthetic", "running", 0),
            pid=12345, pidStart=self.start))
        self.assertEqual(code, "4 秒内没结束（任务 synthetic）")
        self.assertIn("running", output)
        self.assertNotIn("无法确认", output)

    def test_cancelling_unknown_identity_is_not_reported_dead(self):
        code, output = self.wait_journal(dict(task("synthetic", "cancelling", 0), pid=12345))
        self.assertEqual(code, 1)
        self.assertIn("无法确认作业进程身份", output)
        self.assertNotIn("作业进程已不在", output)
