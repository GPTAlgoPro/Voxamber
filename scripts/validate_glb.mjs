import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import validator from 'gltf-validator';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const input = process.argv[2] || path.join(root, 'artifacts/palace.glb');
const bytes = fs.readFileSync(input);
const report = await validator.validateBytes(new Uint8Array(bytes), { uri: path.basename(input), maxIssues: 100 });
const jsonSize = bytes.readUInt32LE(12);
const model = JSON.parse(bytes.subarray(20, 20 + jsonSize).toString());
// This lab emits a flat scene with positive scale and translation only. Report
// physical world bounds, rather than the unscaled accessor coordinate ranges.
const ranges = model.nodes.flatMap(node => {
  if (node.mesh === undefined) return [];
  if (node.matrix || node.rotation || node.children?.length) throw new Error('Extend bounds readback before accepting transformed scene hierarchy');
  const scale = node.scale || [1, 1, 1], translation = node.translation || [0, 0, 0];
  if (scale.some(v => v <= 0)) throw new Error('Expected positive scene scale');
  return model.meshes[node.mesh].primitives.map(p => {
    const a = model.accessors[p.attributes.POSITION];
    return [0, 1, 2].map(axis => [a.min[axis] * scale[axis] + translation[axis], a.max[axis] * scale[axis] + translation[axis]]);
  });
});
const summary = {
  input: path.basename(input),
  bytes: bytes.length,
  meshes: model.meshes.length,
  materials: model.materials.length,
  nodes: model.nodes.length,
  vertices: model.meshes.reduce((sum, mesh) => sum + mesh.primitives.reduce((n, p) => n + model.accessors[p.attributes.POSITION].count, 0), 0),
  triangles: model.meshes.reduce((sum, mesh) => sum + mesh.primitives.reduce((n, p) => n + model.accessors[p.indices].count / 3, 0), 0),
  bounds_world_meters: [0, 1, 2].map(axis => [Math.min(...ranges.map(r => r[axis][0])), Math.max(...ranges.map(r => r[axis][1]))]),
  issues: report.issues,
  generator: model.asset.generator,
  validatorVersion: report.validatorVersion
};
fs.writeFileSync(path.join(root, 'artifacts/glb-validation.json'), JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify(summary, null, 2));
if (report.issues.numErrors || report.issues.numWarnings) process.exitCode = 1;
