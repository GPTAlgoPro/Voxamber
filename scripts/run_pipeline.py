"""Generate, compile with official Three-Live, repair USD schema, and validate."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts'
OUT.mkdir(exist_ok=True)
CLI = ROOT / 'tools/three-live-cli'
receipt = {'compiler': 'Google Three-Live v1.2.3 official macOS arm64 release', 'upstream_commit': 'c0ff24b628795286a175f1a71611673df5dbc05d', 'steps': []}


def run(name, args, required=True):
    start = time.perf_counter()
    result = subprocess.run([str(a) for a in args], cwd=ROOT, text=True, capture_output=True, timeout=90)
    step = {'name': name, 'elapsed_ms': round((time.perf_counter() - start) * 1000, 2), 'exit_code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
    receipt['steps'].append(step)
    (OUT / 'validation.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(f'{name}: {step["elapsed_ms"]} ms, exit {result.returncode}', flush=True)
    if result.returncode and required:
        print(result.stdout + result.stderr)
        raise SystemExit(result.returncode)
    return result


run('host_geometry_generation', [sys.executable, 'scripts/generate_palace.py'])
run('native_scene_validation', [CLI, 'validate', 'scenes/palace.js'])
run('native_js_to_glb', [CLI, 'convert', 'scenes/palace.js', '-o', OUT / 'palace.glb'])
run('native_js_to_usdz', [CLI, 'convert', 'scenes/palace.js', '-o', OUT / 'palace-raw.usdz'])
run('native_glb_to_usdz', [CLI, 'convert', OUT / 'palace.glb', '-o', OUT / 'palace-from-glb-raw.usdz'])
run('raw_apple_compliance', ['usdchecker', '--arkit', '--strict', OUT / 'palace-raw.usdz'], required=False)

# v1.2.3 authors material:binding relationships without declaring the applied
# MaterialBindingAPI schema and omits the polygon subdivision declaration. Keep
# the raw artifact; declare the authored triangles without changing mesh arrays.
with zipfile.ZipFile(OUT / 'palace-raw.usdz') as archive:
    usda = archive.read('model.usda').decode()
fixed, count = re.subn(r'(def Mesh "[^"]+")\s*\{', r'\1 (\n    prepend apiSchemas = ["MaterialBindingAPI"]\n) {\nuniform token subdivisionScheme = "none"', usda)
if not count:
    raise SystemExit('No mesh declarations found for MaterialBindingAPI repair.')
(OUT / 'palace-repaired.usda').write_text(fixed)
receipt['usd_postprocess'] = {'applied_schema': 'MaterialBindingAPI', 'subdivisionScheme': 'none', 'mesh_prims_updated': count, 'vertex_index_or_material_values_changed': False, 'reason': 'Declare material binding schema and preserve authored triangles instead of the USD default Catmull-Clark surface'}
run('apple_usdc_encoding', ['usdcat', OUT / 'palace-repaired.usda', '-o', OUT / 'palace.usdc'])
final = OUT / 'palace.usdz'
if final.exists():
    final.unlink()
run('apple_usdz_packaging', ['usdzip', '--arkitAsset', OUT / 'palace.usdc', final])
run('final_apple_compliance', ['usdchecker', '--arkit', '--strict', final])
run('khronos_glb_validation', ['node', 'scripts/validate_glb.mjs'])
native_checker = ROOT / 'tools/check-realitykit'
native_source = ROOT / 'scripts/check_realitykit.swift'
if not native_checker.exists() or native_checker.stat().st_mtime < native_source.stat().st_mtime:
    run('build_native_realitykit_checker', ['swiftc', '-parse-as-library', native_source, '-o', native_checker])
native_result = run('macOS_realitykit_import_readback', [native_checker, final])
(OUT / 'realitykit-validation.json').write_text(native_result.stdout)
native = json.loads(native_result.stdout)
glb = json.loads((OUT / 'glb-validation.json').read_text())
assert native['modelEntities'] == glb['meshes'], 'Mesh missing from native import'
assert native['triangles'] == glb['triangles'], 'Triangle count changed on native import'
for axis, expected in enumerate(glb['bounds_world_meters']):
    assert abs(native['boundsMetres']['min'][axis] - expected[0]) < 1e-5
    assert abs(native['boundsMetres']['max'][axis] - expected[1]) < 1e-5
assert (OUT / 'palace-raw.usdz').read_bytes() == (OUT / 'palace-from-glb-raw.usdz').read_bytes(), 'Direct/transcoded USDZ differ'
receipt['cross_format_readback'] = {'model_counts_equal': True, 'triangle_counts_equal': True, 'bounds_equal_within_meters': 1e-5, 'native_direct_and_glb_transcoded_usdz_identical': True}
receipt['files'] = {p.name: {'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in [ROOT / 'scenes/palace.js', OUT / 'palace.glb', OUT / 'palace-raw.usdz', OUT / 'palace-from-glb-raw.usdz', final]}
receipt['compiler_sha256'] = hashlib.sha256(CLI.read_bytes()).hexdigest()
receipt['runtime_acceptance'] = {'macOS_realitykit': native['success'], 'iPhone_physical_AR': 'not performed'}
(OUT / 'validation.json').write_text(json.dumps(receipt, indent=2) + '\n')
