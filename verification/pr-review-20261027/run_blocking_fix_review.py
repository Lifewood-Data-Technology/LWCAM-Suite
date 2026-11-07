"""Independent review of 8bde4b9: execute extracted production submit/button.

No production edits. Only path lookup, thumbnail refresh, screen state and snack
rendering are stubbed. SQLite/outbox, durable intents and marker writes are real.
"""
import argparse
import hashlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--flutter', required=True)
parser.add_argument('--source', type=Path)
parser.add_argument('--case')
parser.add_argument('--template', type=Path)
args = parser.parse_args()
source = args.source or ROOT / 'LWCAM/lib/pages/gallery_page.dart'
raw = source.read_bytes()
code = raw.decode('utf-8').replace('\r\n', '\n')
submit = code[code.index('  Future<void> _onSubmitReworkPressed() async {'):code.index('  /// Writes [source] over [target]')]
button = code[code.index('  Widget _buildReworkSubmitButton() {'):code.index('  // ── Rework metadata')]
undo = code[code.index('  Future<void> _undoReworkResolution(ReworkItem item) async {'):code.index('  /// Submit lives in the header')]
template = (args.template or HERE / 'blocking_fix_review.template').read_text(encoding='utf-8')
target = HERE / '_blocking_fix_review_test.dart'
if target.exists():
    raise SystemExit('Refusing to overwrite generated file')
target.write_text(template.replace('// PRODUCTION_SUBMIT', submit).replace('// PRODUCTION_BUTTON', button).replace('// PRODUCTION_UNDO', undo), encoding='utf-8')
print('source=', source, 'sha256=', hashlib.sha256(raw).hexdigest(), flush=True)
try:
    command = [args.flutter, 'test', '--no-pub', '--reporter', 'expanded', str(target)]
    if args.case:
        command += ['--plain-name', args.case]
    result = subprocess.run(command, cwd=ROOT / 'LWCAM')
finally:
    target.unlink()
raise SystemExit(result.returncode)
