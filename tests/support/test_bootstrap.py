"""Dependency consent and capacity checks use metadata from isolated package stubs."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SOURCE = (PROJECT/'tools/bootstrap.sh').read_text().split('# ---- dependency setup ----', 1)[1].split('# ---- end dependency setup ----', 1)[0]
STUB = r'''#!/usr/bin/python3
import os, sys
from pathlib import Path
root=Path(os.environ['DEP_TEST'])
name=Path(sys.argv[0]).name
args=sys.argv[1:]
if name=='df':
    counter=root/'df-count'
    count=int(counter.read_text())+1 if counter.exists() else 1
    counter.write_text(str(count))
    free=int(os.environ.get('DEP_FREE','20000'))
    if os.environ.get('DEP_DROP') and count>=3: free=5119
    print('Filesystem 1K-blocks Used Available Use% Mounted on')
    print(f'fixture 30000 0 {free} 0% /')
    sys.exit(0)
if name=='ucode':
    sys.exit(0 if (root/'installed').exists() or os.environ.get('DEP_READY') or 'uloop' not in ' '.join(args) else 1)
if name not in ('apk','opkg'): sys.exit(0)
while args and args[0].startswith('--'):
    flag=args.pop(0)
    if flag in ('--cache-dir','--lists-dir'): args.pop(0)
    if flag=='--noaction':
        print('Installing ucode-mod-uloop (1) to root...')
        print('Installing libnew (1) to root...')
        sys.exit(0)
verb=args.pop(0)
with (root/'calls').open('a') as f: f.write(name+' '+verb+' '+' '.join(args)+'\n')
if verb=='update': sys.exit(0)
if verb in ('info','status') and (verb=='status' or args[0]=='-e'):
    sys.exit(0 if args[-1]=='libc=1' and not os.environ.get('DEP_UPGRADE') else 1)
if verb in ('query','info'):
    names=['ucode-mod-uloop','libnew','libc'] if verb=='query' else args
    for package in names:
        size=4096 if package=='ucode-mod-uloop' else (1024 if package=='libnew' else 1000000)
        print(('Name' if name=='apk' else 'Package')+': '+package)
        print('Version: 1')
        print('Installed-Size: '+str(size))
        if not os.environ.get('DEP_BAD_SIZE'): print(('File-Size' if name=='apk' else 'Size')+': '+str(size//2))
        print()
    sys.exit(0)
if verb in ('add','install'):
    if os.environ.get('DEP_FAIL_INSTALL'): sys.exit(73)
    (root/'installed').write_text('1')
    sys.exit(0)
sys.exit(2)
'''

class BootstrapTests(unittest.TestCase):
    def run_case(self, manager='apk', answer='n\n', **extra):
        with tempfile.TemporaryDirectory(prefix='zify-dependencies-') as temporary:
            root=Path(temporary)
            (root/'bin').mkdir()
            (root/'work').mkdir()
            program=root/'stub'
            program.write_text(STUB)
            program.chmod(0o755)
            for name in ['df','ucode','curl','unzip','uci','tar','stty',manager]:
                (root/'bin'/name).symlink_to(program)
            env={**os.environ,'DEP_TEST':str(root),'PATH':str(root/'bin')+':/usr/bin:/bin',**extra}
            script='set -eu\n'+SOURCE+'\nwork=$DEP_TEST/work\nensure_dependencies\n'
            result=subprocess.run(['sh','-c',script],input=answer,text=True,capture_output=True,env=env,timeout=10)
            calls=(root/'calls').read_text() if (root/'calls').exists() else ''
            return result,(root/'installed').exists(),calls

    def test_decline_or_empty_never_installs(self):
        for manager in ['apk','opkg']:
            for answer in ['n\n','\n','']:
                result,installed,calls=self.run_case(manager,answer)
                self.assertEqual(result.returncode,1,result.stderr)
                self.assertFalse(installed)
                self.assertIn('Установить зависимости? [y/N]',result.stdout)
                self.assertIn('libnew',result.stdout)
                self.assertNotIn('libc —',result.stdout)
                self.assertNotIn(' add ',calls)
                self.assertNotIn(' install ',calls)

    def test_yes_installs_and_revalidates_both_managers(self):
        for manager in ['apk','opkg']:
            result,installed,calls=self.run_case(manager,'y\n')
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue(installed)
            self.assertIn('Загрузка: 2.5 KiB; место после установки: 5.0 KiB.',result.stdout)
            self.assertIn('требуется с резервом: 5130 KiB',result.stdout)
            self.assertIn(manager+(' add ' if manager=='apk' else ' install '),calls)

    def test_required_upgrades_are_included_in_the_size(self):
        result,installed,_=self.run_case(answer='y\n',DEP_UPGRADE='1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(installed)
        self.assertIn('libc —',result.stdout)
        self.assertNotIn('место после установки: 5.0 KiB.',result.stdout)

    def test_unknown_size_and_low_space_fail_before_prompt(self):
        for extra in [{'DEP_BAD_SIZE':'1'},{'DEP_FREE':'5121'}]:
            result,installed,_=self.run_case(answer='y\n',**extra)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(installed)
            self.assertNotIn('[y/N]',result.stdout)

    def test_space_is_rechecked_after_consent(self):
        result,installed,_=self.run_case(answer='y\n',DEP_DROP='1')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(installed)
        self.assertIn('[y/N]',result.stdout)

    def test_ready_runtime_and_install_failure(self):
        result,installed,calls=self.run_case(DEP_READY='1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'')
        self.assertFalse(installed)
        self.assertEqual(calls,'')
        result,installed,_=self.run_case(answer='y\n',DEP_FAIL_INSTALL='1')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(installed)


class RevisionTests(unittest.TestCase):
    def resolve(self, reference):
        import json
        source = (PROJECT/'tools/bootstrap.sh').read_text()
        lookup = source.split('# A commit SHA keeps', 1)[1].split('\nbase=', 1)[0]
        lookup = '\n'.join(lookup.splitlines()[1:])
        with tempfile.TemporaryDirectory(prefix='zify-revision-') as temporary:
            folder = Path(temporary)
            (folder/'reference.json').write_text(json.dumps(reference))
            script = r'''set -eu
work=$1
download() {
    # The old endpoint returns the root commit's full diff, exceeding the cap.
    case "$1" in
        https://api.github.com/repos/swxfe/zify/git/ref/heads/main)
            test "$3" -eq 65536
            cp "$work/reference.json" "$2";;
        *) printf 'curl: (63) Maximum file size exceeded\n' >&2; return 63;;
    esac
}
''' + lookup + '\nprintf "%s\n" "$revision"\n'
            return subprocess.run(['sh', '-c', script, 'zify-revision', str(folder)],
                                  capture_output=True, text=True, timeout=5)

    def test_branch_lookup_avoids_root_commit_diff(self):
        result = self.resolve({'ref':'refs/heads/main',
                               'object':{'type':'commit', 'sha':'a'*40}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'a'*40+'\n')

    def test_wrong_branch_type_or_sha_is_rejected(self):
        for reference in [
            {'ref':'refs/heads/other','object':{'type':'commit','sha':'a'*40}},
            {'ref':'refs/heads/main','object':{'type':'tag','sha':'a'*40}},
            {'ref':'refs/heads/main','object':{'type':'commit','sha':'invalid'}},
            {'sha':'a'*40},
        ]:
            with self.subTest(reference=reference):
                self.assertNotEqual(self.resolve(reference).returncode, 0)
