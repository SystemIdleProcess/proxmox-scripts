"""Optional contract check against an official core checkout, never executes installers."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

class FrameworkOrigin(unittest.TestCase):
    def test_nested_branch_origin_survives_generated_updater(self):
        checkout = os.environ.get('CS_CORE_DIR')
        if not checkout:
            self.skipTest('Set CS_CORE_DIR to an official community-scripts/core checkout')
        source = (Path(checkout) / 'core/core.func').read_text()
        functions = []
        for name in ['_cs_live_base', 'write_update_entrypoint']:
            match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S)
            self.assertIsNotNone(match, name)
            functions.append(match.group())
        origin = 'https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/feat/mcphub-lxc/community-scripts'
        with tempfile.TemporaryDirectory() as folder:
            code = '\n'.join(functions).replace('/usr/bin', folder)
            code += '\nwrite_update_entrypoint systemidle-mcphub mcphub\n'
            env = dict(os.environ, COMMUNITY_SCRIPTS_URL=origin,
                       COMMUNITY_SCRIPTS_CORE_URL='https://raw.githubusercontent.com/community-scripts/core/4f6c2bd4dfadce266dca9ec737e8382728d753e3')
            subprocess.run(['bash', '-eu', '-c', code], env=env, check=True)
            updater = Path(folder) / 'update'
            subprocess.run(['bash', '-n', str(updater)], check=True)
            result = updater.read_text()
            self.assertIn('export COMMUNITY_SCRIPTS_URL="' + origin + '"', result)
            self.assertIn('export SCRIPT_SLUG="systemidle-mcphub"', result)
            self.assertIn('export UPDATE_SCRIPT_NAME="mcphub"', result)

if __name__ == '__main__':
    unittest.main()
