#!/bin/sh
set -eu
sh tools/bundle.sh >/dev/null
python3 tests/integration/cli.py "$work/manager"
printf '%s\n' 'cli: flexible options, UCI, TTY approvals, closed/open pipes and private entry isolation OK'
