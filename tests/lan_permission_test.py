# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Host-C execution of the real permission-mode helper; no UIKit/Bonjour proof."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'ios/ldn_lan.m').read_text()
start = source.index('static int lan_permission_dev_mode(void)')
end = source.index('\n}\n', start) + 3
helper = source[start:end]
probe = r'''
int main(int argc, char **argv) {
    (void)argc;
    int expected = argv[1][0] == '1';
    if (expected) setenv("S2A_LDN_SERVER", "lan", 1);
    else unsetenv("S2A_LDN_SERVER");
    if (lan_permission_dev_mode() != expected) return 1;
    /* First accepted start writes this diagnostic env; stop must not make it
       an unattended opt-out for a restarted session. */
    setenv("S2A_LDN_SERVER", "lan", 1);
    if (lan_permission_dev_mode() != expected) return 2;
    unsetenv("S2A_LDN_SERVER");
    if (lan_permission_dev_mode() != expected) return 3;
    return 0;
}
'''
with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    for negative in (False, True):
        body = helper.replace('static int initial = -1;', 'int initial = -1;') if negative else helper
        c = d / 'probe.c'
        c.write_text('#define _POSIX_C_SOURCE 200809L\n#include <stdlib.h>\n#include <string.h>\n' + body + probe)
        exe = d / 'probe'
        subprocess.run([os.environ.get('CC', 'cc'), '-Wall', '-Wextra', '-Werror', str(c), '-o', str(exe)], check=True)
        for mode in ('0', '1'):
            rc = subprocess.run([str(exe), mode]).returncode
            assert rc == ((2 if mode == '0' else 3) if negative else 0), (negative, mode, rc)
        print(('negative re-read rejected' if negative else 'actual helper: ordinary/restart and explicit-dev/restart passed'))
# Explicit source contracts: cloud cannot execute the ObjC permission/UI callbacks.
a = source[source.index('static int lan_start('):source.index('static void lan_hosting(')]
assert a.index('if (!port)') < a.index('lan_permission_dev_mode()')
assert a.index('if (g_lan)') < a.index('lan_permission_dev_mode()')
assert a.index('lan_permission_dev_mode()') < a.index('setenv(')
assert 'if (!lan_is_current(lan)) return;\n        s2a_lan_permission_then(dev, ^{' in a
assert 'if (lan_is_current(lan)) [lan start:pid];' in a
print('source contracts: cached mode placement and both deferred-callback gates passed; UIKit untested')
# 审计 P2-17：没有界面时不开始找设备，挂到「根视图就绪」（ios/root_ready.m s2a_ios_on_root_view，行为由 t_ios_root_ready notify 实测）后回来先说明。
perm = (root / 'ios/lan_permission.m').read_text()
then = perm[perm.index('void s2a_lan_permission_then('):perm.index('UIAlertController *a = [UIAlertController alertControllerWithTitle:S2AL(@"lan.permission.title")')]
no_ui = then[then.index('if (!top) {'):]
assert 'go()' not in no_ui, 'no-UI branch must not start discovery'
assert 's2a_ios_on_root_view(retry)' in no_ui and 's2a_lan_permission_then(dev_mode, go)' in no_ui
assert then.index('S2ALanPermExplained') < then.index('lan_top_vc()'), 'explained/unattended/dev skip must not depend on UI'
print('source contracts: no-UI branch defers to root-view readiness and never starts discovery')
